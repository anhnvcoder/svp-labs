#!/usr/bin/env bash
# Measures of the valkey part of the data-scaling lab: error window of a failover or reshard on the keys of one shard,
# valkey-benchmark throughput in batches, what a client sees with cluster mode on and off. Reads the secret and
# /etc/svp-lab-ds-kv.conf; writes svp:lab:probe*, svp:gw:* (client) and key:* (benchmark) keys, logs under SVP_DS_RUN.
# Runs on: instance

# Every time comes from this machine's clock in milliseconds. TLS checks the chain against the system CA bundle; the
# replies are printed as the server gives them. Design notes: data-scaling/README.md.
# Usage: kv.sh probe SECONDS HOST [SLOTS] | bench SECONDS HOST cluster|plain | client CME_HOST CMD_HOST | window LOG |
#   rates LOG
set -euo pipefail
export AWS_PAGER=""

conf=${SVP_DS_CONF:-/etc/svp-lab-ds-kv.conf}
# shellcheck source=/dev/null
. "$conf"
: "${SVP_DS_REGION:?} ${SVP_DS_SECRET_ID:?} ${SVP_DS_CA:?} ${SVP_DS_RUN:?}"
port=6379
# A run must end before the SSM command's timeout (3600 s) of the session script.
max_seconds=3300
# Probe: an attempt every period_ms on a new connection that writes and reads its keys, cut off at attempt_timeout s.
period_ms=500
attempt_timeout=2
# On a shard, each attempt covers up to probe_keys keys spread evenly over its slots, so that the block of slots a
# reshard moves away holds some of them; they are picked among svp:lab:probe:1 to :probe_candidates.
probe_keys=16
probe_candidates=1024
# Benchmark: one batch of requests per test (SET, GET) at a time, so that each batch is one point of throughput.
bench_requests=20000
bench_clients=10
bench_timeout=60
# Keys svp's services write (gateway rate limits, the feed's explore cache), as the client examples use them.
gw_key=svp:gw:rl:register:203.0.113.7
gw_key2=svp:gw:rl:view-once:user-1:video-1
feed_key=svp:feed:explore:v1:first:20

fail() {
  echo "kv: $*" >&2
  exit 1
}

now_ms() { date +%s%3N; }
# utc MS: the time as RFC 3339 in UTC with milliseconds.
utc() { printf '%s.%03dZ' "$(date -u -d "@$(($1 / 1000))" +%Y-%m-%dT%H:%M:%S)" "$(($1 % 1000))"; }
# secs MS: milliseconds as seconds with three decimals.
secs() { printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"; }

# workdir NAME: a new directory under SVP_DS_RUN for the files of this run, so that runs side by side share none.
workdir() {
  mkdir -p "$SVP_DS_RUN"
  run=$(mktemp -d "$SVP_DS_RUN/$1.XXXXXX")
}

posint() { [[ $2 =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive whole number, not '$2'"; }
seconds_arg() {
  posint seconds "$1"
  [ "$1" -le "$max_seconds" ] || fail "seconds must be at most $max_seconds, under the timeout of the SSM command"
}
host_arg() { [[ $1 =~ ^[a-z0-9][a-z0-9.-]*\.cache\.amazonaws\.com$ ]] || fail "'$1' is not an ElastiCache endpoint"; }

# login: the user of the secret. valkey-cli takes the password from VALKEYCLI_AUTH, which only this user and root may
# read in the process environment; valkey-benchmark has no such way and gets it on its command line (bench).
login() {
  local json
  json=$(aws secretsmanager get-secret-value --secret-id "$SVP_DS_SECRET_ID" --query SecretString --output text \
    --region "$SVP_DS_REGION") || fail "cannot read secret $SVP_DS_SECRET_ID"
  [[ $(jq -r .password <<<"$json") =~ ^[A-Za-z0-9]+$ ]] ||
    fail "the password in $SVP_DS_SECRET_ID is not letters and digits"
  kv_user=$(jq -r .username <<<"$json")
  VALKEYCLI_AUTH=$(jq -r .password <<<"$json")
  export VALKEYCLI_AUTH
  trap 'exit 143' TERM INT
}

# cli HOST ARGS...: valkey-cli over TLS as the lab's user; -c among ARGS follows MOVED as a cluster client does.
cli() {
  local host=$1
  shift
  valkey-cli --tls --cacert "$SVP_DS_CA" -h "$host" -p "$port" --user "$kv_user" "$@"
}

# pick_keys HOST RANGES: probe keys whose hash slot, as the cluster computes it, lies in RANGES (a node group's slots
# as ElastiCache lists them: 0-8191 or 0-5460,8192): RANGES cut into probe_keys equal parts by slot count, the first
# candidate in each part. Prints one "key slot" line per part that holds a candidate, in slot order.
pick_keys() {
  local host=$1 ranges=$2 i keys
  local -a slots=()
  mapfile -t slots < <(for ((i = 1; i <= probe_candidates; i++)); do echo "CLUSTER KEYSLOT svp:lab:probe:$i"; done |
    cli "$host" 2>&1)
  [ "${#slots[@]}" -gt 0 ] || fail "no answer to CLUSTER KEYSLOT from $host"
  for i in "${slots[@]}"; do
    [[ $i =~ ^[0-9]+$ ]] || fail "CLUSTER KEYSLOT on $host answered '$i'"
  done
  keys=$(printf '%s\n' "${slots[@]}" | awk -v r="$ranges" -v k="$probe_keys" '
    BEGIN {
      n = split(r, parts, ",")
      for (i = 1; i <= n; i++) {
        if (split(parts[i], b, "-") == 1) b[2] = b[1]
        lo[i] = b[1] + 0; hi[i] = b[2] + 0; off[i] = total; total += hi[i] - lo[i] + 1
      }
    }
    {
      for (i = 1; i <= n; i++) {
        if ($1 < lo[i] || $1 > hi[i]) continue
        part = int((off[i] + $1 - lo[i]) * k / total)
        if (!(part in key)) key[part] = "svp:lab:probe:" NR " " $1
      }
    }
    END { for (p = 0; p < k; p++) if (p in key) print key[p] }')
  [ -n "$keys" ] || fail "none of $probe_candidates keys hashes into slots $ranges"
  printf '%s\n' "$keys"
}

# probe_loop SECONDS HOST CLUSTER KEY...: one line per attempt: start as UTC and epoch ms, end as UTC and epoch ms,
# the address the system resolver gives now, ok or fail, first line of the error. Each attempt opens a new connection,
# writes every KEY and reads it back: ok when every reply is right (with -c, valkey-cli also prints its redirects).
probe_loop() {
  local seconds=$1 host=$2 cflag=$3 t end addr status reason rc ended out want k
  local -a cargs=()
  shift 3
  [ -z "$cflag" ] || cargs=("$cflag")
  end=$(($(now_ms) + seconds * 1000))
  while [ "$(now_ms)" -lt "$end" ]; do
    t=$(now_ms)
    addr=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    status=fail rc=0
    out=$(for k in "$@"; do printf 'SET %s %s\nGET %s\n' "$k" "$t" "$k"; done |
      timeout "$attempt_timeout" valkey-cli --tls --cacert "$SVP_DS_CA" -h "$host" -p "$port" --user "$kv_user" \
        "${cargs[@]}" 2>&1) || rc=$?
    want=$(for k in "$@"; do printf 'OK\n%s\n' "$t"; done)
    if [ "$rc" = 124 ]; then
      reason="no answer within $attempt_timeout s"
    elif [ "$(grep -v '^-> Redirected' <<<"$out" | tail -n $(($# * 2)))" = "$want" ]; then
      status=ok reason=
    else
      reason=$(grep -v -x -e OK -e "$t" -e '' <<<"$out" | grep -v '^-> Redirected' | head -n 1 || true)
      [ -n "$reason" ] || reason="exit $rc, no reply"
    fi
    ended=$(now_ms)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(utc "$t")" "$t" "$(utc "$ended")" "$ended" "${addr:--}" "$status" \
      "$(tr '\t' ' ' <<<"$reason")"
    [ $((ended - t)) -ge "$period_ms" ] || sleep "$(secs $((period_ms - ended + t)))"
  done
}

# window LOG: each chain of failed attempts in a probe log, timed from the end of the last success before it to the
# end of the first success after it. A chain with no success on one side has no window, and says so.
cmd_window() {
  local log=$1
  [ -s "$log" ] || fail "no probe log $log"
  awk -F'\t' -v period="$period_ms" -v timeout="$attempt_timeout" '
    function chain(closed) {
      chains++
      if (closed && last_ok != "") {
        printf "error window %d: %d ms, %d failed attempts", chains, $4 - last_ok, fails
        printf " (last success ended %s, first success after ended %s)\n", last_ok_utc, $3
      } else if (closed) {
        printf "chain %d: %d failed attempts from %s to %s, no success before it: no window\n", chains, fails,
          first_fail, last_fail
      } else {
        printf "chain %d: %d failed attempts from %s to the end of the probe at %s, no success after it:", chains,
          fails, first_fail, last_fail
        printf " window not closed\n"
      }
      printf "first error: %s\n", reason
      fails = 0
    }
    $6 == "ok" {
      if (fails > 0) chain(1)
      last_ok = $4; last_ok_utc = $3; oks++
      if ($4 - $2 > slowest) slowest = $4 - $2
      next
    }
    $6 == "fail" { if (fails == 0) { first_fail = $1; reason = $7 } last_fail = $3; fails++; failed++; next }
    END {
      if (fails > 0) chain(0)
      if (failed == 0) printf "no failed attempt in %d attempts: no error window\n", oks
      printf "attempts: %d ok", oks
      if (oks > 0) printf " (slowest %d ms)", slowest
      printf ", %d failed; a new one every %d ms or when the last ends, each cut off after %d s (resolution)\n",
        failed, period, timeout
    }' "$log"
}

# Without SLOTS the endpoint is a group with cluster mode off and the key is fixed; with SLOTS (the node group's, from
# the session script) the probe writes keys of that shard through the configuration endpoint, as a cluster client.
cmd_probe() {
  local seconds=$1 host=$2 ranges=${3:-} picked cflag=''
  local -a keys=(svp:lab:probe)
  seconds_arg "$seconds"
  host_arg "$host"
  [ -z "$ranges" ] || [[ $ranges =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] ||
    fail "slots must look like 0-8191 or 0-5460,8192-10922, not '$ranges'"
  login
  if [ -n "$ranges" ]; then
    picked=$(pick_keys "$host" "$ranges") || exit 1
    mapfile -t keys < <(cut -d ' ' -f 1 <<<"$picked")
    cflag=-c
    echo "probe keys in the node group's slots $ranges, each with its slot:"
    awk '{print "  " $0}' <<<"$picked"
  fi
  workdir probe
  echo "probe $host from $(utc "$(now_ms)") for $seconds s"
  probe_loop "$seconds" "$host" "$cflag" "${keys[@]}" >"$run/probe.log"
  echo "== $host (log $run/probe.log)"
  cmd_window "$run/probe.log"
}

# rates LOG: a bench log by minute of this machine's clock, with the batches that started in it: SET and GET requests
# per second (lowest, highest, mean of the batches), error lines and the first one, batches that exited non-zero.
cmd_rates() {
  local log=$1
  [ -s "$log" ] || fail "no bench log $log"
  awk -F'\t' '
    function range(name, count, low, high, total) {
      if (count == 0) return name " no result"
      return sprintf("%s %.2f-%.2f req/s (mean %.2f)", name, low, high, total / count)
    }
    function add(v, which) {
      if (v == "-") return
      c[which]++; sum[which] += v
      if (c[which] == 1 || v + 0 < lo[which]) lo[which] = v + 0
      if (c[which] == 1 || v + 0 > hi[which]) hi[which] = v + 0
    }
    function flush() {
      printf "%s: %d batches, %s, %s, %d error lines, %d non-zero exits", minute, n,
        range("SET", c["s"], lo["s"], hi["s"], sum["s"]), range("GET", c["g"], lo["g"], hi["g"], sum["g"]), errs, bad
      if (first != "") printf ", first error: %s", substr(first, 1, 100)
      printf "\n"
      split("", c); split("", sum); split("", lo); split("", hi); n = errs = bad = 0; first = ""
    }
    {
      m = substr($1, 1, 16) "Z"
      if (m != minute && minute != "") flush()
      if (all == 0) from = $1
      minute = m; n++; all++; to = $3
      add($5, "s"); add($6, "g")
      errs += $7; all_errs += $7
      if ($8 != 0) { bad++; all_bad++ }
      if (first == "" && $9 != "") first = $9
    }
    END {
      flush()
      printf "bench log: %d batches from %s to %s, %d error lines, %d non-zero exits\n", all, from, to, all_errs,
        all_bad
    }' "$log"
}

# Throughput in batches until SECONDS run out: each batch logs its time span, the requests per second of SET and GET,
# and the errors it printed, so that a reshard or a failover shows as a dip or as errors at a known time. The
# output gives them by minute: SSM returns only the first 24 000 characters of a command's output.
cmd_bench() {
  local seconds=$1 host=$2 mode=$3 end t done_ms out rc set_rps get_rps errors first pass
  local -a cargs=()
  seconds_arg "$seconds"
  host_arg "$host"
  case $mode in
    cluster) cargs=(--cluster) ;;
    plain) ;;
    *) fail "bench mode must be cluster or plain" ;;
  esac
  login
  pass=$VALKEYCLI_AUTH
  workdir bench
  echo "bench $host ($mode): batches of $bench_requests requests per test, $bench_clients clients, from" \
    "$(utc "$(now_ms)") for $seconds s, one line per batch in $run/bench.log"
  end=$(($(now_ms) + seconds * 1000))
  while [ "$(now_ms)" -lt "$end" ]; do
    t=$(now_ms)
    rc=0
    # The password on the command line: the loader runs nothing but the lab's scripts, reached through SSM only.
    out=$(timeout "$bench_timeout" valkey-benchmark --tls --cacert "$SVP_DS_CA" -h "$host" -p "$port" \
      --user "$kv_user" -a "$pass" "${cargs[@]}" -t set,get -n "$bench_requests" -c "$bench_clients" -r 100000 \
      -d 64 --csv 2>"$run/batch.err") || rc=$?
    done_ms=$(now_ms)
    { printf '%s\n' "$out"; cat "$run/batch.err"; } >>"$run/bench.out"
    set_rps=$(awk -F'"' '$2 == "SET" {print $4}' <<<"$out")
    get_rps=$(awk -F'"' '$2 == "GET" {print $4}' <<<"$out")
    # Every stderr line but a WARNING (CONFIG refused, slots reloaded after MOVED or ASK) is an error; a node's error
    # reply takes two lines, "Node HOST:PORT replied with error:" and the reply, kept together as the first error.
    errors=$(grep -c -v -e '^WARNING:' -e '^$' "$run/batch.err" || true)
    first=$(grep -v -e '^WARNING:' -e '^$' "$run/batch.err" |
      awk 'NR == 1 {f = $0} NR == 2 && f ~ /:$/ {f = f " " $0} END {print f}' | tr '\t' ' ' || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(utc "$t")" "$t" "$(utc "$done_ms")" "$done_ms" "${set_rps:--}" \
      "${get_rps:--}" "$errors" "$rc" "$first" >>"$run/bench.log"
  done
  echo "== $host ended $(utc "$(now_ms)") (log $run/bench.log, full output $run/bench.out)"
  cmd_rates "$run/bench.log"
}

# show HOST TITLE ARGS... < COMMANDS: one example, its commands and the replies as the server gives them.
show() {
  local host=$1 title=$2 cmds
  local -a lines=()
  shift 2
  cmds=$(cat)
  mapfile -t lines <<<"$cmds"
  echo "-- $title"
  printf '   > %s\n' "${lines[@]}"
  cli "$host" "$@" <<<"$cmds" 2>&1 | sed 's/^/   < /' || true
}

# What changes for a client between cluster mode on (CME_HOST, the configuration endpoint) and off (CMD_HOST).
cmd_client() {
  local cme=$1 cmd=$2 tagged='svp:gw:{user-1}:rl:view-once:video-1' tagged2='svp:gw:{user-1}:login-known'
  host_arg "$cme"
  host_arg "$cmd"
  login
  echo "== cluster mode enabled, $cme"
  show "$cme" "hash slots of svp keys" <<EOF
CLUSTER KEYSLOT $gw_key
CLUSTER KEYSLOT $gw_key2
CLUSTER KEYSLOT $feed_key
CLUSTER KEYSLOT $tagged
CLUSTER KEYSLOT $tagged2
EOF
  show "$cme" "a client that is not cluster-aware: the node it reached answers MOVED for a slot it does not own" <<EOF
GET $gw_key
GET $gw_key2
GET $feed_key
EOF
  show "$cme" "the same reads by a cluster-aware client (-c follows MOVED)" -c <<EOF
GET $gw_key
GET $gw_key2
GET $feed_key
EOF
  show "$cme" "one command on two keys of different slots: CROSSSLOT" -c <<EOF
MSET $gw_key 1 $gw_key2 1
MGET $gw_key $gw_key2
EOF
  show "$cme" "the same keys with a hash tag: only {user-1} is hashed, both keys share a slot" -c <<EOF
MSET $tagged 1 $tagged2 1
MGET $tagged $tagged2
EOF
  show "$cme" "the databases svp uses (9, 10, 14) beside 0" -c <<EOF
SELECT 0
SELECT 9
SELECT 10
SELECT 14
EOF
  echo "== cluster mode disabled, $cmd"
  show "$cmd" "one command on two keys: one node holds every key" <<EOF
MSET $gw_key 1 $gw_key2 1
MGET $gw_key $gw_key2
EOF
  show "$cmd" "the databases svp uses (9, 10, 14) beside 0" <<EOF
SELECT 0
SELECT 9
SELECT 10
SELECT 14
EOF
}

need() { [ "$1" -ge "$2" ] || fail "usage: ${usage}"; }
usage="kv.sh probe SECONDS HOST [SLOTS] | bench SECONDS HOST cluster|plain | client CME_HOST CMD_HOST | window LOG"
usage+=" | rates LOG"

cmd=${1:-}
shift || true
case $cmd in
  probe) need $# 2 && cmd_probe "$1" "$2" "${3:-}" ;;
  bench) need $# 3 && cmd_bench "$1" "$2" "$3" ;;
  client) need $# 2 && cmd_client "$1" "$2" ;;
  window) need $# 1 && cmd_window "$1" ;;
  rates) need $# 1 && cmd_rates "$1" ;;
  *) fail "usage: $usage" ;;
esac
