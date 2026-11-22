#!/usr/bin/env bash
# Self-test of kv-session.sh with fake aws, date and sleep first on PATH: no network, no account. Covers the account
# check, the endpoints and slots behind each kv.sh argument, the SSM round trip waiting and in the background, the
# reshard time from a series of statuses, the failover of one node group, and the profile and Region of every call.
# Usage: bash scripts/kv-session-test.sh
# shellcheck disable=SC2016 # bash -c '...' and the fakes expand their own arguments, not this shell
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
state=$work/state
log=$work/calls.log
mkdir -p "$bin" "$state"
failures=0
cid=11111111-2222-3333-4444-555555555555
cfg=clustercfg.svp-lab-ds-cme.abc123.apse1.cache.amazonaws.com
primary=master.svp-lab-ds-cmd.abc123.apse1.cache.amazonaws.com
export REAL_DATE
REAL_DATE=$(command -v date)

unset SVP_AWS_STG_ACCOUNT_ID AWS_PAGER AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export FAKE_LOG=$log FAKE_DIR=$state FAKE_CID=$cid FAKE_CFG=$cfg FAKE_PRIMARY=$primary

# The learner's machine signs in with profile anhnv-stg and names the Region on every call. svp-lab-ds-cme has node
# groups 0001 and 0002, svp-lab-ds-cmd one, 0001; a group listed in $FAKE_DIR/off does not exist. The reshard reads
# "<status>\t<shards>" from $FAKE_DIR/shards in turn, then its last line. The command invocation answers the statuses
# of $FAKE_DIR/statuses in turn, then its last one.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ "$1 $2 $3 $4" = "--profile anhnv-stg --region ap-southeast-1" ] ||
  { echo "fake aws: not --profile anhnv-stg --region ap-southeast-1 first" >&2; exit 97; }
shift 4
arg() { local k=$1; shift; while [ $# -gt 1 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
# next FILE: the next line of FILE, then its last.
next() {
  local n
  n=$(($(cat "$1.n" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$1.n"
  sed -n "${n}p" "$1" | grep . || tail -n 1 "$1"
}
case "$1 $2" in
  "sts get-caller-identity") cat "$FAKE_DIR/account" 2>/dev/null || echo 000000000000 ;;
  "ec2 describe-instances") echo i-0123456789abcdef0 ;;
  "elasticache describe-replication-groups")
    g=$(arg --replication-group-id "$@")
    q=$(arg --query "$@")
    grep -qx "$g" "$FAKE_DIR/off" 2>/dev/null && { echo "An error occurred (ReplicationGroupNotFoundFault)" >&2; exit 254; }
    ngs="0001"
    [ "$g" != svp-lab-ds-cme ] || ngs="0001 0002"
    case $q in
      *ConfigurationEndpoint.Address) echo "$FAKE_CFG" ;;
      *"NodeGroups[0].PrimaryEndpoint.Address") echo "$FAKE_PRIMARY" ;;
      *"[Status, length(NodeGroups)]") next "$FAKE_DIR/shards" ;;
      *Status) echo available ;;
      *"].Slots | [0]")
        ng=${q#*NodeGroupId==\'}; ng=${ng%%\'*}
        case "$g $ng" in
          "svp-lab-ds-cme 0001") echo 0-8191 ;;
          "svp-lab-ds-cme 0002") echo 8192-16383 ;;
          *) echo None ;;
        esac ;;
      *"].NodeGroupId | [0]")
        ng=${q#*NodeGroupId==\'}; ng=${ng%%\'*}
        case " $ngs " in *" $ng "*) echo "$ng" ;; *) echo None ;; esac ;;
      *"NodeGroups[].["*)
        for ng in $ngs; do printf '%s\tavailable\t%s\t%s-%s-001,%s-%s-002\n' "$ng" None "$g" "$ng" "$g" "$ng"; done ;;
      *) echo "fake aws: unexpected query $q" >&2; exit 98 ;;
    esac ;;
  "elasticache modify-replication-group-shard-configuration") echo modifying ;;
  "elasticache test-failover") echo available ;;
  "elasticache describe-events")
    printf '2026-11-18T01:00:00.000Z\tsvp-lab-ds-cme-0002-001\tFailover from master node svp-lab-ds-cme-0002-001 to replica node svp-lab-ds-cme-0002-002 completed\n' ;;
  "ssm send-command") echo "$FAKE_CID" ;;
  "ssm get-command-invocation")
    status=$(next "$FAKE_DIR/statuses")
    jq -cn --arg s "$status" '{Status: $s, StandardOutputContent: "remote out\n", StandardErrorContent: "remote err\n"}' ;;
  *) echo "fake aws: unexpected call $*" >&2; exit 98 ;;
esac
EOF

# date -u +%s reads $FAKE_DIR/clock, which sleep N moves N seconds; any other form is the real date.
cat >"$bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "-u +%s" ]; then cat "$FAKE_DIR/clock"; exit 0; fi
exec "$REAL_DATE" "$@"
EOF
cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >>"$FAKE_LOG"
echo $(($(cat "$FAKE_DIR/clock") + ${1%.*})) >"$FAKE_DIR/clock"
EOF
chmod +x "$bin"/*
export PATH=$bin:$PATH

pass() { printf 'ok    %s\n' "$1"; }
bad() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}
expect() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else bad "$name"; fi
}
session() { SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$src/kv-session.sh" "$@" >"$work/out" 2>&1; }
refused() { ! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$src/kv-session.sh" "$@" >"$work/out" 2>&1; }
# reset keeps every call made so far in all.log, for the check of profile and Region at the end.
reset() {
  rm -rf "${state:?}"/*
  [ ! -e "$log" ] || cat "$log" >>"$work/all.log"
  : >"$log"
  echo 1800000000 >"$state/clock"
  printf 'InProgress\nSuccess\n' >"$state/statuses"
  printf 'available\t2\n' >"$state/shards"
}
# sent: the command the loader got, as the SSM parameters carry it.
sent() { sed -n 's/.*--parameters {"commands":\["\([^"]*\)"\],"executionTimeout":\["\([0-9]*\)"\]}.*/\1 (timeout \2)/p' "$log"; }

# --- account check ----------------------------------------------------------------------------------------------------
reset
echo 111111111111 >"$state/account"
expect "another account is refused" refused failover cme 0001
expect "the refusal names the profile" grep -q 'profile anhnv-stg signs in to 111111111111' "$work/out"
expect "nothing but the identity call runs for another account" \
  bash -c '[ "$(wc -l <"$1" | tr -d " ")" = 1 ] && grep -q "sts get-caller-identity" "$1"' _ "$log"
reset
expect "a missing account variable is refused" bash -c '! bash "$1" check >/dev/null 2>&1' _ "$src/kv-session.sh"
expect "no aws call runs without the account variable" bash -c '[ ! -s "$1" ]' _ "$log"

# --- reshard: the time from the accepted request to available with the new count -------------------------------------
reset
printf 'available\t2\nmodifying\t2\nmodifying\t3\navailable\t3\n' >"$state/shards"
session reshard 3
expect "the reshard goes through the shard configuration of svp-lab-ds-cme, applied at once" \
  grep -q '^aws --profile anhnv-stg --region ap-southeast-1 elasticache modify-replication-group-shard-configuration --replication-group-id svp-lab-ds-cme --node-group-count 3 --apply-immediately ' \
  "$log"
expect "the reshard prints when it was accepted" \
  grep -q '^reshard of svp-lab-ds-cme from 2 to 3 shards accepted at 2027-01-15T08:00:00Z, status modifying$' "$work/out"
expect "the reshard time runs from the accepted request to the first read of available with three shards" \
  grep -q '^reshard time: 30 s, from 2027-01-15T08:00:00Z to 2027-01-15T08:00:30Z (status read every 10 s: resolution)$' \
  "$work/out"
expect "each change of status is printed with its time" grep -q '^2027-01-15T08:00:30Z status available, 3 shards$' "$work/out"
expect "the reshard reminds the learner to set the variable" grep -q '^set shards = 3 in valkey/valkey.auto.tfvars' "$work/out"
expect "the reshard ends with the node groups" grep -q '^  node group 0002 available slots all nodes ' "$work/out"

reset
printf 'available\t2\nmodifying\t2\navailable\t2\navailable\t3\n' >"$state/shards"
session reshard 3
expect "available with the old count is not the end of the reshard" grep -q '^reshard time: 30 s, ' "$work/out"

reset
printf 'available\t2\nmodifying\t3\n' >"$state/shards"
expect "a reshard that never ends in time fails" refused reshard 3
expect "it says so without a reshard time" \
  bash -c 'grep -q "svp-lab-ds-cme still modifying with 3 shards after 3600 s: no reshard time" "$1" &&
    ! grep -q "^reshard time" "$1"' _ "$work/out"
expect "the reshard is requested once" bash -c '[ "$(grep -c modify-replication-group-shard-configuration "$1")" = 1 ]' \
  _ "$log"

reset
expect "a reshard to fewer shards is refused" refused reshard 1
expect "a reshard past five shards is refused" refused reshard 6
printf 'modifying\t2\n' >"$state/shards"
: >"$state/shards.n"
expect "a reshard of a group that is not available is refused" refused reshard 3
expect "nothing is modified for a refused reshard" bash -c '! grep -q modify-replication-group "$1"' _ "$log"

# --- failover: one call on the right node group -----------------------------------------------------------------------
reset
session failover cme 0002
expect "a shard of cme fails over by its node group" \
  grep -q '^aws --profile anhnv-stg --region ap-southeast-1 elasticache test-failover --replication-group-id svp-lab-ds-cme --node-group-id 0002 ' \
  "$log"
expect "the failover is requested once" bash -c '[ "$(grep -c "elasticache test-failover" "$1")" = 1 ]' _ "$log"
expect "the failover prints the time it was requested" \
  grep -q '^failover of svp-lab-ds-cme node group 0002 requested at 2027-01-15T08:00:00Z$' "$work/out"
reset
session failover cmd 0001
expect "cmd fails over its one node group" \
  grep -q 'elasticache test-failover --replication-group-id svp-lab-ds-cmd --node-group-id 0001 ' "$log"
reset
expect "a node group the group lacks is refused" refused failover cmd 0002
expect "a node group that is not four digits is refused" refused failover cme 2
expect "a failover of anything else is refused" refused failover rds 0001
expect "nothing fails over for a refused name" bash -c '! grep -q test-failover "$1"' _ "$log"

# --- kv.sh arguments: group names become endpoints, a node group its slots --------------------------------------------
reset
session run probe 600 cme 0002
expect "a probe on a shard of cme sends the configuration endpoint and the node group's slots" \
  [ "$(sent)" = "/opt/svp-lab-ds/kv.sh probe 600 $cfg 8192-16383 (timeout 3600)" ]
expect "run prints the loader's output once the command ends" grep -qx 'remote out' "$work/out"
reset
session run probe 600 cmd
expect "a probe on cmd sends the primary endpoint and no slots" \
  [ "$(sent)" = "/opt/svp-lab-ds/kv.sh probe 600 $primary (timeout 3600)" ]
reset
session run bench 300 cme
expect "bench on cme runs as a cluster client" \
  [ "$(sent)" = "/opt/svp-lab-ds/kv.sh bench 300 $cfg cluster (timeout 3600)" ]
reset
session run bench 300 cmd
expect "bench on cmd runs as a plain client" \
  [ "$(sent)" = "/opt/svp-lab-ds/kv.sh bench 300 $primary plain (timeout 3600)" ]
reset
session run client
expect "client gets both endpoints" [ "$(sent)" = "/opt/svp-lab-ds/kv.sh client $cfg $primary (timeout 3600)" ]
reset
session run window /var/lib/svp-lab-ds/probe.Ab12Cd/probe.log
expect "window takes a probe log path" \
  [ "$(sent)" = "/opt/svp-lab-ds/kv.sh window /var/lib/svp-lab-ds/probe.Ab12Cd/probe.log (timeout 3600)" ]
reset
session run rates /var/lib/svp-lab-ds/bench.Ab12Cd/bench.log
expect "rates takes a bench log path" \
  [ "$(sent)" = "/opt/svp-lab-ds/kv.sh rates /var/lib/svp-lab-ds/bench.Ab12Cd/bench.log (timeout 3600)" ]
reset
expect "a probe on cme without a node group is refused" refused run probe 600 cme
expect "a probe on a node group cme lacks is refused" refused run probe 600 cme 0003
expect "a probe on another target is refused" refused run probe 600 aurora
expect "window refuses another path" refused run window /etc/passwd
expect "rates refuses a probe log" refused run rates /var/lib/svp-lab-ds/probe.Ab12Cd/probe.log
expect "rates refuses another path" refused run rates /etc/passwd
expect "an argument the remote shell reads is refused" refused run probe '600;id' cmd
expect "an unknown kv.sh command is refused" refused run flush cme
expect "nothing is sent for refused arguments" bash -c '! grep -q "ssm send-command" "$1"' _ "$log"
reset
echo svp-lab-ds-cme >"$state/off"
expect "a group that is down sends nothing" refused run bench 60 cme
expect "it says the part is not up" grep -q 'is the part up' "$work/out"
expect "nothing is sent for a group that is down" bash -c '! grep -q "ssm send-command" "$1"' _ "$log"

# --- start and result ------------------------------------------------------------------------------------------------
reset
session start probe 900 cme 0001
expect "start returns the command id at once" grep -q "command $cid; read it with kv-session.sh result $cid" "$work/out"
expect "start does not wait for the command" bash -c '! grep -q get-command-invocation "$1"' _ "$log"
reset
session result "$cid"
expect "result while the command runs says so" grep -q "^command $cid still running at " "$work/out"
session result "$cid"
expect "result prints the output once it ended" grep -qx 'remote out' "$work/out"
reset
printf 'Failed\n' >"$state/statuses"
expect "a failed command fails the result" refused result "$cid"
expect "a failed command shows the loader's error" grep -qx 'remote err' "$work/out"

# --- groups and events ------------------------------------------------------------------------------------------------
reset
session groups
expect "groups lists each group with its endpoint" \
  bash -c 'grep -qx "svp-lab-ds-cme: available $1" "$3" && grep -qx "svp-lab-ds-cmd: available $2" "$3"' _ "$cfg" \
  "$primary" "$work/out"
expect "groups lists the node groups and their nodes" \
  grep -q '^  node group 0001 available slots all nodes svp-lab-ds-cme-0001-001,svp-lab-ds-cme-0001-002$' "$work/out"
reset
session events 30
expect "events reads the lab's events of the last minutes" \
  grep -q '^aws --profile anhnv-stg --region ap-southeast-1 elasticache describe-events --duration 30 ' "$log"
expect "events prints one line per event" grep -q '^2026-11-18T01:00:00.000Z  svp-lab-ds-cme-0002-001  Failover' \
  "$work/out"

# --- every call carries the profile and the Region --------------------------------------------------------------------
reset
expect "every aws call names the profile and the Region first" \
  bash -c '! grep "^aws" "$1" | grep -qv "^aws --profile anhnv-stg --region ap-southeast-1 "' _ "$work/all.log"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed" >&2
  exit 1
fi
echo "all passed"
