#!/usr/bin/env bash
# Session steps of the postgres part of the data-scaling lab, on the learner's machine with profile anhnv-stg: finds
# the endpoints and the loader by name, runs pg.sh on the loader through SSM Run Command (waiting, or in the
# background to read later), fails Aurora or RDS over, and reads the CloudWatch metrics and RDS events of the measures.

# Prints results only; writes no file. Endpoints go by the names below, never typed by hand, and the instance checks
# every name it gets again. Design notes: data-scaling/README.md.
# Usage: SVP_AWS_STG_ACCOUNT_ID=<id> scripts/pg-session.sh check | endpoints | run ARGS... | start ARGS... | result ID |
#   failover aurora|rds | events [MINUTES] | metrics lag|burst [MINUTES]
set -euo pipefail

profile=anhnv-stg
region=ap-southeast-1
loader=svp-lab-ds-pg-loader
cluster=svp-lab-ds-aurora
rds=svp-lab-ds-rds
proxy=svp-lab-ds-proxy
pg=/opt/svp-lab-ds/pg.sh
# pg.sh refuses a run longer than 3300 s, so a run never outlives its command.
timeout=3600
targets="aurora-writer aurora-reader aurora-1 aurora-2 rds rds-replica proxy"

fail() {
  echo "pg-session: $*" >&2
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
  id=$(aws_ ec2 describe-instances --filters "Name=tag:Name,Values=$loader" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [[ $id =~ ^i-[0-9a-f]+$ ]] || fail "no running instance $loader (terraform apply first)"
  printf '%s' "$id"
}

# endpoint NAME: the host of one of the targets; fails for a name it does not know or a part that is off.
endpoint() {
  local host
  case $1 in
    aurora-writer) host=$(aws_ rds describe-db-clusters --db-cluster-identifier "$cluster" \
      --query 'DBClusters[0].Endpoint' --output text) ;;
    aurora-reader) host=$(aws_ rds describe-db-clusters --db-cluster-identifier "$cluster" \
      --query 'DBClusters[0].ReaderEndpoint' --output text) ;;
    aurora-1 | aurora-2) host=$(aws_ rds describe-db-instances --db-instance-identifier "svp-lab-ds-$1" \
      --query 'DBInstances[0].Endpoint.Address' --output text) ;;
    rds | rds-replica) host=$(aws_ rds describe-db-instances --db-instance-identifier "svp-lab-ds-$1" \
      --query 'DBInstances[0].Endpoint.Address' --output text) ;;
    proxy) host=$(aws_ rds describe-db-proxies --db-proxy-name "$proxy" \
      --query 'DBProxies[0].Endpoint' --output text) ;;
    *) fail "unknown target '$1': one of $targets" ;;
  esac || fail "no endpoint for $1: is its part on (terraform apply)?"
  [[ $host =~ ^[a-z0-9][a-z0-9.-]*\.rds\.amazonaws\.com$ ]] || fail "no endpoint for $1 yet: '$host'"
  printf '%s' "$host"
}

# resolve ARGS...: the arguments of pg.sh with each target name replaced by its host. Which arguments are targets
# depends on the command; any other argument must be a plain word the remote shell keeps as it is.
resolve() {
  local cmd=${1:-} i=0 a
  local -a out=()
  case $cmd in
    init | load | burst | read | lag | probe) ;;
    *) fail "unknown pg.sh command '$cmd': init | load | burst | read | lag | probe | window" ;;
  esac
  for a in "$@"; do
    if { [ "$i" = 1 ] && [ "$cmd" != probe ]; } || { [ "$i" = 2 ] && [ "$cmd" = lag ]; } ||
      { [ "$i" -ge 3 ] && [ "$cmd" = probe ]; }; then
      a=$(endpoint "$a") || exit 1
    fi
    [[ $a =~ ^[A-Za-z0-9:/._-]+$ ]] || fail "argument '$a' holds a character the remote shell reads"
    out+=("$a")
    i=$((i + 1))
  done
  printf '%s\n' "${out[@]}"
}

# window takes a log path of the instance, not a target: only the probe logs pg.sh writes are accepted.
args_for() {
  if [ "${1:-}" = window ]; then
    [[ ${2:-} =~ ^/var/lib/svp-lab-ds/probe\.[A-Za-z0-9]+/probe-[12]\.log$ ]] ||
      fail "window takes a log a probe printed: /var/lib/svp-lab-ds/probe.<id>/probe-1.log or probe-2.log"
    printf '%s\n' window "$2"
  else
    resolve "$@"
  fi
}

# remote_args ARGS...: sets the caller's array args to the arguments for pg.sh, or exits before anything is sent when
# one of them is refused.
remote_args() {
  local out line
  out=$(args_for "$@") || exit 1
  while IFS= read -r line; do args+=("$line"); done <<<"$out"
}

# send INSTANCE ARGS...: starts pg.sh ARGS on the loader as root and prints the command id.
send() {
  local id=$1 cmd
  shift
  cmd="$pg $*"
  aws_ ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$(jq -cn --arg c "$cmd" --arg t "$timeout" '{commands: [$c], executionTimeout: [$t]}')" \
    --query Command.CommandId --output text || fail "ssm send-command to $id"
}

# status ID INSTANCE: one read of the command's state; prints its output once it ended, and fails as it failed. Exit 3
# while it still runs, 4 while SSM knows no such command on the instance; any other error of the read ends the script.
status() {
  local cid=$1 id=$2 out st
  if ! out=$(aws_ ssm get-command-invocation --command-id "$cid" --instance-id "$id" --output json 2>&1); then
    [[ $out != *"(InvocationDoesNotExist)"* ]] || return 4
    printf '%s\n' "$out" >&2
    fail "cannot read command $cid on $id"
  fi
  st=$(jq -r .Status <<<"$out") || fail "cannot read the answer for command $cid on $id"
  case $st in
    Pending | InProgress | Delayed) return 3 ;;
  esac
  jq -r '.StandardOutputContent // empty' <<<"$out"
  [ "$st" = Success ] || {
    jq -r '.StandardErrorContent // empty' <<<"$out" >&2
    fail "command $cid on $id ended $st"
  }
}

cmd_run() {
  local id cid deadline rc
  local -a args=()
  [ $# -gt 0 ] || fail "run needs the arguments of pg.sh"
  remote_args "$@"
  id=$(instance)
  cid=$(send "$id" "${args[@]}")
  deadline=$(($(now) + timeout + 60))
  while :; do
    sleep 2
    rc=0
    status "$cid" "$id" || rc=$?
    # SSM records the invocation a moment after send-command returns its id.
    [ "$rc" = 3 ] || [ "$rc" = 4 ] || return "$rc"
    [ "$(now)" -lt "$deadline" ] || fail "'pg.sh ${args[*]}' still running after $timeout s (command $cid)"
  done
}

# Starts and returns at once: the learner fails over, then reads the result with the id printed here.
cmd_start() {
  local id cid
  local -a args=()
  [ $# -gt 0 ] || fail "start needs the arguments of pg.sh"
  remote_args "$@"
  id=$(instance)
  cid=$(send "$id" "${args[@]}")
  echo "started 'pg.sh ${args[*]}' at $(utc "$(now)"): command $cid; read it with pg-session.sh result $cid"
}

cmd_result() {
  local id rc=0
  [[ ${1:-} =~ ^[0-9a-f-]{36}$ ]] || fail "result needs the command id that start printed"
  id=$(instance)
  status "$1" "$id" || rc=$?
  [ "$rc" != 4 ] || fail "the loader $id has no command $1: use the id that start printed"
  [ "$rc" != 3 ] || echo "command $1 still running at $(utc "$(now)"); read it again later"
  [ "$rc" = 3 ] || return "$rc"
}

cmd_endpoints() {
  local t host
  for t in $targets; do
    host=$( (endpoint "$t") 2>/dev/null) || host="off"
    echo "$t $host"
  done
}

# Aurora promotes its reader; RDS Multi-AZ reboots the primary onto its standby. The request time printed here is the
# start of the failover as the learner reads it.
cmd_failover() {
  case ${1:-} in
    aurora)
      aws_ rds failover-db-cluster --db-cluster-identifier "$cluster" --query DBCluster.Status --output text >/dev/null
      echo "failover of $cluster requested at $(utc "$(now)")" ;;
    rds)
      aws_ rds reboot-db-instance --db-instance-identifier "$rds" --force-failover \
        --query DBInstance.DBInstanceStatus --output text >/dev/null
      echo "reboot with failover of $rds requested at $(utc "$(now)")" ;;
    *) fail "failover takes aurora or rds" ;;
  esac
}

cmd_events() {
  local minutes=${1:-60} type id
  [[ $minutes =~ ^[1-9][0-9]*$ ]] || fail "minutes must be a positive number"
  for type in db-cluster:$cluster db-instance:$cluster-1 db-instance:$cluster-2 db-instance:$rds; do
    id=${type#*:}
    aws_ rds describe-events --source-type "${type%%:*}" --source-identifier "$id" --duration "$minutes" \
      --query 'Events[].[Date,Message]' --output text | awk -F'\t' -v id="$id" '{print $1 "  " id "  " $2}'
  done
}

# metric NAMESPACE METRIC STATISTIC DIMENSION START END: the largest and the mean of the one-minute values.
metric() {
  local out
  out=$(aws_ cloudwatch get-metric-statistics --namespace "$1" --metric-name "$2" --dimensions "$4" \
    --start-time "$(utc "$5")" --end-time "$(utc "$6")" --period 60 --statistics "$3" \
    --query "[max(Datapoints[].$3), avg(Datapoints[].$3)]" --output text)
  echo "$2 $3 (${4#Name=}) over $(utc "$5") to $(utc "$6"): largest ${out%%$'\t'*}, mean ${out##*$'\t'}"
}

# AuroraReplicaLag (ms) comes from whichever instance is the reader; ReplicaLag (s) from the RDS replica. Connections
# are the one-minute Maximum of the DB instances and of the proxy.
cmd_metrics() {
  local what=${1:-} minutes=${2:-15} end start i
  [[ $minutes =~ ^[1-9][0-9]*$ ]] || fail "minutes must be a positive number"
  end=$(now)
  start=$((end - minutes * 60))
  case $what in
    lag)
      for i in "$cluster-1" "$cluster-2"; do
        metric AWS/RDS AuroraReplicaLag Maximum "Name=DBInstanceIdentifier,Value=$i" "$start" "$end"
      done
      metric AWS/RDS ReplicaLag Maximum "Name=DBInstanceIdentifier,Value=$rds-replica" "$start" "$end" ;;
    burst)
      for i in "$cluster-1" "$cluster-2"; do
        metric AWS/RDS DatabaseConnections Maximum "Name=DBInstanceIdentifier,Value=$i" "$start" "$end"
      done
      metric AWS/RDS ClientConnections Maximum "Name=ProxyName,Value=$proxy" "$start" "$end"
      metric AWS/RDS DatabaseConnections Maximum "Name=ProxyName,Value=$proxy" "$start" "$end" ;;
    *) fail "metrics takes lag or burst" ;;
  esac
}

cmd=${1:-}
shift || true
case $cmd in
  check) check_account && echo "profile $profile signs in to SVP_AWS_STG_ACCOUNT_ID" ;;
  endpoints) check_account && cmd_endpoints ;;
  run) check_account && cmd_run "$@" ;;
  start) check_account && cmd_start "$@" ;;
  result) check_account && cmd_result "${1:-}" ;;
  failover) check_account && cmd_failover "${1:-}" ;;
  events) check_account && cmd_events "${1:-}" ;;
  metrics) check_account && cmd_metrics "${1:-}" "${2:-}" ;;
  *) fail "usage: pg-session.sh check | endpoints | run ARGS... | start ARGS... | result ID | failover aurora|rds |" \
    "events [MINUTES] | metrics lag|burst [MINUTES]" ;;
esac
