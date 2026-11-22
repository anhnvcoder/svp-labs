#!/usr/bin/env bash
# Self-test of kv.sh with fake aws, valkey-cli, valkey-benchmark, getent, date, sleep and timeout first on PATH: no
# network, no account. Covers error windows (in the middle, never closed, none), the keys picked for a shard from the
# cluster's answer, attempts cut off or wrong, benchmark batches and minutes, client examples, TLS, Region, password.
# Usage: bash scripts/kv-test.sh
# shellcheck disable=SC2016 # bash -c '...' and the fakes expand their own arguments, not this shell
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin
state=$work/state
log=$work/calls.log
export REAL_DATE
REAL_DATE=$(command -v date)
mkdir -p "$bin" "$state" "$work/run"
failures=0

unset SVP_AWS_STG_ACCOUNT_ID AWS_PAGER AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset VALKEYCLI_AUTH REDISCLI_AUTH
export FAKE_LOG=$log FAKE_DIR=$state FAKE_PW=FakeValkeyPassw0rdForTheTestOnly
export SVP_DS_CONF=$work/svp-lab-ds-kv.conf
cat >"$SVP_DS_CONF" <<EOF
SVP_DS_REGION=ap-southeast-1
SVP_DS_SECRET_ID=svp-lab-ds-kv-app
SVP_DS_CA=/etc/pki/tls/certs/ca-bundle.crt
SVP_DS_RUN=$work/run
EOF
cme=clustercfg.svp-lab-ds-cme.abc123.apse1.cache.amazonaws.com
cmd=master.svp-lab-ds-cmd.abc123.apse1.cache.amazonaws.com

# The instance runs with the credentials of its role: a profile is a mistake, a missing Region too.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
case " $* " in *" --profile "*) echo "fake aws: --profile on an instance" >&2; exit 97 ;; esac
case " $* " in *" --region ap-southeast-1 "*) ;; *) echo "fake aws: no --region ap-southeast-1" >&2; exit 97 ;; esac
case "$1 $2" in
  "secretsmanager get-secret-value") printf '{"username":"svp-lab-ds-kv-app","password":"%s"}\n' "$FAKE_PW" ;;
  *) echo "fake aws: unexpected call $*" >&2; exit 98 ;;
esac
EOF

# The clock of date +%s%3N, moved by $FAKE_DIR/step ms (default 100) at each read and by advance MS.
cat >"$bin/fake-lib" <<'EOF'
setclock() { echo "$1" >"$FAKE_DIR/clock.$$" && mv -f "$FAKE_DIR/clock.$$" "$FAKE_DIR/clock"; }
advance() { setclock $(($(cat "$FAKE_DIR/clock") + $1)); }
EOF

# valkey-cli logs its arguments and whether VALKEYCLI_AUTH holds the password, then answers each line of stdin: CLUSTER
# KEYSLOT svp:lab:probe:N is N * 1000 mod 16384, other commands but the probe's get "reply to <command>". A probe call
# takes the next line of $FAKE_DIR/seq.<host> (ok past its end): ok, fail (refused), hang (30 s on the clock), stale
# (every GET wrong), stale2 (the second GET wrong), moved (ok after a redirect line), refused (error after a redirect).
cat >"$bin/valkey-cli" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
host= args="$*"
while [ $# -gt 0 ]; do
  case $1 in -h) host=$2; shift ;; esac
  shift
done
auth=none
[ "${VALKEYCLI_AUTH:-}" != "$FAKE_PW" ] || auth=env
echo "valkey-cli $args | auth=$auth" >>"$FAKE_LOG"
probe= r= gets=0
while IFS= read -r line; do
  echo "  < $line" >>"$FAKE_LOG"
  case $line in
    "CLUSTER KEYSLOT svp:lab:probe:"*) n=${line##*:}; echo $((n * 1000 % 16384)) ;;
    "SET svp:lab:probe"*)
      value=${line##* }
      if [ -z "$probe" ]; then
        probe=1
        n=$(($(cat "$FAKE_DIR/n.$host" 2>/dev/null || echo 0) + 1))
        echo "$n" >"$FAKE_DIR/n.$host"
        r=$(sed -n "${n}p" "$FAKE_DIR/seq.$host" 2>/dev/null)
        case $r in
          fail) echo "Could not connect to Valkey at $host:6379: Connection refused" >&2; exit 1 ;;
          hang) advance 30000; exit 1 ;;
        esac
        [ "$r" != moved ] || echo "-> Redirected to slot [9000] located at svp-lab-ds-cme-0002-001.example:6379"
        [ "$r" != refused ] || { echo "-> Redirected to slot [9000] located at x:6379"; echo "NOPERM no permissions"; exit 0; }
      fi
      echo OK ;;
    "GET svp:lab:probe"*)
      gets=$((gets + 1))
      if [ "$r" = stale ] || { [ "$r" = stale2 ] && [ "$gets" = 2 ]; }; then echo 17; else echo "$value"; fi ;;
    *) echo "reply to $line" ;;
  esac
done
[ -n "$probe" ] || exit 0
EOF

# valkey-benchmark logs its arguments, moves the clock $FAKE_DIR/bench_ms (default 2 s) and prints a batch as 9.0.7
# does: nodes on stdout and CONFIG refused on stderr, the CSV with SET at 10000, 11000, 12000 req/s in turn. The next
# line of $FAKE_DIR/bench_seq picks the batch (ok past its end): moved (slots reloaded), reset (connection lost after
# the header, exit 1), wrongpass (AUTH refused, exit 1), hang (outlives the 60 s limit of its timeout).
cat >"$bin/valkey-benchmark" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
echo "valkey-benchmark $*" >>"$FAKE_LOG"
cluster=
for a in "$@"; do
  case $a in
    --cluster) cluster=1 ;;
    -e) echo "WARNING: -e option has no effect. We now immediately exit on error to avoid false results." >&2 ;;
  esac
done
b=$(($(cat "$FAKE_DIR/bench_b" 2>/dev/null || echo 0) + 1))
echo "$b" >"$FAKE_DIR/bench_b"
r=$(sed -n "${b}p" "$FAKE_DIR/bench_seq" 2>/dev/null)
[ "$r" != hang ] || { advance 70000; exit 0; }
advance "$(cat "$FAKE_DIR/bench_ms" 2>/dev/null || echo 2000)"
if [ "$r" = wrongpass ]; then
  printf 'Node 10.67.17.20:6379 replied with error:\nWRONGPASS invalid username-password pair or user is disabled.\n' >&2
  exit 1
fi
if [ -n "$cluster" ]; then
  printf 'Cluster has 2 primary nodes:\n\n'
  for i in 0 1; do
    echo "Node $i(Primary): 5c9a3e1f0b7d4a2e8f6c1b3d9e0a7f4c2b8d6e1$i 10.67.17.2$i:6379"
    echo "WARNING: Could not fetch node CONFIG 10.67.17.2$i:6379" >&2
  done
  echo
else
  echo "WARNING: Could not fetch server CONFIG" >&2
fi
echo '"test","rps","avg_latency_ms","min_latency_ms","p50_latency_ms","p95_latency_ms","p99_latency_ms","max_latency_ms"'
[ "$r" != reset ] || { echo "Error: Connection reset by peer" >&2; exit 1; }
[ "$r" != moved ] || echo "WARNING: Cluster slots configuration changed, fetching new one..." >&2
n=$(($(cat "$FAKE_DIR/bench_n" 2>/dev/null || echo 0) % 3))
echo $((n + 1)) >"$FAKE_DIR/bench_n"
echo "\"SET\",\"$((10000 + n * 1000)).00\",\"0.900\",\"0.200\",\"0.800\",\"1.500\",\"2.000\",\"5.000\""
echo '"GET","12000.00","0.700","0.200","0.600","1.200","1.800","4.000"'
EOF

cat >"$bin/getent" <<'EOF'
#!/usr/bin/env bash
echo "getent $*" >>"$FAKE_LOG"
echo "10.67.17.10     STREAM $2"
EOF

cat >"$bin/date" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-lib"
if [ "$*" = "+%s%3N" ]; then
  v=$(cat "$FAKE_DIR/clock")
  echo "$v"
  setclock $((v + $(cat "$FAKE_DIR/step" 2>/dev/null || echo 100)))
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
before=$(cat "$FAKE_DIR/clock")
"$@" >"$FAKE_DIR/out.$$" 2>"$FAKE_DIR/err.$$" || rc=$?
if [ $(($(cat "$FAKE_DIR/clock") - before)) -gt "$limit" ]; then
  setclock $((before + limit))
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
kv() { bash "$src/kv.sh" "$@" >"$work/out" 2>&1; }
refused() { ! bash "$src/kv.sh" "$@" >"$work/out" 2>&1; }
reset() {
  rm -rf "${state:?}"/* "${work:?}/run"/*
  : >"$log"
  echo 1800000000000 >"$state/clock"
}
# iso MS: epoch milliseconds as kv.sh prints them, with BSD or GNU date.
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
    printf '%s\t%s\t%s\t%s\t10.67.17.10\t%s\t%s\n' "$(iso "$s")" "$s" "$(iso "$e")" "$e" "$st" \
      "$([ "$st" = ok ] || echo 'Could not connect to Valkey')" >>"$f"
  done
}
# logof: the probe log as the last probe printed it; benchlog: the batch log as the last bench printed it.
logof() { sed -n 's/^== .* (log \(.*\))$/\1/p' "$work/out"; }
benchlog() { sed -n 's/^== .* (log \([^,]*\), full output .*)$/\1/p' "$work/out"; }
# call N: the lines the Nth valkey-cli call read on stdin.
call() { awk -v n="$1" '/^valkey-cli / {c++; next} /^  < / && c == n {print substr($0, 5)}' "$log"; }
no_password() { ! grep -q "$FAKE_PW" "$work/out"; }

# --- the fake aws refuses what an instance must never do --------------------------------------------------------------
reset
expect "the fake aws refuses --profile" bash -c '! aws secretsmanager get-secret-value --profile x --region ap-southeast-1 \
  >/dev/null 2>&1'
expect "the fake aws refuses a call without the Region" bash -c '! aws secretsmanager get-secret-value >/dev/null 2>&1'

# --- window: a chain in the middle, one that never closes, none -------------------------------------------------------
reset
probe_log "$work/w.log" "1000 1010 ok" "1500 1510 ok" "2000 4000 fail" "4500 6500 fail" "7000 9000 fail" \
  "9500 10700 ok" "10700 10710 ok"
kv window "$work/w.log"
expect "a chain in the middle gives its window, from the end of the last success to the end of the first after it" \
  grep -q '^error window 1: 9190 ms, 3 failed attempts (last success ended 1970-01-01T00:00:01.510Z, first success after ended 1970-01-01T00:00:10.700Z)$' \
  "$work/out"
expect "the window names the first error of the chain" grep -q '^first error: Could not connect to Valkey$' "$work/out"
expect "the window gives the slowest success and the resolution" \
  grep -q '^attempts: 4 ok (slowest 1200 ms), 3 failed; a new one every 500 ms or when the last ends, each cut off after 2 s (resolution)$' \
  "$work/out"

probe_log "$work/w.log" "1000 1010 ok" "1500 3500 fail" "3500 5500 fail" "5500 7500 fail"
kv window "$work/w.log"
expect "a chain that never closes before the end says so" \
  grep -q '^chain 1: 3 failed attempts from 1970-01-01T00:00:01.500Z to the end of the probe at 1970-01-01T00:00:07.500Z, no success after it: window not closed$' \
  "$work/out"
expect "a chain that never closes prints no window number" bash -c '! grep -q "error window" "$1"' _ "$work/out"

probe_log "$work/w.log" "1000 1010 ok" "1500 1510 ok" "2000 2010 ok"
kv window "$work/w.log"
expect "no failed attempt means no window" grep -q '^no failed attempt in 3 attempts: no error window$' "$work/out"
expect "no failed attempt prints no window number" bash -c '! grep -qE "^(error window|chain)" "$1"' _ "$work/out"

probe_log "$work/w.log" "1000 3000 fail" "3000 3010 ok"
kv window "$work/w.log"
expect "a chain with no success before it has no window" \
  grep -q '^chain 1: 1 failed attempts from .* no success before it: no window$' "$work/out"
expect "a missing log is refused" refused window "$work/none.log"

# --- probe on a shard: the keys come from the cluster's own slot of each candidate -----------------------------------
reset
printf 'moved\nrefused\nstale2\nok\n' >"$state/seq.$cme"
kv probe 3 "$cme" 8192-16383
expect "the slots come from CLUSTER KEYSLOT of every candidate on the configuration endpoint" \
  bash -c '[ "$(grep -c "^CLUSTER KEYSLOT svp:lab:probe:[0-9]*$" <<<"$1")" = 1024 ] &&
    grep "^valkey-cli" "$2" | head -n 1 | grep -q -- "-h $3 "' _ "$(call 1)" "$log" "$cme"
expect "the probe picks one key in each sixteenth of the node group's slots" \
  bash -c '[ "$(grep -c "^  svp:lab:probe:" "$1")" = 16 ]' _ "$work/out"
expect "the first key is the first candidate the cluster puts in the lowest sixteenth" \
  grep -qx '  svp:lab:probe:25 8616' "$work/out"
expect "the last key is the first candidate the cluster puts in the highest sixteenth" \
  grep -qx '  svp:lab:probe:16 16000' "$work/out"
expect "each attempt writes and reads every key, in slot order, as a cluster client" \
  bash -c '[ "$(wc -l <<<"$1" | tr -d " ")" = 32 ] && [[ $(head -n 1 <<<"$1") == "SET svp:lab:probe:25 "* ]] &&
    [ "$(sed -n 2p <<<"$1")" = "GET svp:lab:probe:25" ] && [ "$(tail -n 1 <<<"$1")" = "GET svp:lab:probe:16" ] &&
    grep "^valkey-cli" "$2" | sed -n 2p | grep -q -- " -c | auth=env$"' _ "$(call 2)" "$log"
expect "a redirect line before the right replies is a success" \
  bash -c '[ "$(sed -n 1p "$1" | cut -f 6)" = ok ]' _ "$(logof)"
expect "an error after a redirect fails with the error, not the redirect line" \
  bash -c '[ "$(sed -n 2p "$1" | cut -f 6-)" = "fail	NOPERM no permissions" ]' _ "$(logof)"
expect "one key read back wrong fails the attempt" bash -c '[ "$(sed -n 3p "$1" | cut -f 6-)" = "fail	17" ]' _ "$(logof)"
expect "the attempt after them succeeds" bash -c '[ "$(sed -n 4p "$1" | cut -f 6)" = ok ]' _ "$(logof)"
reset
kv probe 3 "$cme" 0-500,16050-16100
expect "slots in two ranges: keys in both" \
  bash -c 'grep -qx "  svp:lab:probe:213 8" "$1" && grep -qx "  svp:lab:probe:98 16080" "$1"' _ "$work/out"
expect "a part of the slots that holds no candidate gets no key" \
  bash -c '[ "$(grep -c "^  svp:lab:probe:" "$1")" = 13 ]' _ "$work/out"
reset
expect "a node group no candidate hashes into is refused" refused probe 3 "$cme" 16383
expect "the refusal says why" grep -q 'none of 1024 keys hashes into slots 16383' "$work/out"
expect "a refused key starts no probe" bash -c '! grep -q "^  < SET" "$1"' _ "$log"

# --- probe on a group with cluster mode off: attempts ok, failed, cut off, answered wrong -----------------------------
reset
printf 'ok\nfail\nhang\nstale\nok\n' >"$state/seq.$cmd"
kv probe 4 "$cmd"
expect "a probe without slots writes the fixed key, not as a cluster client" \
  bash -c 'grep -q "^  < SET svp:lab:probe " "$1" && ! grep "^valkey-cli" "$1" | grep -q -- " -c "' _ "$log"
expect "every attempt is cut off after 2 s" bash -c '! grep "^timeout" "$1" | grep -qv "^timeout 2 valkey-cli$"' _ "$log"
expect "a refused connection fails the attempt with the client's error" \
  grep -q '	fail	Could not connect to Valkey at .*: Connection refused$' "$(logof)"
expect "an attempt with no answer in time fails" grep -q '	fail	no answer within 2 s$' "$(logof)"
expect "a read that returns another value fails" grep -q '	fail	17$' "$(logof)"
expect "the log carries the address of the resolver" grep -q '	10.67.17.10	ok	$' "$(logof)"
expect "the probe reports the window around the three failures" grep -qE '^error window 1: [0-9]+ ms, 3 failed attempts' \
  "$work/out"

# --- TLS and password rules -------------------------------------------------------------------------------------------
expect "every valkey-cli call is TLS with the CA file, as the lab's user, on 6379" \
  bash -c '! grep "^valkey-cli" "$1" | grep -qv "^valkey-cli --tls --cacert /etc/pki/tls/certs/ca-bundle.crt -h [^ ]* -p 6379 --user svp-lab-ds-kv-app"' \
  _ "$log"
expect "valkey-cli gets the password through VALKEYCLI_AUTH, never on its command line" \
  bash -c '! grep "^valkey-cli" "$1" | grep -qv "| auth=env$" && ! grep "^valkey-cli" "$1" | grep -q -- "$2"' _ "$log" "$FAKE_PW"
expect "the secret is read with the Region and no profile" \
  grep -q '^aws secretsmanager get-secret-value --secret-id svp-lab-ds-kv-app --query SecretString --output text --region ap-southeast-1$' \
  "$log"
expect "the probe never prints the password" no_password

# --- bench: one log line per batch, the output by minute --------------------------------------------------------------
reset
printf 'reset\nwrongpass\nmoved\nok\n' >"$state/bench_seq"
kv bench 9 "$cme" cluster
expect "bench runs batches until its seconds run out" \
  bash -c '[ "$(grep -c "^valkey-benchmark" "$1")" = 4 ]' _ "$log"
expect "a batch with warnings only (CONFIG refused, slots reloaded) logs its rates, 0 error lines and exit 0" \
  grep -qE '^20[0-9-]+T[0-9:.]+Z	[0-9]+	20[0-9-]+T[0-9:.]+Z	[0-9]+	10000.00	12000.00	0	0	$' "$(benchlog)"
expect "a batch with no warning beyond CONFIG logs 0 error lines too" \
  grep -qE '	11000.00	12000.00	0	0	$' "$(benchlog)"
expect "a batch that loses its connection logs no rates, its error line and its exit" \
  grep -qE '	-	-	1	1	Error: Connection reset by peer$' "$(benchlog)"
expect "a node's error reply logs both of its lines as one first error" \
  grep -qE '	-	-	2	1	Node 10.67.17.20:6379 replied with error: WRONGPASS invalid username-password pair or user is disabled.$' \
  "$(benchlog)"
expect "the output gives the batches of each minute: lowest, highest, mean rate, errors and the first" \
  grep -qx '2027-01-15T08:00Z: 4 batches, SET 10000.00-11000.00 req/s (mean 10500.00), GET 12000.00-12000.00 req/s (mean 12000.00), 3 error lines, 2 non-zero exits, first error: Error: Connection reset by peer' \
  "$work/out"
expect "the output ends with the whole log" \
  grep -qE '^bench log: 4 batches from 2027-01-15T08:00:00.[0-9]{3}Z to 2027-01-15T08:00:[0-9]{2}.[0-9]{3}Z, 3 error lines, 2 non-zero exits$' \
  "$work/out"
expect "the output holds no line per batch" bash -c '! grep -q "req/s, GET" "$1" && ! grep -q "	" "$1"' _ "$work/out"
expect "rates reads the same log again" bash -c 'grep "^2027" "$1" >"$1.minute" && bash "$2" rates "$3" | grep -qxFf "$1.minute"' \
  _ "$work/out" "$src/kv.sh" "$(benchlog)"
expect "the full output keeps what each batch printed on stdout and on stderr" \
  bash -c 'grep -q "^WARNING: Could not fetch node CONFIG" "$1" && grep -q "^\"SET\"," "$1"' _ "$(dirname "$(benchlog)")/bench.out"
expect "bench on cme runs as a cluster client over TLS" \
  bash -c 'grep "^valkey-benchmark" "$1" | head -n 1 | grep -q -- "--tls --cacert /etc/pki/tls/certs/ca-bundle.crt -h $2 -p 6379 --user svp-lab-ds-kv-app -a .* --cluster -t set,get"' \
  _ "$log" "$cme"
expect "bench leaves out -e, which valkey-benchmark 9.0.7 ignores with a warning" \
  bash -c '! grep "^valkey-benchmark" "$1" | grep -q -- " -e "' _ "$log"
expect "bench never prints the password" no_password
reset
echo hang >"$state/bench_seq"
kv bench 70 "$cme" cluster
expect "a batch cut off by its timeout logs no rates and its exit" grep -qE '	-	-	0	124	$' "$(benchlog)"
expect "a minute of batches cut off only says no result" \
  grep -qE '^2027-01-15T08:00Z: 1 batches, SET no result, GET no result, 0 error lines, 1 non-zero exits$' "$work/out"
expect "the next minute has the batches that ran" grep -qE '^2027-01-15T08:01Z: [0-9]+ batches, SET 10000.00-' "$work/out"
# Error lines in every batch of the longest run, at one batch every 50 s or so: the output must still fit in what
# get-command-invocation returns of it.
reset
printf 'wrongpass\n%.0s' {1..100} >"$state/bench_seq"
echo 50000 >"$state/bench_ms"
kv bench 3300 "$cme" cluster
expect "the longest bench gives one line per minute" \
  bash -c '[ "$(grep -c "^2027-01-15T[0-9:]*Z: " "$1")" -ge 55 ]' _ "$work/out"
expect "the longest bench with errors in every batch prints under 24 000 characters" \
  bash -c '[ "$(wc -c <"$1")" -lt 24000 ]' _ "$work/out"
expect "the first error of a minute is cut to 100 characters" \
  bash -c '! grep -q "first error: .\{101\}" "$1"' _ "$work/out"
reset
expect "a missing bench log is refused" refused rates "$work/none.log"
reset
kv bench 1 "$cmd" plain
expect "bench on cmd is not a cluster client" bash -c '! grep "^valkey-benchmark" "$1" | grep -q -- --cluster' _ "$log"
expect "bench refuses another mode" refused bench 5 "$cmd" fast

# --- client: the examples on both groups ------------------------------------------------------------------------------
reset
kv client "$cme" "$cmd"
expect "client shows the slots of svp keys" grep -q '> CLUSTER KEYSLOT svp:gw:rl:register:203.0.113.7' "$work/out"
expect "client reads once without following MOVED, then as a cluster client" \
  bash -c 'grep -A 4 "^valkey-cli .* -h $2 -p 6379 --user svp-lab-ds-kv-app | auth=env$" "$1" | grep -q "^  < GET svp:feed:" &&
    grep -A 4 "^valkey-cli .* -h $2 -p 6379 --user svp-lab-ds-kv-app -c | auth=env$" "$1" | grep -q "^  < GET svp:feed:"' \
  _ "$log" "$cme"
expect "client sends a command on two svp keys and on two hash-tagged keys" \
  bash -c 'grep -q "^  < MSET svp:gw:rl:register:203.0.113.7 1 svp:gw:rl:view-once:user-1:video-1 1$" "$1" &&
    grep -q "^  < MGET svp:gw:{user-1}:rl:view-once:video-1 svp:gw:{user-1}:login-known$" "$1"' _ "$log"
expect "client selects the databases svp uses on both groups" \
  bash -c '[ "$(grep -c "^  < SELECT 10$" "$1")" = 2 ] && [ "$(grep -c "^  < SELECT 14$" "$1")" = 2 ]' _ "$log"
expect "client prints the replies as the server gives them" grep -q '   < reply to SELECT 10' "$work/out"
expect "client never prints the password" no_password

# --- arguments refused before anything runs ---------------------------------------------------------------------------
reset
expect "a host outside ElastiCache is refused" refused probe 10 example.com
expect "a run longer than the SSM command is refused" refused probe 3301 "$cmd"
expect "slots that are not ranges are refused" refused probe 10 "$cme" '0-100;rm'
expect "nothing ran for refused arguments" bash -c '[ ! -s "$1" ]' _ "$log"
expect "an unknown command is refused" refused flush "$cme"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed" >&2
  exit 1
fi
echo "all passed"
