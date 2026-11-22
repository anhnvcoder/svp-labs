#!/usr/bin/env bash
# Session steps of the dms-migration lab, on the learner's machine with profile anhnv-stg: runs pgload.sh on the
# on-premises stand-in through SSM Run Command, starts, reads and stops the DMS task, and reads its full load time and
# its CDC latency metrics. Prints results only; writes no file.

# Times measured on the instance come back in the output of pgload.sh; this script times nothing itself but the full
# load, from the two dates DMS records. Design notes: dms-migration/README.md.
# Usage: SVP_AWS_STG_ACCOUNT_ID=<id> scripts/session.sh check | run ARGS... | task start|resume|status|stop | fullload |
#   metrics [MINUTES] | cutover [LIMIT_S] | cleanup
set -euo pipefail
export AWS_PAGER=""

profile=anhnv-stg
region=ap-southeast-1
lab=svp-lab-dms
pgload=/opt/svp-lab-dms/pgload.sh

fail() {
  echo "session: $*" >&2
  exit 1
}

aws_() { aws --profile "$profile" --region "$region" "$@"; }

now() { date -u +%s; }
# utc EPOCH: the time as RFC 3339 in UTC, with BSD or GNU date.
utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

check_account() {
  local got
  [[ ${SVP_AWS_STG_ACCOUNT_ID:-} =~ ^[0-9]{12}$ ]] ||
    fail "export SVP_AWS_STG_ACCOUNT_ID=<the 12 digits of account svp-stg> first (never in a file)"
  got=$(aws_ sts get-caller-identity --query Account --output text) || fail "sts get-caller-identity"
  [ "$got" = "$SVP_AWS_STG_ACCOUNT_ID" ] || fail "profile $profile signs in to $got, not to SVP_AWS_STG_ACCOUNT_ID"
}

instance() {
  local id
  id=$(aws_ ec2 describe-instances --filters "Name=tag:Name,Values=$lab-source" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [[ $id =~ ^i-[0-9a-f]+$ ]] || fail "no running instance $lab-source (terraform apply first)"
  printf '%s' "$id"
}

task_arn() {
  local arn
  arn=$(aws_ dms describe-replication-tasks --filters "Name=replication-task-id,Values=$lab" \
    --query 'ReplicationTasks[0].ReplicationTaskArn' --output text)
  [[ $arn =~ ^arn:aws[a-z-]*:dms: ]] || fail "no replication task $lab (terraform apply first)"
  printf '%s' "$arn"
}

# remote TIMEOUT ARGS...: runs pgload.sh ARGS on the instance as root, waits, prints its output, and fails as it
# fails. The arguments are words a shell keeps as they are, so nothing typed here runs as another command there.
remote() {
  local timeout=$1 id cid out status deadline a
  shift
  for a in "$@"; do [[ $a =~ ^[A-Za-z0-9:/._-]+$ ]] || fail "argument '$a' holds a character the remote shell reads"; done
  id=$(instance)
  cid=$(aws_ ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$(jq -cn --arg c "$pgload $*" --arg t "$timeout" '{commands: [$c], executionTimeout: [$t]}')" \
    --query Command.CommandId --output text) || fail "ssm send-command to $id"
  deadline=$(($(now) + timeout + 60))
  while :; do
    sleep 2
    out=$(aws_ ssm get-command-invocation --command-id "$cid" --instance-id "$id" --output json 2>/dev/null) || out='{}'
    status=$(jq -r '.Status // "Pending"' <<<"$out")
    case $status in
      Pending | InProgress | Delayed) ;;
      *) break ;;
    esac
    [ "$(now)" -lt "$deadline" ] || fail "'pgload.sh $*' on $id still $status after $timeout s"
  done
  jq -r '.StandardOutputContent // empty' <<<"$out"
  [ "$status" = Success ] || {
    jq -r '.StandardErrorContent // empty' <<<"$out" >&2
    fail "'pgload.sh $*' on $id ended $status"
  }
}

# start is the first run of the task (full load, then CDC); resume picks CDC up again after a stop.
cmd_task() {
  local arn type=start-replication
  case ${1:-} in
    start | resume | status | stop) ;;
    *) fail "usage: session.sh task start|resume|status|stop" ;;
  esac
  arn=$(task_arn)
  case $1 in
    start | resume)
      check_account
      [ "$1" = start ] || type=resume-processing
      echo "task $lab: $(aws_ dms start-replication-task --replication-task-arn "$arn" --start-replication-task-type "$type" \
        --query ReplicationTask.Status --output text) $(utc "$(now)")" ;;
    status)
      aws_ dms describe-replication-tasks --filters "Name=replication-task-id,Values=$lab" --output text --query \
        'ReplicationTasks[0].[Status,StopReason,ReplicationTaskStats.FullLoadProgressPercent,ReplicationTaskStats.TablesLoaded,ReplicationTaskStats.TablesErrored]' |
        awk -F'\t' '{print "task status " $1 ", stop reason " $2 ", full load " $3 " %, tables loaded " $4 ", errored " $5}' ;;
    stop)
      check_account
      aws_ dms stop-replication-task --replication-task-arn "$arn" --query ReplicationTask.Status --output text >/dev/null
      aws_ dms wait replication-task-stopped --filters "Name=replication-task-arn,Values=$arn"
      echo "task $lab stopped $(utc "$(now)")" ;;
  esac
}

# The two dates as DMS records them, ISO 8601 with an offset; the difference in whole seconds.
cmd_fullload() {
  local out
  out=$(aws_ dms describe-replication-tasks --filters "Name=replication-task-id,Values=$lab" --output json \
    --query 'ReplicationTasks[0].ReplicationTaskStats')
  jq -r '
    def epoch: capture("^(?<d>[0-9-]+T[0-9:]{8})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")
      | (.d + "Z" | fromdateiso8601)
        - (if .z == "Z" then 0 else (.z | sub(":"; "")) as $z
           | ($z[0:1] + "1" | tonumber) * (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60) end);
    if .FullLoadFinishDate == null then
      "full load not finished: \(.FullLoadProgressPercent // 0) %, \(.TablesLoaded // 0) tables loaded\n" | halt_error(1)
    else
      "Full load: \((.FullLoadFinishDate | epoch) - (.FullLoadStartDate | epoch)) s" +
        " (start \(.FullLoadStartDate), finish \(.FullLoadFinishDate), \(.TablesLoaded) tables)"
    end' <<<"$out"
}

# DMS publishes the task metrics under the instance and the task's resource id; list-metrics finds the dimensions as
# they are, instead of rebuilding the id from the ARN.
cmd_metrics() {
  local minutes=${1:-15} dims end m stats line
  local -a args=()
  [[ $minutes =~ ^[1-9][0-9]*$ ]] || fail "minutes must be a positive number"
  dims=$(aws_ cloudwatch list-metrics --namespace AWS/DMS --metric-name CDCLatencySource --output json \
    --dimensions "Name=ReplicationInstanceIdentifier,Value=$lab" --query 'Metrics[0].Dimensions')
  [ "$dims" != null ] || fail "no CDCLatencySource metric for $lab yet: is the task in CDC?"
  while IFS= read -r line; do args+=("$line"); done < <(jq -r '.[] | "Name=\(.Name),Value=\(.Value)"' <<<"$dims")
  end=$(now)
  for m in CDCLatencySource CDCLatencyTarget; do
    stats=$(aws_ cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name "$m" --dimensions "${args[@]}" \
      --start-time "$(utc $((end - minutes * 60)))" --end-time "$(utc "$end")" --period 60 --statistics Maximum Average \
      --query '[max(Datapoints[].Maximum), avg(Datapoints[].Average)]' --output text)
    echo "$m over the $minutes min to $(utc "$end"): max ${stats%%$'\t'*} s, average ${stats##*$'\t'} s"
  done
}

cmd_cutover() {
  local limit=${1:-900}
  [[ $limit =~ ^[1-9][0-9]*$ ]] || fail "limit must be a positive number of seconds"
  check_account
  remote $((limit + 300)) cutover "$(task_arn)" "$limit"
}

# Before terraform destroy: the writer and the task stop, then the slot the task made on the source goes.
cmd_cleanup() {
  check_account
  (remote 120 stop) || true
  if [[ $(aws_ dms describe-replication-tasks --filters "Name=replication-task-id,Values=$lab" \
    --query 'ReplicationTasks[0].Status' --output text) =~ ^(running|starting|stopping)$ ]]; then
    cmd_task stop
  fi
  remote 120 drop-slots
}

case ${1:-} in
  check) check_account && echo "profile $profile signs in to SVP_AWS_STG_ACCOUNT_ID" ;;
  run)
    shift
    [ $# -gt 0 ] || fail "run needs the arguments of pgload.sh"
    check_account
    remote 3600 "$@" ;;
  task) cmd_task "${2:-}" ;;
  fullload) cmd_fullload ;;
  metrics) cmd_metrics "${2:-}" ;;
  cutover) cmd_cutover "${2:-}" ;;
  cleanup) cmd_cleanup ;;
  *) fail "usage: session.sh check | run ARGS... | task start|resume|status|stop | fullload | metrics [MINUTES] |" \
    "cutover [LIMIT_S] | cleanup" ;;
esac
