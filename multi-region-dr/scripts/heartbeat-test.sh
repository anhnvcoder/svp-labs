#!/usr/bin/env bash
# Self-test of heartbeat.sh with fake aws, dig, psql, sleep and setsid first on PATH: no network, no account. Covers
# a CNAME that changes target between two attempts, a host that does not answer, the TLS and timeout of every
# connection, an aws call with --region and no --profile, and a password that never leaves the password file.
# Usage: bash scripts/heartbeat-test.sh
# shellcheck disable=SC2016 # bash -c '...' and the fakes expand their own arguments, not this shell
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
real_sleep=$(command -v sleep)
mkdir -p "$bin" "$work/run" "$work/tmp"
log=$work/calls.log
: >"$log"
failures=0

unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export FAKE_LOG=$log FAKE_DIR=$work TMPDIR=$work/tmp
export SVP_DR_CONF=$work/svp-lab-dr.conf
password=FakePassw0rdOnlyForTheTest
cat >"$SVP_DR_CONF" <<EOF
SVP_DR_REGION=us-east-1
SVP_DR_SECRET_ID=svp-lab-dr-db-master
SVP_DR_NAME=db.svp-lab-dr.internal
SVP_DR_DB=svp_lab
SVP_DR_USER=svp_admin
SVP_DR_CA=/opt/svp-lab-dr/rds-ca.pem
SVP_DR_RUN=$work/run
EOF

# The instance runs with the credentials of its role: a profile is a mistake, a missing Region too.
cat >"$bin/aws" <<EOF
#!/usr/bin/env bash
echo "aws \$*" >>"\$FAKE_LOG"
case " \$* " in *" --profile "*) echo "fake aws: --profile on an instance" >&2; exit 97 ;; esac
case " \$* " in *" --region us-east-1 "*) ;; *) echo "fake aws: no --region us-east-1" >&2; exit 97 ;; esac
echo "$password"
EOF

# dig answers line N of \$FAKE_DIR/dig on its Nth call (an empty line: no answer), the last line after that.
cat >"$bin/dig" <<'EOF'
#!/usr/bin/env bash
echo "dig $*" >>"$FAKE_LOG"
n=$(($(cat "$FAKE_DIR/dig.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/dig.n"
total=$(wc -l <"$FAKE_DIR/dig" | tr -d ' ')
[ "$n" -le "$total" ] || n=$total
sed -n "${n}p" "$FAKE_DIR/dig"
EOF

# psql: a host named *unreachable* times out, *readonly* refuses writes, any other host accepts them; a report
# answers what $FAKE_DIR/report holds. It logs the conninfo and the mode and content of the password file.
cat >"$bin/psql" <<'EOF'
#!/usr/bin/env bash
conninfo= statement=
while [ $# -gt 0 ]; do
  case $1 in
    -c) statement=$2; shift ;;
    host=*) conninfo=$1 ;;
  esac
  shift
done
mode=$(ls -l "$PGPASSFILE" | cut -c1-10)
echo "psql $conninfo | pgpass $mode $(cat "$PGPASSFILE") | $(tr '\n' ' ' <<<"$statement")" >>"$FAKE_LOG"
case $conninfo in
  *unreachable*) echo "psql: error: connection to server failed: timeout expired" >&2; exit 2 ;;
  *readonly*) echo "ERROR:  cannot execute INSERT in a read-only transaction" >&2; exit 1 ;;
esac
case $statement in SELECT*) cat "$FAKE_DIR/report" ;; esac
EOF

printf '#!/bin/sh\necho "sleep $*" >>"$FAKE_LOG"\n' >"$bin/sleep"
printf '#!/bin/sh\nexec "$@"\n' >"$bin/setsid"
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
hb() { bash "$src/heartbeat.sh" "$@"; }
# field LINE COLUMN: a column of line LINE of the writer's output.
field() { sed -n "${1}p" "$work/out" | cut -f "$2"; }
reset() {
  : >"$log"
  rm -f "$work/dig.n"
}

# --- write: the CNAME moves from an unreachable primary to a read-only replica, then to the promoted DR host ----------
reset
printf '%s\n' 'svp-lab-dr-primary.unreachable.ap-southeast-1.rds.amazonaws.com.' '' \
  'svp-lab-dr-replica.readonly.us-east-1.rds.amazonaws.com.' 'svp-lab-dr-replica.abc.us-east-1.rds.amazonaws.com.' \
  >"$work/dig"
hb write dr 4 >"$work/out" 2>&1
expect "write makes one line per attempt" [ "$(wc -l <"$work/out" | tr -d ' ')" = 4 ]
expect "an unreachable host is a failed attempt, with the error" \
  [ "$(field 1 3)|$(field 1 4)" = "svp-lab-dr-primary.unreachable.ap-southeast-1.rds.amazonaws.com|fail" ]
expect "the timeout shows in the line" grep -q 'timeout expired' <(field 1 5)
expect "no CNAME is a failed attempt without a connection" [ "$(field 2 3)|$(field 2 4)" = "-|fail" ]
expect "a replica not yet promoted refuses the write" [ "$(field 3 4)" = fail ]
expect "the CNAME changing target between attempts reaches the new host" \
  [ "$(field 4 3)|$(field 4 4)" = "svp-lab-dr-replica.abc.us-east-1.rds.amazonaws.com|ok" ]
expect "each line starts with the UTC time of its epoch" \
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z	[0-9]+	' "$work/out"
expect "three connections, each to the resolved host" [ "$(grep -c '^psql host=' "$log")" = 3 ]
expect "every connection is verify-full against the RDS bundle with a 2 s timeout" \
  [ "$(grep '^psql host=' "$log" | grep -c 'sslmode=verify-full sslrootcert=/opt/svp-lab-dr/rds-ca.pem connect_timeout=2')" = 3 ]
expect "the row is written by side dr" grep -qF "INSERT INTO heartbeat (side, client_ts) VALUES ('dr', to_timestamp(" "$log"
expect "the aws call names the Region and no profile" grep -q '^aws secretsmanager get-secret-value .* --region us-east-1$' "$log"
expect "the password file is private to the process" \
  [ "$(grep '^psql host=' "$log" | grep -c "pgpass -rw------- \*:\*:\*:svp_admin:$password")" = 3 ]
expect "the password is not in the output" bash -c '! grep -q "$1" "$2"' _ "$password" "$work/out"
expect "the password file is gone after the run" [ -z "$(ls -A "$work/tmp")" ]
expect "the dig query asks for the CNAME of db.<zone>" grep -q '^dig +short +time=1 +tries=1 db.svp-lab-dr.internal CNAME$' "$log"

# --- write: a side other than primary or dr is refused before any call ------------------------------------------------
reset
expect "an unknown side is refused" bash -c '! bash "$1" write other 1 >/dev/null 2>&1' _ "$src/heartbeat.sh"
expect "nothing is called for an unknown side" [ ! -s "$log" ]

# --- report -----------------------------------------------------------------------------------------------------------
reset
printf 'primary_last=1800000000\ndr_first=1800000095\n' >"$work/report"
hb report svp-lab-dr-replica.abc.us-east-1.rds.amazonaws.com >"$work/out" 2>&1
expect "report prints the newest primary row and the first dr row" \
  [ "$(cat "$work/out")" = "$(printf 'primary_last=1800000000\ndr_first=1800000095')" ]
expect "report connects to the host it is given" \
  grep -q '^psql host=svp-lab-dr-replica.abc.us-east-1.rds.amazonaws.com port=5432 dbname=svp_lab ' "$log"
expect "report without a host fails" bash -c '! bash "$1" report >/dev/null 2>&1' _ "$src/heartbeat.sh"

# --- start and stop ---------------------------------------------------------------------------------------------------
reset
printf '%s\n' 'svp-lab-dr-replica.abc.us-east-1.rds.amazonaws.com.' >"$work/dig"
hb start dr >"$work/out" 2>&1
expect "start writes the pid of the writer" [ -s "$work/run/dr.pid" ]
pid=$(cat "$work/run/dr.pid")
# A logged attempt proves the writer runs, so the second start below meets a live writer, not a fork that died.
for _ in {1..50}; do
  if [ -s "$work/run/dr.log" ] && [ "$(wc -l <"$work/run/dr.log")" -gt 0 ]; then break; fi
  "$real_sleep" 0.1
done
expect "the writer runs in the background and logs its attempts" \
  [ "$(head -n 1 "$work/run/dr.log" | cut -f 3,4)" = "$(printf 'svp-lab-dr-replica.abc.us-east-1.rds.amazonaws.com\tok')" ]
hb start dr >"$work/out" 2>&1
expect "a second start keeps the running writer" \
  bash -c 'grep -q "already running, pid $1" "$2" && [ "$(cat "$3")" = "$1" ]' _ "$pid" "$work/out" "$work/run/dr.pid"
hb stop >"$work/out" 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; "$real_sleep" 0.2; done
expect "stop ends the writer it started" bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid"
expect "stop removes the pid file" [ ! -e "$work/run/dr.pid" ]

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
