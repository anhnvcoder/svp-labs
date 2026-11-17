#!/usr/bin/env bash
# Self-test of pgload.sh with fake aws, psql, runuser, date, sleep and setsid first on PATH (jq is the host's): no
# network, no account. Covers CDC lag samples, a lag that does not drain before the deadline, a checksum mismatch,
# validation that fails or never ends, a target that refuses the first writes, and the TLS, Region and password rules.
# Usage: bash scripts/pgload-test.sh
# shellcheck disable=SC2016 # bash -c '...' and the fakes expand their own arguments, not this shell
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
bin=$work/bin
state=$work/state
log=$work/calls.log
export REAL_SLEEP REAL_DATE
REAL_SLEEP=$(command -v sleep)
REAL_DATE=$(command -v date)
mkdir -p "$bin" "$state" "$work/run" "$work/tmp"
failures=0

# A writer left running by a failed check must not outlive the test.
cleanup() {
  local pid
  pid=$(cat "$work/run/writer.pid" 2>/dev/null) && kill "$pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export FAKE_LOG=$log FAKE_DIR=$state TMPDIR=$work/tmp
export FAKE_PW_SRC=FakeSourcePassw0rdForTheTestOnly FAKE_PW_TGT=FakeTargetPassw0rdForTheTestOnly
export SVP_DMS_CONF=$work/svp-lab-dms.conf
cat >"$SVP_DMS_CONF" <<EOF
SVP_DMS_REGION=ap-southeast-1
SVP_DMS_DB=svp_engagement
SVP_DMS_USER=svp_dms
SVP_DMS_PARAMETER=/svp-lab-dms/source/svp_dms-password
SVP_DMS_TARGET_SECRET=svp-lab-dms-target
SVP_DMS_CA=/opt/svp-lab-dms/rds-ca.pem
SVP_DMS_RUN=$work/run
EOF
arn=arn:aws:dms:ap-southeast-1:000000000000:task:ABCDEFGHIJKLMNOPQRSTUVWXYZ

# bump FILE: adds one to the counter in FILE and prints it; the rename keeps a concurrent reader from an empty file.
cat >"$bin/fake-lib" <<'EOF'
bump() {
  local n
  n=$(($(cat "$1" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$1.$$" && mv -f "$1.$$" "$1"
  echo "$n"
}
EOF

# The instance runs with the credentials of its role: a profile is a mistake, a missing Region too. The parameter
# read fails $FAKE_DIR/ssm.fail times first, as while a new role reaches IAM.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
echo "aws $*" >>"$FAKE_LOG"
case " $* " in *" --profile "*) echo "fake aws: --profile on an instance" >&2; exit 97 ;; esac
case " $* " in *" --region ap-southeast-1 "*) ;; *) echo "fake aws: no --region ap-southeast-1" >&2; exit 97 ;; esac
case "$1 $2" in
  "ssm get-parameter")
    [ "$(bump "$FAKE_DIR/ssm.n")" -gt "$(cat "$FAKE_DIR/ssm.fail" 2>/dev/null || echo 0)" ] ||
      { echo "AccessDeniedException" >&2; exit 254; }
    printf '%s\t3\n' "$FAKE_PW_SRC" ;;
  "secretsmanager get-secret-value")
    printf '{"username":"svp_admin","password":"%s","port":"5432",' "$FAKE_PW_TGT"
    echo '"host":"svp-lab-dms-target.abc.ap-southeast-1.rds.amazonaws.com"}' ;;
  "dms describe-table-statistics") cat "$FAKE_DIR/stats" ;;
  "dms stop-replication-task") echo stopping ;;
  *) echo "fake aws: unexpected call $*" >&2; exit 98 ;;
esac
EOF

# psql: no host= is the local source, a host= the target. It logs its arguments and the password file, keeps what came
# on stdin per side, and answers from $FAKE_DIR: when a heartbeat row shows up on the target (visible_after: on the
# Nth poll, or never), the checksums (sum.<side>.<table>), and how many target write batches fail first (target_fail).
cat >"$bin/psql" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
args="$*" cmd= file= side=source
while [ $# -gt 0 ]; do
  case $1 in
    -c) cmd=$2; shift ;;
    -f) file=$2; shift ;;
    host=*) side=target ;;
  esac
  shift
done
stdin=
[ "$file" != - ] || stdin=$(cat)
pass=
[ -z "${PGPASSFILE:-}" ] || pass="pgpass $(ls -l "$PGPASSFILE" | cut -c1-10) $(cat "$PGPASSFILE")"
echo "psql $side | $args | $pass" >>"$FAKE_LOG"
[ -z "$stdin" ] || printf '%s\n' "$stdin" >>"$FAKE_DIR/stdin.$side"
case $cmd in
  "INSERT INTO heartbeat"*) printf '00000000-0000-0000-0000-%012d\n' "$(bump "$FAKE_DIR/hb.n")" ;;
  "SELECT count(*) FROM heartbeat WHERE id = "*)
    id=${cmd##*= \'}
    k=$(bump "$FAKE_DIR/seen.${id%\'}")
    after=$(cat "$FAKE_DIR/visible_after" 2>/dev/null || echo 2)
    if [ "$after" != never ] && [ "$k" -ge "$after" ]; then echo 1; else echo 0; fi ;;
  "SELECT count(*) || ' ' ||"*) cat "$FAKE_DIR/sum.$side.${cmd##* FROM }" 2>/dev/null || echo "100 12345" ;;
  *"FROM pg_replication_slots WHERE active") cat "$FAKE_DIR/active" 2>/dev/null || echo 0 ;;
  "SELECT count(*) FROM "*) echo 7 ;;
esac
if [ "$side" = target ] && grep -q '^INSERT INTO view_counts' <<<"$stdin"; then
  [ "$(bump "$FAKE_DIR/target_writes")" -gt "$(cat "$FAKE_DIR/target_fail" 2>/dev/null || echo 0)" ] ||
    { echo "psql: error: connection to server failed" >&2; exit 2; }
fi
exit 0
EOF

# date: +%s%3N reads a clock that moves $FAKE_DIR/step ms (default 100) at each call; the rest is the real date.
cat >"$bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "+%s%3N" ]; then
  v=$(cat "$FAKE_DIR/clock")
  echo "$v"
  echo $((v + $(cat "$FAKE_DIR/step" 2>/dev/null || echo 100))) >"$FAKE_DIR/clock.$$"
  mv -f "$FAKE_DIR/clock.$$" "$FAKE_DIR/clock"
  exit 0
fi
if [ "${1:-}" = -u ] && [ "${2:-}" = -d ]; then
  "$REAL_DATE" -u -r "${3#@}" "$4" 2>/dev/null || "$REAL_DATE" -u -d "$3" "$4"
  exit
fi
exec "$REAL_DATE" "$@"
EOF

printf '#!/bin/sh\necho "sleep $*" >>"$FAKE_LOG"\n"$REAL_SLEEP" 0.01\n' >"$bin/sleep"
printf '#!/bin/sh\nexec "$@"\n' >"$bin/setsid"
printf '#!/bin/sh\necho "runuser $1 $2" >>"$FAKE_LOG"\nwhile [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n' \
  >"$bin/runuser"
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
pg() { bash "$src/pgload.sh" "$@"; }
out() { cat "$work/out"; }
# reset: a fresh fake world. The writer left by a case is stopped first, and its last batch given time to end: the
# fake setsid leaves the writer's psql outside a process group of its own.
reset() {
  if [ -e "$work/run/writer.pid" ]; then
    pg stop >/dev/null 2>&1 || true
    "$REAL_SLEEP" 0.3
  fi
  rm -rf "${state:?}"/* "${work:?}/run"/*
  : >"$log"
  echo 1800000000000 >"$state/clock"
  echo 10 >"$work/run/views"
  printf '%s\t%s\t0\t0\t0\n' view_counts Validated likes Validated heartbeat Validated >"$state/stats"
}
running() { kill -0 "$(cat "$work/run/writer.pid" 2>/dev/null || echo 0)" 2>/dev/null; }
# epoch LABEL: the epoch ms in parentheses on the line that starts with LABEL.
epoch() { sed -n "s/^$1 [^ ]* (\([0-9]*\)).*/\1/p" "$work/out"; }

# --- password: retried while IAM is new, set through stdin, never on a command line -----------------------------------
reset
echo 2 >"$state/ssm.fail"
pg password >"$work/out" 2>&1
expect "password reports the parameter and its version" \
  grep -q '^password of svp_dms set from /svp-lab-dms/source/svp_dms-password version 3$' "$work/out"
expect "the parameter read is retried until IAM lets it" [ "$(grep -c '^aws ssm get-parameter' "$log")" = 3 ]
expect "the parameter is read decrypted, with the Region and no profile" \
  grep -q '^aws ssm get-parameter --name /svp-lab-dms/source/svp_dms-password --with-decryption .* --region ap-southeast-1$' \
  "$log"
expect "ALTER ROLE goes to psql on stdin, as postgres" \
  bash -c 'grep -qx "ALTER ROLE svp_dms PASSWORD '\''$1'\'';" "$2" && grep -q "^runuser -u postgres" "$3"' \
  _ "$FAKE_PW_SRC" "$state/stdin.source" "$log"
expect "the password is on no command line" bash -c '! grep "^psql" "$1" | grep -q "$2"' _ "$log" "$FAKE_PW_SRC"
expect "the password is not in the output" bash -c '! grep -q "$1" "$2"' _ "$FAKE_PW_SRC" "$work/out"

reset
echo 99 >"$state/ssm.fail"
expect "a parameter that never reads fails" bash -c '! bash "$1" password >"$2" 2>&1' _ "$src/pgload.sh" "$work/out"
expect "the failure names the parameter" grep -q 'cannot read a password from /svp-lab-dms/source/svp_dms-password' \
  "$work/out"

reset
pg init >"$work/out" 2>&1
expect "init creates the database and a superuser DMS user when missing" \
  bash -c 'grep -q "CREATE DATABASE svp_engagement.*\\\\gexec" "$1" && grep -q "CREATE ROLE svp_dms LOGIN SUPERUSER.*\\\\gexec" "$1"' \
  _ "$state/stdin.source"

# --- setup: the schema on both sides, the sample rows on the source only ----------------------------------------------
reset
rm -f "$work/run/views"
pg setup 10 20 >"$work/out" 2>&1
expect "setup creates the three tables on both sides" \
  bash -c 'for s in source target; do [ "$(grep -c "^CREATE TABLE IF NOT EXISTS" "$1/stdin.$s")" = 3 ] || exit 1; done' _ \
  "$state"
expect "heartbeat.kind is varchar, which DMS does not move as a LOB" grep -q 'kind varchar(16) NOT NULL' "$state/stdin.target"
expect "the sample rows go to the source only" \
  bash -c 'grep -q "generate_series(1, 10)" "$1/stdin.source" && grep -q "generate_series(1, 20)" "$1/stdin.source" &&
    ! grep -q "^INSERT" "$1/stdin.target"' _ "$state"
expect "setup records the number of videos for the writer" [ "$(cat "$work/run/views")" = 10 ]
expect "setup prints the row counts of both sides" [ "$(grep -c '^source .* rows; target .* rows$' "$work/out")" = 3 ]
expect "every target connection is verify-full against the RDS bundle" \
  bash -c '[ "$(grep -c "^psql target" "$1")" -gt 0 ] && ! grep "^psql target" "$1" |
    grep -v -q "sslmode=verify-full sslrootcert=/opt/svp-lab-dms/rds-ca.pem"' _ "$log"
expect "the target password sits in a private password file" \
  bash -c '! grep "^psql target" "$1" | grep -v -q "pgpass -rw------- \*:\*:\*:svp_admin:$2"' _ "$log" "$FAKE_PW_TGT"
expect "the target password is on no command line" \
  bash -c '! grep "^psql target" "$1" | cut -d"|" -f2 | grep -q "$2"' _ "$log" "$FAKE_PW_TGT"
expect "the password file is gone after the run" [ -z "$(ls -A "$work/tmp")" ]
expect "setup refuses a count that is not a number" \
  bash -c '! bash "$1" setup ten >/dev/null 2>&1' _ "$src/pgload.sh"

# --- lag: a row written at the source and seen at the target, on one clock --------------------------------------------
reset
echo 3 >"$state/visible_after"
pg lag 2 >"$work/out" 2>&1
expect "each sample is the time from the write to the poll that saw the row" \
  [ "$(grep -c '^lag [12]: 300 ms (written .*Z, seen on the target .*Z)$' "$work/out")" = 2 ]
expect "the summary gives min, median, max and mean in ms" \
  grep -q '^CDC lag over 2 samples: min 300 ms, median 300 ms, max 300 ms, mean 300 ms$' "$work/out"
expect "each sample polls the target for its own row" \
  [ "$(grep -c "^psql target .*WHERE id = '00000000-0000-0000-0000-000000000002'" "$log")" = 3 ]

reset
echo never >"$state/visible_after"
expect "a row that never reaches the target fails the lag" \
  bash -c '! SVP_DMS_SAMPLE_LIMIT=1 bash "$1" lag 1 >"$2" 2>&1' _ "$src/pgload.sh" "$work/out"
expect "the missed sample is reported with its limit" grep -q '^lag 1: not seen on the target after 1 s' "$work/out"
expect "the failure counts the missed samples" grep -q '1 of 1 samples never reached the target' "$work/out"

# --- compare: row count and checksum per table ------------------------------------------------------------------------
reset
pg compare >"$work/out" 2>&1
expect "equal sides match on every table" [ "$(grep -c '^compare .*: match, 100 rows, checksum 12345$' "$work/out")" = 3 ]
echo "100 99999" >"$state/sum.target.likes"
expect "a checksum mismatch fails compare" bash -c '! bash "$1" compare >"$2" 2>&1' _ "$src/pgload.sh" "$work/out"
expect "the mismatch names the table and both sides" \
  grep -q '^compare likes: MISMATCH, source 100 rows checksum 12345, target 100 rows checksum 99999$' "$work/out"

# --- writer: start, a second start, stop ------------------------------------------------------------------------------
reset
pg start 8 >"$work/out" 2>&1
expect "start runs a writer on the source at the given rate" \
  bash -c 'grep -q "^writer started on the source, 8 statements per second" "$1" && [ "$(cat "$2")" = "source 8" ]' _ \
  "$work/out" "$work/run/writer.conf"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q $'\tok' "$work/run/writer.log" 2>/dev/null && break; "$REAL_SLEEP" 0.2; done
expect "a batch holds RATE statements on the source" \
  [ "$(grep -c -e '^INSERT' -e '^WITH' "$state/stdin.source" | awk '{print ($1 % 8 == 0 && $1 > 0)}')" = 1 ]
expect "the writer logs ok batches with their side" grep -q $'\tsource\tok$' "$work/run/writer.log"
pid=$(cat "$work/run/writer.pid")
pg start 8 >"$work/out" 2>&1
expect "a second start keeps the running writer" grep -q "^writer already running, pid $pid" "$work/out"
pg stop >"$work/out" 2>&1
expect "stop ends the writer" bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid"
expect "stop removes the pid file" [ ! -e "$work/run/writer.pid" ]
expect "start without setup fails" bash -c 'rm -f "$1/views"; ! bash "$2" start >/dev/null 2>&1' _ "$work/run" \
  "$src/pgload.sh"

# --- cutover: the full path -------------------------------------------------------------------------------------------
reset
pg start 4 >/dev/null 2>&1
pg cutover "$arn" 30 >"$work/out" 2>&1
expect "the cutover ends with the downtime" grep -Eq '^Downtime cutover: [0-9]+\.[0-9]{3} s$' "$work/out"
t0=$(epoch T0)
t1=$(epoch T1)
expect "the downtime runs from T0, the stop at the source, to T1, the first write at the target" \
  grep -qx "Downtime cutover: $(printf '%d.%03d' $(((t1 - t0) / 1000)) $(((t1 - t0) % 1000))) s" "$work/out"
# in_order FILE PATTERN...: each pattern matches a line, each after the line of the pattern before it.
in_order() {
  local file=$1 last=0 n
  shift
  for p in "$@"; do
    n=$(grep -n -m 1 -e "$p" "$file" | cut -d: -f1)
    [ -n "$n" ] && [ "$n" -gt "$last" ] || return 1
    last=$n
  done
}
expect "the steps run in order" in_order "$work/out" '^T0 ' '^lag drained' '^validation:' '^compare heartbeat: match' \
  '^task stopping' '^T1 ' '^Downtime cutover'
expect "the task is stopped once, by its ARN, with the Region" \
  [ "$(grep -c "^aws dms stop-replication-task --replication-task-arn $arn --region ap-southeast-1 " "$log")" = 1 ]
expect "the writer now runs on the target" bash -c 'running() { kill -0 "$(cat "$1")" 2>/dev/null; }; running "$1" &&
  [ "$(cat "$2")" = "target 4" ]' _ "$work/run/writer.pid" "$work/run/writer.conf"
expect "the validation statistics are read with the task ARN and the Region" \
  grep -q "^aws dms describe-table-statistics --replication-task-arn $arn .*--region ap-southeast-1 " "$log"

# --- cutover: the lag does not drain before the deadline --------------------------------------------------------------
reset
echo never >"$state/visible_after"
pg start 4 >/dev/null 2>&1
expect "a lag that never drains aborts the cutover" \
  bash -c '! bash "$1" cutover "$2" 2 >"$3" 2>&1' _ "$src/pgload.sh" "$arn" "$work/out"
expect "the abort names the fence and the limit" grep -q '^cutover aborted: lag not drained: fence .* not on the target after 2 s' \
  "$work/out"
expect "the writes resume at the source" bash -c 'grep -q "writes resumed at the source" "$1" && kill -0 "$(cat "$2")" &&
  [ "$(cat "$3")" = "source 4" ]' _ "$work/out" "$work/run/writer.pid" "$work/run/writer.conf"
expect "the task keeps running and nothing is written at the target" \
  bash -c '! grep -q "stop-replication-task" "$1" && [ ! -e "$2/target_writes" ]' _ "$log" "$state"

# --- cutover: a checksum differs --------------------------------------------------------------------------------------
reset
echo "100 99999" >"$state/sum.target.likes"
pg start 4 >/dev/null 2>&1
expect "a checksum mismatch aborts the cutover" \
  bash -c '! bash "$1" cutover "$2" 30 >"$3" 2>&1' _ "$src/pgload.sh" "$arn" "$work/out"
expect "the abort follows the mismatched table" \
  bash -c 'grep -q "^compare likes: MISMATCH" "$1" && grep -q "^cutover aborted: row counts or checksums differ" "$1"' _ \
  "$work/out"
expect "after a mismatch the task keeps running and the source takes the writes" \
  bash -c '! grep -q "stop-replication-task" "$1" && [ "$(cat "$2")" = "source 4" ]' _ "$log" "$work/run/writer.conf"

# --- cutover: validation fails, or never ends -------------------------------------------------------------------------
reset
printf '%s\t%s\t%s\t%s\t%s\n' view_counts Validated 0 0 0 likes "Mismatched records" 0 2 0 heartbeat Validated 0 0 0 \
  >"$state/stats"
pg start 4 >/dev/null 2>&1
expect "a validation mismatch aborts the cutover" \
  bash -c '! bash "$1" cutover "$2" 30 >"$3" 2>&1' _ "$src/pgload.sh" "$arn" "$work/out"
expect "the abort names the validation" grep -q '^cutover aborted: validation reports mismatched or failed records' \
  "$work/out"

reset
printf '%s\t%s\t%s\t0\t0\n' view_counts Validated 0 likes "Pending records" 4 heartbeat Validated 0 >"$state/stats"
pg start 4 >/dev/null 2>&1
expect "validation still pending at the deadline aborts the cutover" \
  bash -c '! bash "$1" cutover "$2" 2 >"$3" 2>&1' _ "$src/pgload.sh" "$arn" "$work/out"
expect "the abort says the validation is not complete" grep -q '^cutover aborted: validation not complete after 2 s' \
  "$work/out"

# --- cutover: the target refuses the first writes ---------------------------------------------------------------------
reset
echo 2 >"$state/target_fail"
pg start 4 >/dev/null 2>&1
pg cutover "$arn" 30 >"$work/out" 2>&1
expect "the first target write is retried until it succeeds" [ "$(cat "$state/target_writes")" -ge 3 ]
t0=$(epoch T0)
t1=$(epoch T1)
expect "the retries count in the downtime" \
  grep -qx "Downtime cutover: $(printf '%d.%03d' $(((t1 - t0) / 1000)) $(((t1 - t0) % 1000))) s" "$work/out"

# --- cutover: refused before anything changes -------------------------------------------------------------------------
reset
expect "a cutover without a running writer is refused" \
  bash -c '! bash "$1" cutover "$2" >"$3" 2>&1' _ "$src/pgload.sh" "$arn" "$work/out"
expect "the refusal says to start the load" grep -q 'no writer running' "$work/out"
expect "a refused cutover calls no AWS API" bash -c '! grep -q "^aws" "$1"' _ "$log"
expect "a cutover without a task ARN is refused" \
  bash -c '! bash "$1" cutover arn:aws:dms:ap-southeast-1:000000000000:endpoint:X >/dev/null 2>&1' _ "$src/pgload.sh"

# --- slots ------------------------------------------------------------------------------------------------------------
reset
echo 1 >"$state/active"
expect "an active slot is not dropped" bash -c '! bash "$1" drop-slots >"$2" 2>&1' _ "$src/pgload.sh" "$work/out"
expect "the refusal says to stop the task" grep -q 'still active: stop the task first' "$work/out"
echo 0 >"$state/active"
pg drop-slots >"$work/out" 2>&1
expect "inactive slots are dropped" grep -q 'pg_drop_replication_slot' "$log"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
