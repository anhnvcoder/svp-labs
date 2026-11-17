#!/usr/bin/env bash
# Self-test of session.sh with fake aws and sleep first on PATH (jq is the host's): no network, no account. Covers the
# full load time from DMS dates in several offsets and before the end, the account check, the SSM round trip and its
# failures, the arguments that reach the remote shell, the CDC metrics, and the profile and Region of every call.
# Usage: bash scripts/session-test.sh
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
arn=arn:aws:dms:ap-southeast-1:000000000000:task:ABCDEFGHIJKLMNOPQRSTUVWXYZ

unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export FAKE_LOG=$log FAKE_DIR=$state FAKE_ARN=$arn

# The learner's machine signs in with profile anhnv-stg and names the Region on every call. The command invocation
# answers the statuses of $FAKE_DIR/statuses in turn, then its last one.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ "$1 $2 $3 $4" = "--profile anhnv-stg --region ap-southeast-1" ] ||
  { echo "fake aws: not --profile anhnv-stg --region ap-southeast-1 first" >&2; exit 97; }
shift 4
case "$1 $2" in
  "sts get-caller-identity") cat "$FAKE_DIR/account" 2>/dev/null || echo 000000000000 ;;
  "ec2 describe-instances") echo i-0123456789abcdef0 ;;
  "ssm send-command") echo cmd-1 ;;
  "ssm get-command-invocation")
    n=$(($(cat "$FAKE_DIR/inv.n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_DIR/inv.n"
    status=$(sed -n "${n}p" "$FAKE_DIR/statuses")
    [ -n "$status" ] || status=$(tail -n 1 "$FAKE_DIR/statuses")
    jq -cn --arg s "$status" '{Status: $s, StandardOutputContent: "remote out\n", StandardErrorContent: "remote err\n"}' ;;
  "dms describe-replication-tasks")
    case "$*" in
      *ReplicationTaskArn*) echo "$FAKE_ARN" ;;
      *ReplicationTaskStats\'*|*ReplicationTaskStats) cat "$FAKE_DIR/stats.json" ;;
      *"ReplicationTasks[0].Status"*) cat "$FAKE_DIR/task_status" 2>/dev/null || echo running ;;
      *) printf 'running\tnull\t100\t3\t0\n' ;;
    esac ;;
  "dms start-replication-task") echo starting ;;
  "dms stop-replication-task") echo stopping ;;
  "dms wait") ;;
  "cloudwatch list-metrics") cat "$FAKE_DIR/dims.json" ;;
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
session() { SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$src/session.sh" "$@"; }
reset() {
  rm -rf "${state:?}"/*
  : >"$log"
  printf 'InProgress\nSuccess\n' >"$state/statuses"
}
# stats START FINISH: task statistics as the CLI prints them, FINISH null while the full load runs.
stats() {
  jq -n --arg s "$1" --argjson f "$2" \
    '{FullLoadStartDate: $s, FullLoadFinishDate: $f, FullLoadProgressPercent: 40, TablesLoaded: 3}' >"$state/stats.json"
}

# --- fullload: the time between the two DMS dates, whatever the offset ---------------------------------------------
reset
stats 2026-11-17T01:00:00.123000+00:00 '"2026-11-17T01:03:25.900000+00:00"'
session fullload >"$work/out" 2>&1
expect "the full load time is the finish minus the start, in whole seconds" \
  grep -q '^Full load: 205 s (start 2026-11-17T01:00:00.123000+00:00, finish 2026-11-17T01:03:25.900000+00:00, 3 tables)$' \
  "$work/out"

reset
stats 2026-11-17T08:00:00+07:00 '"2026-11-17T01:01:00Z"'
session fullload >"$work/out" 2>&1
expect "dates in two offsets compare as instants" grep -q '^Full load: 60 s ' "$work/out"

reset
stats 2026-11-16T23:59:30-0230 '"2026-11-17T02:30:30+00:00"'
session fullload >"$work/out" 2>&1
expect "a negative offset without a colon counts too" grep -q '^Full load: 60 s ' "$work/out"

reset
stats 2026-11-17T01:00:00+00:00 null
expect "a full load not finished fails" bash -c '! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$1" fullload >"$2" 2>&1' _ \
  "$src/session.sh" "$work/out"
expect "the failure gives the progress" grep -q '^full load not finished: 40 %, 3 tables loaded' "$work/out"

# --- account check -------------------------------------------------------------------------------------------------
reset
echo 111111111111 >"$state/account"
expect "another account is refused" bash -c '! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$1" run compare >"$2" 2>&1' _ \
  "$src/session.sh" "$work/out"
expect "the refusal names the profile" grep -q 'profile anhnv-stg signs in to 111111111111' "$work/out"
expect "nothing runs on the instance for another account" bash -c '! grep -q "ssm send-command" "$1"' _ "$log"
reset
expect "a missing account variable is refused" bash -c '! bash "$1" run compare >/dev/null 2>&1' _ "$src/session.sh"

# --- run: the SSM round trip ----------------------------------------------------------------------------------------
reset
session run lag 30 >"$work/out" 2>&1
expect "run polls until the command succeeds and prints its output" \
  bash -c '[ "$(cat "$1/inv.n")" = 2 ] && grep -qx "remote out" "$2"' _ "$state" "$work/out"
expect "the command is pgload.sh with the arguments, on the source instance" \
  grep -qF -- '--instance-ids i-0123456789abcdef0 --document-name AWS-RunShellScript --parameters {"commands":["/opt/svp-lab-dms/pgload.sh lag 30"],"executionTimeout":["3600"]}' \
  "$log"
expect "the instance is found by its Name tag" grep -q 'Name=tag:Name,Values=svp-lab-dms-source' "$log"

reset
printf 'InProgress\nFailed\n' >"$state/statuses"
expect "a failed remote command fails run" bash -c '! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$1" run compare >"$2" 2>&1' _ \
  "$src/session.sh" "$work/out"
expect "the failure shows the remote error and status" \
  bash -c 'grep -qx "remote err" "$1" && grep -q "pgload.sh compare. on i-0123456789abcdef0 ended Failed" "$1"' _ "$work/out"

reset
expect "an argument the remote shell would read is refused" \
  bash -c '! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$1" run "lag;reboot" >"$2" 2>&1' _ "$src/session.sh" "$work/out"
expect "nothing is sent for a refused argument" bash -c '! grep -q "ssm send-command" "$1"' _ "$log"

# --- cutover: the task ARN and the limit reach the instance --------------------------------------------------------
reset
session cutover 600 >"$work/out" 2>&1
expect "cutover runs pgload.sh cutover with the task ARN and the limit" \
  grep -qF "{\"commands\":[\"/opt/svp-lab-dms/pgload.sh cutover $arn 600\"],\"executionTimeout\":[\"900\"]}" "$log"
expect "a cutover limit that is not a number is refused" \
  bash -c '! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$1" cutover soon >/dev/null 2>&1' _ "$src/session.sh"

# --- task ----------------------------------------------------------------------------------------------------------
reset
session task start >"$work/out" 2>&1
expect "task start is the first run of the task, by its ARN" \
  grep -q "^aws .* dms start-replication-task --replication-task-arn $arn --start-replication-task-type start-replication " \
  "$log"
reset
session task resume >"$work/out" 2>&1
expect "task resume picks CDC up again" grep -q -- '--start-replication-task-type resume-processing ' "$log"
reset
session task stop >"$work/out" 2>&1
expect "task stop waits until the task is stopped" \
  bash -c 'grep -q "dms stop-replication-task --replication-task-arn $2" "$1" &&
    grep -q "dms wait replication-task-stopped --filters Name=replication-task-arn,Values=$2" "$1"' _ "$log" "$arn"

# --- cleanup: writer, task, slot -------------------------------------------------------------------------------------
reset
session cleanup >"$work/out" 2>&1
expect "cleanup stops the writer, the task, then drops the slot" \
  bash -c 'grep -n -e "pgload.sh stop" -e "stop-replication-task" -e "pgload.sh drop-slots" "$1" | cut -d: -f1 |
    tr "\n" " " | awk "{exit !(NF == 3 && \$1 < \$2 && \$2 < \$3)}"' _ "$log"
reset
echo stopped >"$state/task_status"
session cleanup >"$work/out" 2>&1
expect "cleanup leaves a stopped task alone" bash -c '! grep -q "stop-replication-task" "$1"' _ "$log"

# --- metrics: dimensions as CloudWatch lists them --------------------------------------------------------------------
reset
echo '[{"Name":"ReplicationInstanceIdentifier","Value":"svp-lab-dms"},{"Name":"ReplicationTaskIdentifier","Value":"ABCDEF"}]' \
  >"$state/dims.json"
session metrics 10 >"$work/out" 2>&1
expect "both latency metrics are read with the listed dimensions" \
  [ "$(grep -c -- '--dimensions Name=ReplicationInstanceIdentifier,Value=svp-lab-dms Name=ReplicationTaskIdentifier,Value=ABCDEF ' "$log")" = 2 ]
expect "each metric prints its maximum and average in seconds" \
  bash -c 'grep -q "^CDCLatencySource over the 10 min to .*Z: max 4.0 s, average 1.25 s$" "$1" &&
    grep -q "^CDCLatencyTarget over the 10 min to .*Z: max 4.0 s, average 1.25 s$" "$1"' _ "$work/out"
reset
echo null >"$state/dims.json"
expect "no metric yet fails with a hint" bash -c '! SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$1" metrics >"$2" 2>&1 &&
  grep -q "is the task in CDC" "$2"' _ "$src/session.sh" "$work/out"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
