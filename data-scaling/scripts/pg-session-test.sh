#!/usr/bin/env bash
# Self-test of pg-session.sh with fake aws and sleep first on PATH (jq is the host's): no network, no account. Covers
# the account check, the target names and their endpoints, the SSM round trip waiting and in the background, the
# failover of each engine by its identifier, the metrics and events, and the profile and Region of every call.
# Usage: bash scripts/pg-session-test.sh
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
suffix=abc.ap-southeast-1.rds.amazonaws.com

unset SVP_AWS_STG_ACCOUNT_ID AWS_PAGER AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export FAKE_LOG=$log FAKE_DIR=$state FAKE_CID=$cid FAKE_SUFFIX=$suffix

# The learner's machine signs in with profile anhnv-stg and names the Region on every call. A part listed in
# $FAKE_DIR/off answers as RDS does for a missing resource, a loader listed there as no running instance. The command
# invocation answers the statuses of $FAKE_DIR/statuses in turn, then its last one; error:<code> fails as the CLI does.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ "$1 $2 $3 $4" = "--profile anhnv-stg --region ap-southeast-1" ] ||
  { echo "fake aws: not --profile anhnv-stg --region ap-southeast-1 first" >&2; exit 97; }
shift 4
off() { grep -qx "$1" "$FAKE_DIR/off" 2>/dev/null && { echo "An error occurred (NotFound)" >&2; exit 254; }; return 0; }
arg() { local k=$1; shift; while [ $# -gt 1 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "sts get-caller-identity") cat "$FAKE_DIR/account" 2>/dev/null || echo 000000000000 ;;
  "ec2 describe-instances") grep -qx loader "$FAKE_DIR/off" 2>/dev/null || echo i-0123456789abcdef0 ;;
  "rds describe-db-clusters")
    off aurora
    case "$*" in
      *ReaderEndpoint*) echo "svp-lab-ds-aurora.cluster-ro-$FAKE_SUFFIX" ;;
      *) echo "svp-lab-ds-aurora.cluster-$FAKE_SUFFIX" ;;
    esac ;;
  "rds describe-db-instances")
    id=$(arg --db-instance-identifier "$@")
    case $id in svp-lab-ds-aurora-*) off aurora ;; svp-lab-ds-rds*) off rds ;; esac
    echo "$id.$FAKE_SUFFIX" ;;
  "rds describe-db-proxies") off proxy; echo "svp-lab-ds-proxy.proxy-$FAKE_SUFFIX" ;;
  "ssm send-command") echo "$FAKE_CID" ;;
  "ssm get-command-invocation")
    n=$(($(cat "$FAKE_DIR/inv.n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_DIR/inv.n"
    status=$(sed -n "${n}p" "$FAKE_DIR/statuses")
    [ -n "$status" ] || status=$(tail -n 1 "$FAKE_DIR/statuses")
    case $status in error:*)
      echo "An error occurred (${status#error:}) when calling the GetCommandInvocation operation: fake" >&2; exit 254 ;;
    esac
    jq -cn --arg s "$status" '{Status: $s, StandardOutputContent: "remote out\n", StandardErrorContent: "remote err\n"}' ;;
  "rds failover-db-cluster") echo failing-over ;;
  "rds reboot-db-instance") echo rebooting ;;
  "rds describe-events") printf '2026-11-17T01:00:00.000Z\tStarted cross AZ failover\n' ;;
  "cloudwatch get-metric-statistics") printf '4.0\t1.25\n' ;;
  *) echo "fake aws: unexpected call $*" >&2; exit 98 ;;
esac
EOF
printf '#!/bin/sh\necho "sleep $*" >>"$FAKE_LOG"\n' >"$bin/sleep"
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
session() { SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$src/pg-session.sh" "$@" >"$work/out" 2>&1; }
refused() { ! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$src/pg-session.sh" "$@" >"$work/out" 2>&1; }
reset() {
  rm -rf "${state:?}"/*
  : >"$log"
  printf 'InProgress\nSuccess\n' >"$state/statuses"
}
# sent: the command the loader got, as the SSM parameters carry it.
sent() { sed -n 's/.*--parameters {"commands":\["\([^"]*\)"\],"executionTimeout":\["\([0-9]*\)"\]}.*/\1 (timeout \2)/p' "$log"; }

# --- account check ----------------------------------------------------------------------------------------------------
reset
echo 111111111111 >"$state/account"
expect "another account is refused" refused failover aurora
expect "the refusal names the profile" grep -q 'profile anhnv-stg signs in to 111111111111' "$work/out"
expect "nothing but the identity call runs for another account" \
  bash -c '[ "$(wc -l <"$1" | tr -d " ")" = 1 ] && grep -q "sts get-caller-identity" "$1"' _ "$log"
reset
expect "a missing account variable is refused" bash -c '! bash "$1" check >/dev/null 2>&1' _ "$src/pg-session.sh"
expect "no aws call runs without the account variable" bash -c '[ ! -s "$1" ]' _ "$log"

# --- failover: the right call on the right identifier -----------------------------------------------------------------
reset
session failover aurora
expect "Aurora fails over by its cluster identifier" \
  grep -q '^aws --profile anhnv-stg --region ap-southeast-1 rds failover-db-cluster --db-cluster-identifier svp-lab-ds-aurora ' \
  "$log"
expect "the failover prints the time it was requested" grep -qE '^failover of svp-lab-ds-aurora requested at 20[0-9-]+T' \
  "$work/out"
reset
session failover rds
expect "RDS fails over by a reboot of its primary with --force-failover" \
  grep -q '^aws .* rds reboot-db-instance --db-instance-identifier svp-lab-ds-rds --force-failover ' "$log"
expect "an RDS failover never touches the cluster" bash -c '! grep -q failover-db-cluster "$1"' _ "$log"
reset
expect "a failover of anything else is refused" refused failover rds-replica
expect "nothing fails over for a refused name" bash -c '! grep -q "failover-db-cluster\|reboot-db-instance" "$1"' _ "$log"

# --- targets: names become endpoints, unknown names are refused -------------------------------------------------------
reset
session run probe write 600 proxy aurora-writer
expect "run sends pg.sh with the endpoints of the names, under a timeout of an hour" \
  grep -qx "/opt/svp-lab-ds/pg.sh probe write 600 svp-lab-ds-proxy.proxy-$suffix svp-lab-ds-aurora.cluster-$suffix (timeout 3600)" \
  <(sent)
expect "run waits until the command ends and prints its output" \
  bash -c '[ "$(cat "$1/inv.n")" = 2 ] && grep -qx "remote out" "$2"' _ "$state" "$work/out"
expect "the command goes to the loader found by its Name tag" \
  grep -q 'ec2 describe-instances --filters Name=tag:Name,Values=svp-lab-ds-pg-loader Name=instance-state-name,Values=running' "$log"
expect "the loader is looked up once per run, not at each read" \
  bash -c '[ "$(grep -c "ec2 describe-instances" "$1")" = 1 ]' _ "$log"

reset
session run lag aurora-writer aurora-reader 30
expect "lag takes a writer and a reader" \
  grep -qx "/opt/svp-lab-ds/pg.sh lag svp-lab-ds-aurora.cluster-$suffix svp-lab-ds-aurora.cluster-ro-$suffix 30 (timeout 3600)" \
  <(sent)
reset
session run read rds-replica 50 300
expect "an instance target becomes the instance's address" \
  grep -qx "/opt/svp-lab-ds/pg.sh read svp-lab-ds-rds-replica.$suffix 50 300 (timeout 3600)" <(sent)

reset
expect "an unknown target name is refused" refused run probe write 600 aurora-wrtier
expect "the refusal lists the targets" grep -q "unknown target 'aurora-wrtier': one of aurora-writer aurora-reader" "$work/out"
expect "the refusal is the only error, the empty endpoint goes no further" \
  bash -c '[ "$(grep -c . "$1")" = 1 ] && ! grep -q "holds a character" "$1"' _ "$work/out"
expect "nothing is sent for an unknown target" bash -c '! grep -q "ssm send-command" "$1"' _ "$log"
reset
expect "a host typed by hand is refused" refused run init "svp-lab-ds-aurora.cluster-$suffix"
expect "an unknown pg.sh command is refused" refused run reboot aurora-writer
expect "an argument the remote shell would read is refused" refused run load aurora-writer '100;reboot' 60
expect "nothing is sent for a refused argument" bash -c '! grep -q "ssm send-command" "$1"' _ "$log"
reset
echo proxy >"$state/off"
expect "a target whose part is off is refused" refused run burst proxy 200 60
expect "the refusal says the part may be off" grep -q 'no endpoint for proxy' "$work/out"
expect "nothing is sent when the second target is off" refused run probe write 600 aurora-writer proxy
expect "not even the first target" bash -c '! grep -q "ssm send-command" "$1"' _ "$log"

reset
session run window /var/lib/svp-lab-ds/probe.Ab3xQ9/probe-2.log
expect "window reads a probe log of the loader" \
  grep -qx "/opt/svp-lab-ds/pg.sh window /var/lib/svp-lab-ds/probe.Ab3xQ9/probe-2.log (timeout 3600)" <(sent)
expect "window refuses any other path" refused run window /etc/passwd
expect "window refuses a path that leaves the run directory" refused run window /var/lib/svp-lab-ds/probe.x/../probe-1.log

reset
printf 'InProgress\nFailed\n' >"$state/statuses"
expect "a failed remote command fails run" refused run init aurora-writer
expect "the failure shows the remote error and status" \
  bash -c 'grep -qx "remote err" "$1" && grep -q "command .* ended Failed" "$1"' _ "$work/out"

# --- reading the command: only a command SSM has not recorded yet is waited for ---------------------------------------
reset
printf 'error:InvocationDoesNotExist\nInProgress\nSuccess\n' >"$state/statuses"
session run init aurora-writer
expect "run waits while SSM has not recorded the command it just sent" \
  bash -c '[ "$(cat "$1/inv.n")" = 3 ] && grep -qx "remote out" "$2"' _ "$state" "$work/out"
reset
printf 'error:ExpiredTokenException\nSuccess\n' >"$state/statuses"
expect "any other error of the read ends run at once" refused run init aurora-writer
expect "the error is shown, not taken for a running command" \
  bash -c 'grep -q "(ExpiredTokenException)" "$1" && grep -q "cannot read command $2" "$1" && [ "$(cat "$3/inv.n")" = 1 ]' _ \
  "$work/out" "$cid" "$state"
reset
echo loader >"$state/off"
expect "run without a running loader is refused" refused run init aurora-writer
expect "the refusal names the loader and nothing is sent" \
  bash -c 'grep -q "no running instance svp-lab-ds-pg-loader" "$1" && ! grep -q "ssm " "$2"' _ "$work/out" "$log"

# --- start and result: a run longer than a failover, without waiting --------------------------------------------------
reset
session start probe write 900 proxy aurora-writer
expect "start returns the command id at once" \
  bash -c 'grep -q "started .pg.sh probe write 900 .* command $2; read it with pg-session.sh result $2" "$1"' _ "$work/out" "$cid"
expect "start does not wait for the command" bash -c '! grep -q "get-command-invocation" "$1"' _ "$log"
expect "start gives the command an hour, longer than any probe pg.sh accepts" grep -q '(timeout 3600)$' <(sent)
reset
printf 'InProgress\n' >"$state/statuses"
session result "$cid"
expect "result of a running command says so and returns" grep -q "command $cid still running" "$work/out"
expect "result reads once" bash -c '[ "$(grep -c get-command-invocation "$1")" = 1 ]' _ "$log"
reset
printf 'Success\n' >"$state/statuses"
session result "$cid"
expect "result of an ended command prints its output" grep -qx 'remote out' "$work/out"
expect "result needs a command id" refused result latest
reset
printf 'error:InvocationDoesNotExist\n' >"$state/statuses"
expect "result of a command the loader never had is refused" refused result "$cid"
expect "the refusal says so instead of still running" \
  bash -c 'grep -q "has no command $2" "$1" && ! grep -q "still running" "$1"' _ "$work/out" "$cid"
reset
echo loader >"$state/off"
expect "result without a running loader is refused" refused result "$cid"
expect "result reads nothing without a loader" bash -c '! grep -q "get-command-invocation" "$1"' _ "$log"

# --- endpoints, events, metrics ---------------------------------------------------------------------------------------
reset
echo rds >"$state/off"
session endpoints
expect "endpoints lists every target" \
  bash -c 'grep -qx "aurora-writer svp-lab-ds-aurora.cluster-$2" "$1" && grep -qx "proxy svp-lab-ds-proxy.proxy-$2" "$1"' _ \
  "$work/out" "$suffix"
expect "endpoints marks a part that is off" bash -c 'grep -qx "rds off" "$1" && grep -qx "rds-replica off" "$1"' _ "$work/out"

reset
session events 30
expect "events read the cluster and the instances that fail over" \
  bash -c 'grep -q "describe-events --source-type db-cluster --source-identifier svp-lab-ds-aurora --duration 30" "$1" &&
    grep -q "describe-events --source-type db-instance --source-identifier svp-lab-ds-rds --duration 30" "$1"' _ "$log"
expect "events print time, source and message" grep -q '^2026-11-17T01:00:00.000Z  svp-lab-ds-rds  Started cross AZ failover$' \
  "$work/out"

reset
session metrics lag 20
expect "lag metrics: AuroraReplicaLag of both instances and ReplicaLag of the replica" \
  bash -c 'grep -q "AuroraReplicaLag .*Value=svp-lab-ds-aurora-1 " "$1" && grep -q "AuroraReplicaLag .*Value=svp-lab-ds-aurora-2 " "$1" &&
    grep -q "ReplicaLag --dimensions Name=DBInstanceIdentifier,Value=svp-lab-ds-rds-replica " "$1"' _ "$log"
expect "metrics read one-minute values" grep -q -- '--period 60 --statistics Maximum' "$log"
expect "metrics print the largest and the mean" \
  grep -qE '^ReplicaLag Maximum \(DBInstanceIdentifier,Value=svp-lab-ds-rds-replica\) over .*: largest 4.0, mean 1.25$' "$work/out"
reset
session metrics burst
expect "burst metrics: connections of the DB instances and of the proxy" \
  bash -c 'grep -q "DatabaseConnections --dimensions Name=DBInstanceIdentifier,Value=svp-lab-ds-aurora-1 " "$1" &&
    grep -q "ClientConnections --dimensions Name=ProxyName,Value=svp-lab-ds-proxy " "$1" &&
    grep -q "DatabaseConnections --dimensions Name=ProxyName,Value=svp-lab-ds-proxy " "$1"' _ "$log"
expect "metrics of anything else are refused" refused metrics cpu

expect "every aws call names the profile and the Region" \
  bash -c '! grep "^aws " "$1" | grep -qv "^aws --profile anhnv-stg --region ap-southeast-1 "' _ "$log"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
