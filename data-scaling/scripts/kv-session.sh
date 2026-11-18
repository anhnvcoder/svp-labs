#!/usr/bin/env bash
# Session steps of the valkey part of the data-scaling lab, on the learner's machine with profile anhnv-stg: finds
# the endpoints, shards and loader by name, runs kv.sh on the loader through SSM Run Command (waiting, or in the
# background to read later), reshards svp-lab-ds-cme and times it, fails one shard over, and reads ElastiCache events.

# Prints results only; writes no file. Endpoints and slots go by the names below, never typed by hand, and the
# instance checks every value it gets again. Design notes: data-scaling/README.md.
# Usage: SVP_AWS_STG_ACCOUNT_ID=<id> scripts/kv-session.sh check | groups | run ARGS... | start ARGS... | result ID |
#   reshard SHARDS | failover cme|cmd NODE_GROUP | events [MINUTES]
set -euo pipefail

profile=anhnv-stg
region=ap-southeast-1
loader=svp-lab-ds-kv-loader
cme=svp-lab-ds-cme
cmd=svp-lab-ds-cmd
kv=/opt/svp-lab-ds/kv.sh
# kv.sh refuses a run longer than 3300 s, so a run never outlives its command.
timeout=3600
# Reshard: the status is read every reshard_poll seconds, for at most reshard_limit seconds.
reshard_poll=10
reshard_limit=3600
max_shards=5

fail() {
  echo "kv-session: $*" >&2
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

# group ID QUERY: one value of the replication group ID, or a failure when the group does not exist.
group() {
  aws_ elasticache describe-replication-groups --replication-group-id "$1" --query "ReplicationGroups[0].$2" \
    --output text || fail "cannot read replication group $1: is the part up (terraform apply)?"
}

# endpoint cme|cmd: the configuration endpoint of the group with cluster mode on, the primary endpoint of the other.
endpoint() {
  local host
  case $1 in
    cme) host=$(group "$cme" ConfigurationEndpoint.Address) || exit 1 ;;
    cmd) host=$(group "$cmd" 'NodeGroups[0].PrimaryEndpoint.Address') || exit 1 ;;
    *) fail "unknown group '$1': cme or cmd" ;;
  esac
  [[ $host =~ ^[a-z0-9][a-z0-9.-]*\.cache\.amazonaws\.com$ ]] || fail "no endpoint for $1 yet: '$host'"
  printf '%s' "$host"
}

# slots NODE_GROUP: the hash slots of one node group of svp-lab-ds-cme, as ElastiCache lists them (0-8191).
slots() {
  local s
  [[ $1 =~ ^[0-9]{4}$ ]] || fail "a node group is four digits, such as 0001, not '$1'"
  s=$(group "$cme" "NodeGroups[?NodeGroupId=='$1'].Slots | [0]") || exit 1
  [[ $s =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || fail "$cme has no node group $1 (kv-session.sh groups)"
  printf '%s' "$s"
}

# remote_args ARGS...: sets the caller's array args to the arguments for kv.sh, with group names replaced by endpoints
# and a node group by its slots, or exits before anything is sent when one of them is refused.
remote_args() {
  local a
  local -a out=()
  case ${1:-} in
    probe)
      [ $# -ge 3 ] || fail "probe SECONDS cme NODE_GROUP | probe SECONDS cmd"
      case $3 in
        cme) [ $# = 4 ] || fail "probe on cme needs the node group to hit, such as 0001"
          out=(probe "$2" "$(endpoint cme)" "$(slots "$4")") ;;
        cmd) [ $# = 3 ] || fail "probe on cmd takes no node group"
          out=(probe "$2" "$(endpoint cmd)") ;;
        *) fail "probe runs on cme or cmd, not '$3'" ;;
      esac ;;
    bench)
      [ $# = 3 ] || fail "bench SECONDS cme|cmd"
      case $3 in
        cme) out=(bench "$2" "$(endpoint cme)" cluster) ;;
        cmd) out=(bench "$2" "$(endpoint cmd)" plain) ;;
        *) fail "bench runs on cme or cmd, not '$3'" ;;
      esac ;;
    client)
      [ $# = 1 ] || fail "client takes no argument"
      out=(client "$(endpoint cme)" "$(endpoint cmd)") ;;
    window)
      [[ $# = 2 && $2 =~ ^/var/lib/svp-lab-ds/probe\.[A-Za-z0-9]+/probe\.log$ ]] ||
        fail "window takes a log a probe printed: /var/lib/svp-lab-ds/probe.<id>/probe.log"
      out=(window "$2") ;;
    rates)
      [[ $# = 2 && $2 =~ ^/var/lib/svp-lab-ds/bench\.[A-Za-z0-9]+/bench\.log$ ]] ||
        fail "rates takes a log a bench printed: /var/lib/svp-lab-ds/bench.<id>/bench.log"
      out=(rates "$2") ;;
    *) fail "unknown kv.sh command '${1:-}': probe | bench | client | window | rates" ;;
  esac
  for a in "${out[@]}"; do
    [ -n "$a" ] || exit 1
    [[ $a =~ ^[A-Za-z0-9:/.,_-]+$ ]] || fail "argument '$a' holds a character the remote shell reads"
  done
  args=("${out[@]}")
}

# send INSTANCE ARGS...: starts kv.sh ARGS on the loader as root and prints the command id.
send() {
  local id=$1 c
  shift
  c="$kv $*"
  aws_ ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$(jq -cn --arg c "$c" --arg t "$timeout" '{commands: [$c], executionTimeout: [$t]}')" \
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
    [ "$(now)" -lt "$deadline" ] || fail "'kv.sh ${args[*]}' still running after $timeout s (command $cid)"
  done
}

# Starts and returns at once: the learner reshards or fails over, then reads the result with the id printed here.
cmd_start() {
  local id cid
  local -a args=()
  remote_args "$@"
  id=$(instance)
  cid=$(send "$id" "${args[@]}")
  echo "started 'kv.sh ${args[*]}' at $(utc "$(now)"): command $cid; read it with kv-session.sh result $cid"
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

# The status, endpoint and node groups of both groups: the node group ids and slots that probe and failover take.
cmd_groups() {
  local g t st host ngs
  for g in cme cmd; do
    t=svp-lab-ds-$g
    st=$(group "$t" Status) || exit 1
    host=$( (endpoint "$g") 2>/dev/null) || host="no endpoint yet"
    # shellcheck disable=SC2016 # the backquotes are a JMESPath literal
    ngs=$(group "$t" 'NodeGroups[].[NodeGroupId, Status, Slots, join(`,`, NodeGroupMembers[].CacheClusterId)]') ||
      exit 1
    echo "$t: $st $host"
    awk -F'\t' '{printf "  node group %s %s slots %s nodes %s\n", $1, $2, ($3 == "None" ? "all" : $3), $4}' <<<"$ngs"
  done
}

# reshard SHARDS: online scale-out of svp-lab-ds-cme to SHARDS node groups through the API, then the reshard time:
# from the moment the request is accepted to the first read of the group available with SHARDS node groups.
cmd_reshard() {
  local want=${1:-} cur st n t0 t last
  [[ $want =~ ^[1-9][0-9]*$ ]] || fail "reshard needs the new number of shards"
  cur=$(group "$cme" '[Status, length(NodeGroups)]') || exit 1
  st=${cur%%$'\t'*}
  n=${cur##*$'\t'}
  [ "$st" = available ] || fail "$cme is $st: reshard only an available group"
  if [ "$want" -le "$n" ] || [ "$want" -gt "$max_shards" ]; then
    fail "$cme has $n shards: reshard scales out to more, at most $max_shards"
  fi
  last=$(aws_ elasticache modify-replication-group-shard-configuration --replication-group-id "$cme" \
    --node-group-count "$want" --apply-immediately --query ReplicationGroup.Status --output text) ||
    fail "the reshard of $cme was not accepted"
  t0=$(now)
  echo "reshard of $cme from $n to $want shards accepted at $(utc "$t0"), status $last"
  echo "set shards = $want in valkey/valkey.auto.tfvars: the next plan then shows no change"
  while :; do
    sleep "$reshard_poll"
    cur=$(group "$cme" '[Status, length(NodeGroups)]') || exit 1
    t=$(now)
    st=${cur%%$'\t'*}
    n=${cur##*$'\t'}
    [ "$st" = "$last" ] || echo "$(utc "$t") status $st, $n shards"
    last=$st
    if [ "$st" = available ] && [ "$n" = "$want" ]; then
      echo "reshard time: $((t - t0)) s, from $(utc "$t0") to $(utc "$t") (status read every $reshard_poll s:" \
        "resolution)"
      cmd_groups
      return
    fi
    [ $((t - t0)) -lt "$reshard_limit" ] ||
      fail "$cme still $st with $n shards after $((t - t0)) s: no reshard time; read it later with kv-session.sh groups"
  done
}

# One test-failover, never repeated: AWS limits how many shards it fails over in a rolling day. The request time
# printed here is the start of the failover as the learner reads it.
cmd_failover() {
  local g=${1:-} ng=${2:-} t found
  case $g in
    cme | cmd) t=svp-lab-ds-$g ;;
    *) fail "failover takes cme or cmd, then a node group such as 0001" ;;
  esac
  [[ $ng =~ ^[0-9]{4}$ ]] || fail "a node group is four digits, such as 0001, not '$ng'"
  found=$(group "$t" "NodeGroups[?NodeGroupId=='$ng'].NodeGroupId | [0]") || exit 1
  [ "$found" = "$ng" ] || fail "$t has no node group $ng (kv-session.sh groups)"
  aws_ elasticache test-failover --replication-group-id "$t" --node-group-id "$ng" \
    --query ReplicationGroup.Status --output text >/dev/null || fail "test-failover of $t node group $ng"
  echo "failover of $t node group $ng requested at $(utc "$(now)")"
}

cmd_events() {
  local minutes=${1:-60}
  [[ $minutes =~ ^[1-9][0-9]*$ ]] || fail "minutes must be a positive number"
  # shellcheck disable=SC2016 # the backquotes are a JMESPath literal
  aws_ elasticache describe-events --duration "$minutes" \
    --query 'Events[?starts_with(SourceIdentifier, `svp-lab-ds-`)].[Date, SourceIdentifier, Message]' --output text |
    awk -F'\t' '{print $1 "  " $2 "  " $3}'
}

c=${1:-}
shift || true
case $c in
  check) check_account && echo "profile $profile signs in to SVP_AWS_STG_ACCOUNT_ID" ;;
  groups) check_account && cmd_groups ;;
  run) check_account && cmd_run "$@" ;;
  start) check_account && cmd_start "$@" ;;
  result) check_account && cmd_result "${1:-}" ;;
  reshard) check_account && cmd_reshard "${1:-}" ;;
  failover) check_account && cmd_failover "${1:-}" "${2:-}" ;;
  events) check_account && cmd_events "${1:-}" ;;
  *) fail "usage: kv-session.sh check | groups | run ARGS... | start ARGS... | result ID | reshard SHARDS |" \
    "failover cme|cmd NODE_GROUP | events [MINUTES]" ;;
esac
