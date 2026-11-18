#!/usr/bin/env bash
# Self-test of pg.sh with fake aws, psql, pgbench, dig, date, sleep and timeout first on PATH (jq is the host's): no
# network, no account. Covers p95 by nearest rank, error windows (in the middle, never closed, none, attempts cut off),
# replica lag, a mark never seen or never written, the restarted load, the burst, the TLS, Region and password rules.
# Usage: bash scripts/pg-test.sh
# shellcheck disable=SC2016 # bash -c '...' and the fakes expand their own arguments, not this shell
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
state=$work/state
log=$work/calls.log
export REAL_DATE REAL_SLEEP
REAL_DATE=$(command -v date)
REAL_SLEEP=$(command -v sleep)
mkdir -p "$bin" "$state" "$work/run" "$work/tmp"
failures=0

unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset PGHOST PGHOSTADDR PGPORT PGUSER PGDATABASE PGSSLMODE PGSSLROOTCERT PGPASSFILE PGPASSWORD
export FAKE_LOG=$log FAKE_DIR=$state TMPDIR=$work/tmp FAKE_PW=FakeMasterPassw0rdForTheTestOnly
export SVP_DS_CONF=$work/svp-lab-ds-pg.conf
cat >"$SVP_DS_CONF" <<EOF
SVP_DS_REGION=ap-southeast-1
SVP_DS_SECRET_ID=svp-lab-ds-pg-master
SVP_DS_DB=svp_lab
SVP_DS_CA=/opt/svp-lab-ds/rds-ca.pem
SVP_DS_PROXY_CA=/opt/svp-lab-ds/proxy-ca.pem
SVP_DS_RUN=$work/run
EOF
writer=svp-lab-ds-aurora.cluster-abc.ap-southeast-1.rds.amazonaws.com
reader=svp-lab-ds-aurora.cluster-ro-abc.ap-southeast-1.rds.amazonaws.com
proxy=svp-lab-ds-proxy.proxy-abc.ap-southeast-1.rds.amazonaws.com

# bump FILE: adds one to the counter in FILE and prints it; the rename keeps a concurrent reader from an empty file.
# clockfile: $FAKE_DIR/clock.$PGHOST when that file exists, so that probe loops side by side each move their own clock
# and get the same attempts however the scheduler runs them, else $FAKE_DIR/clock. advance MS moves that clock.
cat >"$bin/fake-lib" <<'EOF'
bump() {
  local n
  n=$(($(cat "$1" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$1.$$" && mv -f "$1.$$" "$1"
  echo "$n"
}
clockfile() {
  if [ -e "$FAKE_DIR/clock.${PGHOST:-}" ]; then echo "$FAKE_DIR/clock.$PGHOST"; else echo "$FAKE_DIR/clock"; fi
}
setclock() { echo "$2" >"$1.$$" && mv -f "$1.$$" "$1"; }
advance() {
  local c
  c=$(clockfile)
  setclock "$c" $(($(cat "$c") + $1))
}
EOF

# The instance runs with the credentials of its role: a profile is a mistake, a missing Region too.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
case " $* " in *" --profile "*) echo "fake aws: --profile on an instance" >&2; exit 97 ;; esac
case " $* " in *" --region ap-southeast-1 "*) ;; *) echo "fake aws: no --region ap-southeast-1" >&2; exit 97 ;; esac
case "$1 $2" in
  "secretsmanager get-secret-value") printf '{"username":"svp_admin","password":"%s"}\n' "$FAKE_PW" ;;
  *) echo "fake aws: unexpected call $*" >&2; exit 98 ;;
esac
EOF

# psql logs its arguments, the libpq environment and the password file. A probe statement answers from
# $FAKE_DIR/seq.<host>, one line per call (ok past its end): ok, fail, or ok after 30 s (hang) or 1.5 s (slow) on the
# clock. The lag poller fails when $FAKE_DIR/lag_never exists; with $FAKE_DIR/lag_hold it waits to be killed, and the
# mark's write fails once the poller runs.
cat >"$bin/psql" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
args="$*" cmd= file=
while [ $# -gt 0 ]; do
  case $1 in
    -c) cmd=$2; shift ;;
    -f) file=$2; shift ;;
  esac
  shift
done
stdin=
[ "$file" != - ] || stdin=$(cat)
pass=
[ -z "${PGPASSFILE:-}" ] || pass="pgpass $(ls -l "$PGPASSFILE" | cut -c1-10) $(cat "$PGPASSFILE")"
echo "psql | $args | host=${PGHOST:-} hostaddr=${PGHOSTADDR:-} sslmode=${PGSSLMODE:-} root=${PGSSLROOTCERT:-} timeout=${PGCONNECT_TIMEOUT:-} user=${PGUSER:-} | $pass" >>"$FAKE_LOG"
[ -z "$stdin" ] || printf '%s\n' "$stdin" >>"$FAKE_DIR/stdin"
case $cmd in
  *probe_marks* | "SELECT view_count"*)
    n=$(bump "$FAKE_DIR/n.$PGHOST")
    r=$(sed -n "${n}p" "$FAKE_DIR/seq.$PGHOST" 2>/dev/null)
    [ "$r" != fail ] || { echo "psql: error: connection to server failed: Connection refused"; echo "detail" ; } >&2
    [ "$r" != fail ] || exit 2
    [ "$r" != hang ] || advance 30000
    [ "$r" != slow ] || advance 1500 ;;
  "SELECT count(*)"*) echo 7 ;;
  "INSERT INTO lag_marks"*)
    if [ -e "$FAKE_DIR/lag_hold" ]; then
      for _ in $(seq 500); do [ ! -e "$FAKE_DIR/poller" ] || break; "$REAL_SLEEP" 0.02; done
      echo "psql: error: server closed the connection unexpectedly" >&2
      exit 2
    fi ;;
esac
if grep -q 'LOOP' <<<"$stdin" && [ -e "$FAKE_DIR/lag_hold" ]; then
  trap 'echo killed >"$FAKE_DIR/poller"; exit 143' TERM
  echo running >"$FAKE_DIR/poller"
  for _ in $(seq 500); do "$REAL_SLEEP" 0.02; done
  echo "never killed" >"$FAKE_DIR/poller"
  exit 3
fi
if grep -q 'LOOP' <<<"$stdin" && [ -e "$FAKE_DIR/lag_never" ]; then
  echo "ERROR:  mark not seen" >&2
  exit 3
fi
exit 0
EOF

# pgbench logs its arguments and environment, moves the clock by its -T (or by 1 s when it fails), prints a report,
# and with --log writes the latencies of $FAKE_DIR/latencies over two files, as two threads would. It fails while
# $FAKE_DIR/pgbench_fail counts down.
cat >"$bin/pgbench" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
echo "pgbench $* | host=${PGHOST:-} sslmode=${PGSSLMODE:-} root=${PGSSLROOTCERT:-} user=${PGUSER:-}" >>"$FAKE_LOG"
t=0 prefix=
while [ $# -gt 0 ]; do
  case $1 in
    -T) t=$2; shift ;;
    --log-prefix=*) prefix=${1#--log-prefix=} ;;
  esac
  shift
done
left=$(cat "$FAKE_DIR/pgbench_fail" 2>/dev/null || echo 0)
if [ "$left" -gt 0 ]; then
  echo $((left - 1)) >"$FAKE_DIR/pgbench_fail"
  echo $(($(cat "$FAKE_DIR/clock") + 1000)) >"$FAKE_DIR/clock"
  echo "pgbench: error: client 0 aborted in command 2 (SQL) of script 0; perhaps the backend died while processing"
  echo "number of transactions actually processed: 12/34"
  exit 2
fi
echo $(($(cat "$FAKE_DIR/clock") + t * 1000)) >"$FAKE_DIR/clock"
if [ -n "$prefix" ]; then
  head -n 11 "$FAKE_DIR/latencies" >"$prefix.4242"
  tail -n +12 "$FAKE_DIR/latencies" >"$prefix.4242.1"
fi
cat <<'OUT'
transaction type: script
number of transactions actually processed: 600
number of failed transactions: 0 (0.000%)
latency average = 2.500 ms
average connection time = 9.100 ms
tps = 20.0 (including reconnection times)
OUT
EOF

# dig: an address for every name but those listed in $FAKE_DIR/noaddr, after a CNAME line.
cat >"$bin/dig" <<'EOF'
#!/usr/bin/env bash
echo "dig $*" >>"$FAKE_LOG"
for a in "$@"; do name=$a; [ "$a" = A ] && break; prev=$a; done
grep -qx "$prev" "$FAKE_DIR/noaddr" 2>/dev/null && exit 0
echo "instance.abc.ap-southeast-1.rds.amazonaws.com."
echo "10.67.1.10"
EOF

# date: +%s%3N reads the clock of clockfile, which moves $FAKE_DIR/step ms (default 100) at each call; the rest is
# the real date.
cat >"$bin/date" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
if [ "$*" = "+%s%3N" ]; then
  clock=$(clockfile)
  v=$(cat "$clock")
  echo "$v"
  setclock "$clock" $((v + $(cat "$FAKE_DIR/step" 2>/dev/null || echo 100)))
  exit 0
fi
if [ "${1:-}" = -u ] && [ "${2:-}" = -d ]; then
  "$REAL_DATE" -u -r "${3#@}" "$4" 2>/dev/null || "$REAL_DATE" -u -d "$3" "$4"
  exit
fi
exec "$REAL_DATE" "$@"
EOF

# timeout LIMIT CMD...: runs CMD; when CMD moved the clock past LIMIT seconds, the clock goes back to the moment the
# real timeout would have ended it, its output is dropped and the exit is 124, as GNU timeout's.
cat >"$bin/timeout" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
echo "timeout $1 $2" >>"$FAKE_LOG"
limit=$(($1 * 1000)) rc=0
shift
c=$(clockfile)
before=$(cat "$c")
"$@" >"$FAKE_DIR/out.$$" 2>"$FAKE_DIR/err.$$" || rc=$?
if [ $(($(cat "$c") - before)) -gt "$limit" ]; then
  setclock "$c" $((before + limit))
  rc=124
else
  cat "$FAKE_DIR/out.$$"
  cat "$FAKE_DIR/err.$$" >&2
fi
rm -f "$FAKE_DIR/out.$$" "$FAKE_DIR/err.$$"
exit "$rc"
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
pg() { bash "$src/pg.sh" "$@" >"$work/out" 2>&1; }
refused() { ! bash "$src/pg.sh" "$@" >"$work/out" 2>&1; }
reset() {
  rm -rf "${state:?}"/* "${work:?}/run"/*
  : >"$log"
  echo 1800000000000 >"$state/clock"
}
# iso MS: epoch milliseconds as pg.sh prints them, with BSD or GNU date.
iso() {
  printf '%s.%03dZ' "$("$REAL_DATE" -u -r "$(($1 / 1000))" +%Y-%m-%dT%H:%M:%S 2>/dev/null ||
    "$REAL_DATE" -u -d "@$(($1 / 1000))" +%Y-%m-%dT%H:%M:%S)" "$(($1 % 1000))"
}
# probe_log FILE LINE...: a probe log, one "<start ms> <end ms> ok|fail" per argument, as probe_loop writes it.
probe_log() {
  local f=$1 a s e st
  shift
  : >"$f"
  for a in "$@"; do
    read -r s e st <<<"$a"
    printf '%s\t%s\t%s\t%s\t10.67.1.10\t%s\t%s\n' "$(iso "$s")" "$s" "$(iso "$e")" "$e" "$st" \
      "$([ "$st" = ok ] || echo 'connection to server failed')" >>"$f"
  done
}
# logof HOST: the probe log of HOST as the last probe printed it.
logof() { sed -n "s/^== $1 ([a-z]*, log \(.*\))$/\1/p" "$work/out"; }
# rundir NAME: the directory pg.sh made for its run of NAME since the reset; two runs give two lines.
rundir() { compgen -G "$work/run/$1.*" || true; }
# clocks HOST...: a clock of its own for each probe loop.
clocks() { for h in "$@"; do echo 1800000000000 >"$state/clock.$h"; done; }

# --- the fake aws refuses what an instance must never do --------------------------------------------------------------
reset
expect "the fake aws refuses --profile" bash -c '! aws secretsmanager get-secret-value --profile x --region ap-southeast-1 \
  >/dev/null 2>&1'
expect "the fake aws refuses a call without the Region" bash -c '! aws secretsmanager get-secret-value >/dev/null 2>&1'

# --- window: a chain in the middle, one that never closes, none, one with no success before it ------------------------
reset
probe_log "$work/w.log" "1000 1010 ok" "1500 1510 ok" "2000 4000 fail" "4500 6500 fail" "7000 9000 fail" \
  "9500 10700 ok" "10700 10710 ok"
pg window "$work/w.log"
expect "a chain in the middle gives its window, from the end of the last success to the end of the first after it" \
  grep -q '^error window 1: 9190 ms, 3 failed attempts (last success ended 1970-01-01T00:00:01.510Z, first success after ended 1970-01-01T00:00:10.700Z)$' \
  "$work/out"
expect "the window gives the slowest success and the resolution" \
  grep -q '^attempts: 4 ok (slowest 1200 ms), 3 failed; a new one every 500 ms or when the last ends, each cut off after 2 s (resolution)$' \
  "$work/out"

probe_log "$work/w.log" "1000 1010 ok" "1500 3500 fail" "3500 5500 fail" "5500 7500 fail"
pg window "$work/w.log"
expect "a chain that never closes says so" \
  grep -q '^chain 1: 3 failed attempts from 1970-01-01T00:00:01.500Z to the end of the probe at 1970-01-01T00:00:07.500Z, no success after it: window not closed$' \
  "$work/out"
expect "a chain that never closes prints no window number" bash -c '! grep -q "error window" "$1"' _ "$work/out"
expect "a chain that never closes shows the last error" grep -q '^last error: connection to server failed$' "$work/out"

probe_log "$work/w.log" "1000 1010 ok" "1500 1510 ok" "2000 2010 ok"
pg window "$work/w.log"
expect "no failed attempt means no window" grep -q '^no failed attempt in 3 attempts: no error window$' "$work/out"
expect "no failed attempt prints no window number" bash -c '! grep -qE "^(error window|chain)" "$1"' _ "$work/out"

probe_log "$work/w.log" "1000 3000 fail" "3000 3010 ok" "3500 5500 fail" "5500 5510 ok"
pg window "$work/w.log"
expect "a chain with no success before it has no window" \
  grep -q '^chain 1: 1 failed attempts from .* no success before it: no window$' "$work/out"
expect "a later chain gets its own window" grep -q '^error window 2: 2500 ms, 1 failed attempts' "$work/out"

probe_log "$work/w.log" "1000 3000 fail" "3000 5000 fail"
pg window "$work/w.log"
expect "a probe without a success prints no slowest time" grep -q '^attempts: 0 ok, 2 failed; ' "$work/out"

expect "a missing log is refused" refused window "$work/none.log"

# --- probe: two endpoints side by side, a new connection and a fresh address each time -------------------------------
reset
printf 'ok\nok\nfail\nfail\nfail\nok\n' >"$state/seq.$writer"
echo 1000 >"$state/step"
# Three clock reads per attempt of 1 s each: seven attempts on each endpoint in 20 s, one more than the writer's seq.
clocks "$proxy" "$writer"
pg probe write 20 "$proxy" "$writer"
expect "each loop makes the same seven attempts whatever the scheduling" \
  bash -c '[ "$(grep -c . "$1")" = 7 ] && [ "$(grep -c . "$2")" = 7 ]' _ "$(logof "$proxy")" "$(logof "$writer")"
expect "the probe on the writer reports its window" \
  bash -c 'sed -n "/^== $1/,/^attempts/p" "$2" | grep -qE "^error window 1: [0-9]+ ms, 3 failed attempts"' _ "$writer" \
  "$work/out"
expect "the probe on the proxy saw no error" \
  bash -c 'sed -n "/^== $1/,/^attempts/p" "$2" | grep -q "^no failed attempt in"' _ "$proxy" "$work/out"
expect "each attempt asks the VPC resolver again" \
  bash -c '[ "$(grep -c "^dig @169.254.169.253 +short .* $1 A$" "$2")" -ge 6 ]' _ "$writer" "$log"
expect "each attempt connects to the address it resolved, the name kept for TLS" \
  bash -c 'grep "INSERT INTO probe_marks" "$1" | grep -q "host=$2 hostaddr=10.67.1.10 sslmode=verify-full"' _ "$log" "$writer"
expect "the proxy is verified against the Amazon Trust Services roots" \
  bash -c 'grep "INSERT INTO probe_marks" "$1" | grep "host=$2 " | grep -q "root=/opt/svp-lab-ds/proxy-ca.pem timeout=2"' _ \
  "$log" "$proxy"
expect "the writer is verified against the RDS bundle" \
  bash -c 'grep "INSERT INTO probe_marks" "$1" | grep "host=$2 " | grep -q "root=/opt/svp-lab-ds/rds-ca.pem timeout=2"' _ \
  "$log" "$writer"
expect "every connection is verify-full" bash -c '! grep "^psql" "$1" | grep -v "sslmode=verify-full" | grep -q .' _ "$log"
expect "the probe log has one line per attempt with the address" \
  bash -c '[ "$(grep -c "	10.67.1.10	fail	psql: error: connection to server failed" "$1")" = 3 ]' _ \
  "$(logof "$writer")"

# RDS Proxy holds a statement while no writer is up: an attempt still without an answer at the limit is ended and
# fails, and the window runs to the end of the first answer after it.
reset
printf 'ok\nok\nhang\nhang\nslow\n' >"$state/seq.$proxy"
echo 1000 >"$state/step"
clocks "$proxy"
pg probe write 20 "$proxy"
expect "every attempt runs under the limit" bash -c '[ "$(grep -c "^timeout 2 psql$" "$1")" = 5 ]' _ "$log"
expect "an attempt held past the limit fails as no answer" \
  bash -c '[ "$(grep -c "	fail	no answer within 2 s$" "$1")" = 2 ]' _ "$(logof "$proxy")"
expect "the held attempts give a window to the end of the first answer after them" \
  grep -qE '^error window 1: 14500 ms, 2 failed attempts \(last success ended ' "$work/out"
expect "an answer slower than usual but within the limit shows as the slowest success" \
  grep -q '^attempts: 3 ok (slowest 2500 ms), 2 failed; ' "$work/out"

reset
echo "$writer" >"$state/noaddr"
echo 1000 >"$state/step"
clocks "$writer" "$reader"
pg probe read 3 "$writer" "$reader"
expect "a name without an address is a failed attempt" grep -q "no address for $writer" "$(logof "$writer")"
expect "a read probe reads" \
  bash -c 'grep "SELECT view_count FROM view_counts" "$1" | grep -q "host=$2 hostaddr=10.67.1.10 "' _ "$log" "$reader"
first=$(logof "$reader")
pg probe read 3 "$writer" "$reader"
expect "the same probe again writes a log of its own and leaves the first" \
  bash -c '[ -n "$2" ] && [ "$1" != "$2" ] && [ -s "$1" ] && [ -s "$2" ]' _ "$first" "$(logof "$reader")"
expect "every probe has a directory of its own under SVP_DS_RUN" \
  bash -c '[ "$(grep -c . <<<"$1")" = 2 ]' _ "$(rundir probe)"

reset
expect "a probe mode other than write or read is refused" refused probe delete 10 "$writer"
expect "three endpoints are refused" refused probe write 10 "$writer" "$reader" "$proxy"
expect "a host outside RDS is refused" refused probe write 10 db.example.org
expect "the refusal names the host" grep -q "'db.example.org' is not an RDS or RDS Proxy endpoint" "$work/out"
expect "a probe longer than the SSM timeout allows is refused" refused probe write 3301 "$writer"
expect "nothing runs for a refused probe" bash -c '! grep -q "^psql\|^aws" "$1"' _ "$log"

# --- p95: nearest rank over every log file of the run -----------------------------------------------------------------
reset
for v in 7 3 20 1 15 9 12 18 2 5 11 4 16 8 19 6 13 10 17 14; do echo "0 $v $((v * 1000)) 0 1800000000 1"; done \
  >"$state/latencies"
pg read "$reader" 50 60
expect "p95 of 20 latencies is the 19th (0.95 x 20 = 19)" \
  grep -q '^p95 read latency: 19.000 ms (nearest rank 19 of 20 transactions), max 20.000 ms; failed or skipped: 0$' \
  "$work/out"
expect "read runs pgbench at a fixed rate with a log in the directory of the run" \
  bash -c 'grep -q "^pgbench -n -c 4 -j 2 -R 50 -T 60 -D videos=100000 -f $1/read.sql --log --log-prefix=$1/p95 " "$2" &&
    grep -q "(pgbench logs in $1)$" "$3"' _ "$(rundir read)" "$log" "$work/out"
pg read "$reader" 50 60
expect "a second read counts only its own log" \
  grep -q '^p95 read latency: 19.000 ms (nearest rank 19 of 20 transactions)' "$work/out"

reset
for v in 21 7 3 20 1 15 9 12 18 2 5 11 4 16 8 19 6 13 10 17 14; do echo "0 $v $((v * 1000)) 0 1800000000 1"; done \
  >"$state/latencies"
echo "1 22 failed 0 1800000000 2" >>"$state/latencies"
echo "1 23 skipped 0 1800000000 3" >>"$state/latencies"
pg read "$reader" 50 60
expect "p95 of 21 latencies rounds the rank up (0.95 x 21 = 19.95, rank 20)" \
  grep -q '^p95 read latency: 20.000 ms (nearest rank 20 of 21 transactions), max 21.000 ms; failed or skipped: 2$' \
  "$work/out"

reset
printf '0 1 failed 0 1800000000 1\n' >"$state/latencies"
expect "a log without any latency fails instead of printing a number" refused read "$reader" 50 60
expect "the failure says why" grep -q 'no transaction with a latency' "$work/out"

# --- lag: samples, and a reader that never sees the mark --------------------------------------------------------------
reset
pg lag "$writer" "$reader" 3
expect "lag prints one line per sample" bash -c '[ "$(grep -cE "^lag [1-3]: [0-9]+ ms \(written " "$1")" = 3 ]' _ "$work/out"
expect "lag prints the median and the max with the resolution" \
  grep -qE "^replica lag $writer -> $reader over 3 samples: median [0-9]+ ms, max [0-9]+ ms \(resolution: poll every 0.01 s\)$" \
  "$work/out"
expect "the mark is written on the writer" \
  bash -c 'grep "INSERT INTO lag_marks" "$1" | grep -q "host=$2 "' _ "$log" "$writer"
expect "the reader is polled in one session until the mark shows" \
  bash -c 'grep -q "PERFORM 1 FROM lag_marks WHERE id = .lag-" "$1" && grep -q "pg_sleep(0.01)" "$1"' _ "$state/stdin"

reset
touch "$state/lag_never"
expect "a mark never seen fails the lag" refused lag "$writer" "$reader" 2
expect "each sample past the wait says so" \
  bash -c '[ "$(grep -c "not seen on the reader within 30 s" "$1")" = 2 ]' _ "$work/out"
expect "the failure counts the samples lost" grep -q '2 of 2 samples never reached the reader' "$work/out"
expect "no lag number is printed when no sample arrived" bash -c '! grep -q "^replica lag" "$1"' _ "$work/out"

reset
touch "$state/lag_hold"
expect "a mark that cannot be written fails the lag" refused lag "$writer" "$reader" 1
expect "the sample says the write failed" \
  grep -q '^lag 1: write failed on the writer: psql: error: server closed the connection' "$work/out"
expect "the poller's psql ends with its sample instead of staying on the reader" grep -qx killed "$state/poller"

# --- load: steady rate, started again after a failover ----------------------------------------------------------------
reset
echo 1 >"$state/pgbench_fail"
pg load "$writer" 100 60
expect "load runs pgbench at the fixed rate on the engagement script" \
  grep -q "^pgbench -n -c 4 -j 2 -R 100 -T 60 -D videos=100000 -f $(rundir load)/write.sql " "$log"
expect "a load that loses its clients starts again for the time left" \
  bash -c 'grep -q "load starts again for the time left" "$1" && grep -q "^pgbench .* -T 59 " "$2"' _ "$work/out" "$log"
expect "the load prints the report and the aborted client" \
  bash -c 'grep -q "^tps = 20.0" "$1" && grep -q "client 0 aborted" "$1"' _ "$work/out"
expect "the write script upserts a view count and adds a like in one transaction" \
  bash -c 'grep -q "^BEGIN;" "$1" && grep -q "ON CONFLICT (video_id) DO UPDATE" "$1" && grep -q "^INSERT INTO likes" "$1"' _ \
  "$(rundir load)/write.sql"

# --- burst: a new connection per transaction --------------------------------------------------------------------------
reset
pg burst "$proxy" 200 60
expect "burst opens a connection per transaction" grep -q "^pgbench -n -C -c 200 -j 2 -T 60 " "$log"
expect "burst through the proxy verifies against the Amazon Trust Services roots" \
  grep -q "^pgbench .* host=$proxy sslmode=verify-full root=/opt/svp-lab-ds/proxy-ca.pem user=svp_admin" "$log"
expect "burst prints the connection time and the failures" \
  bash -c 'grep -q "^average connection time = 9.100 ms" "$1" && grep -q "^number of failed transactions: 0" "$1"' _ \
  "$work/out"

# --- init -------------------------------------------------------------------------------------------------------------
reset
pg init "$writer"
expect "init creates the four tables and the sample rows" \
  bash -c '[ "$(grep -c "^CREATE TABLE IF NOT EXISTS" "$1")" = 4 ] && grep -q "generate_series(1, 500000)" "$1"' _ \
  "$state/stdin"

# --- the password: read at run time, in a private file, never on a command line or in the output ----------------------
expect "the secret is read with the Region and no profile" \
  grep -q '^aws secretsmanager get-secret-value --secret-id svp-lab-ds-pg-master --query SecretString --output text --region ap-southeast-1$' \
  "$log"
expect "psql gets the password from a file only its owner reads" grep -q "| pgpass -rw------- \*:\*:\*:svp_admin:$FAKE_PW$" "$log"
expect "the password is on no command line" \
  bash -c '! grep "^psql\|^pgbench" "$1" | cut -d"|" -f1-2 | grep -q "$2"' _ "$log" "$FAKE_PW"
expect "the password is not in the output" bash -c '! grep -q "$1" "$2"' _ "$FAKE_PW" "$work/out"
expect "PGPASSWORD is never set" bash -c '! grep -qE "PGPASSWORD=|export PGPASSWORD" "$1"' _ "$src/pg.sh"
expect "the password file is removed at exit" bash -c '[ -z "$(ls -A "$1")" ]' _ "$work/tmp"
expect "no call passes a profile" bash -c '! grep -q -- "--profile" "$1"' _ "$log"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
