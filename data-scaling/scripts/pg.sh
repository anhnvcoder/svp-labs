#!/usr/bin/env bash
# Measures of the postgres part of the data-scaling lab: steady write load, replica lag, error window of a failover,
# connections of a burst, p95 read latency. Reads /etc/svp-lab-ds-pg.conf (from the user data) and the master user
# from Secrets Manager; writes the lab's tables on the given endpoint and its logs in a new directory under SVP_DS_RUN.
# Runs on: instance

# Every time comes from this machine's clock in milliseconds. TLS is always verify-full: the RDS bundle for a database
# endpoint, the Amazon Trust Services roots for a proxy endpoint (ACM). Design notes: data-scaling/README.md.
# Usage: pg.sh init HOST | load HOST RATE SECONDS | lag WRITER READER [SAMPLES] | probe write|read SECONDS HOST [HOST] |
#   burst HOST CLIENTS SECONDS | read HOST RATE SECONDS | window LOG
set -euo pipefail

conf=${SVP_DS_CONF:-/etc/svp-lab-ds-pg.conf}
# shellcheck source=/dev/null
. "$conf"
: "${SVP_DS_REGION:?} ${SVP_DS_SECRET_ID:?} ${SVP_DS_DB:?} ${SVP_DS_CA:?} ${SVP_DS_PROXY_CA:?} ${SVP_DS_RUN:?}"
# The same sample data on every endpoint compared: videos rows of view_counts, five likes each.
videos=100000
likes=500000
# A run must end before the SSM command's timeout (3600 s) of the session script.
max_seconds=3300
# Probe: one attempt every period_ms, each on a new connection; 2 s is the shortest connect_timeout libpq applies.
# The whole attempt is cut off at the same limit: RDS Proxy accepts a connection at once and holds its statement while
# no writer is up, so a limit on connecting alone would let an attempt wait through the failover and count as a success.
period_ms=500
connect_timeout=2
# Lag: the reader is polled every poll seconds inside one session; a sample waits at most lag_limit seconds.
poll=0.01
lag_limit=30
# The Route 53 Resolver of the VPC, asked directly by the probe so that no local cache stands between it and a failover.
resolver=169.254.169.253

fail() {
  echo "pg: $*" >&2
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

# login: the master user of the secret into a password file only this process can read, removed on exit, instead of
# PGPASSWORD, which other users may see in the environment of the process. The password is never printed.
login() {
  local json
  json=$(aws secretsmanager get-secret-value --secret-id "$SVP_DS_SECRET_ID" --query SecretString --output text \
    --region "$SVP_DS_REGION") || fail "cannot read secret $SVP_DS_SECRET_ID"
  [[ $(jq -r .password <<<"$json") =~ ^[A-Za-z0-9]+$ ]] ||
    fail "the password in $SVP_DS_SECRET_ID is not letters and digits"
  PGUSER=$(jq -r .username <<<"$json")
  PGPASSFILE=$(umask 077 && mktemp)
  export PGUSER PGPASSFILE
  trap 'rm -f "$PGPASSFILE"' EXIT
  trap 'exit 143' TERM INT
  jq -r '"*:*:*:" + .username + ":" + .password' <<<"$json" >"$PGPASSFILE"
}

# use HOST: points psql and pgbench at HOST through libpq's environment. An RDS Proxy endpoint presents an ACM
# certificate, verified against the Amazon Trust Services roots; a database endpoint one of the RDS CA.
use() {
  [[ $1 =~ ^[a-z0-9][a-z0-9.-]*\.rds\.amazonaws\.com$ ]] || fail "'$1' is not an RDS or RDS Proxy endpoint"
  export PGHOST=$1 PGPORT=5432 PGDATABASE=$SVP_DS_DB PGSSLMODE=verify-full PGCONNECT_TIMEOUT=$connect_timeout
  case $1 in
    *.proxy-*) export PGSSLROOTCERT=$SVP_DS_PROXY_CA ;;
    *) export PGSSLROOTCERT=$SVP_DS_CA ;;
  esac
}

sql() { psql -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

# A minimal copy of the engagement tables of svp, plus the lab's own marks of the lag and the probe.
schema_sql() {
  cat <<'EOF'
CREATE TABLE IF NOT EXISTS view_counts (
  video_id uuid PRIMARY KEY,
  view_count bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS likes (
  video_id uuid NOT NULL,
  user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (video_id, user_id)
);
CREATE TABLE IF NOT EXISTS lag_marks (
  id text PRIMARY KEY,
  written_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS probe_marks (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  host text NOT NULL,
  written_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
EOF
}

# Video ids are md5('video-<n>') for n from 1 to videos, so a script picks an existing video without reading a table.
cmd_init() {
  local host=$1
  login
  use "$host"
  schema_sql | sql -f -
  sql -f - <<EOF
INSERT INTO view_counts (video_id, view_count)
  SELECT md5('video-' || i)::uuid, (random() * 1000)::bigint FROM generate_series(1, $videos) AS i
  ON CONFLICT DO NOTHING;
INSERT INTO likes (video_id, user_id)
  SELECT md5('video-' || (1 + i % $videos))::uuid, md5('user-' || i)::uuid FROM generate_series(1, $likes) AS i
  ON CONFLICT DO NOTHING;
ANALYZE;
EOF
  echo "init $host: view_counts $(sql -c "SELECT count(*) FROM view_counts") rows, likes" \
    "$(sql -c "SELECT count(*) FROM likes") rows"
}

# One transaction of the write load: a view counted and a like added on a random video, as engagement-service does.
write_script() {
  cat <<'EOF'
\set v random(1, :videos)
BEGIN;
INSERT INTO view_counts (video_id, view_count) VALUES (md5('video-' || :v)::uuid, 1)
  ON CONFLICT (video_id) DO UPDATE SET view_count = view_counts.view_count + 1, updated_at = now();
INSERT INTO likes (video_id, user_id) VALUES (md5('video-' || :v)::uuid, gen_random_uuid()) ON CONFLICT DO NOTHING;
COMMIT;
EOF
}

read_script() {
  cat <<'EOF'
\set v random(1, :videos)
SELECT view_count FROM view_counts WHERE video_id = md5('video-' || :v)::uuid;
EOF
}

# summary: the lines of a pgbench report the lab reads, and any client it aborted.
summary() {
  local keep='number of transactions actually processed|number of failed transactions|latency average|latency stddev'
  keep+='|average connection time|tps =|rate limit schedule lag'
  grep -E "^($keep)|aborted" || true
}

# Steady write load at a fixed rate for SECONDS. pgbench drops a client whose connection dies (a failover): the load
# starts again for the time left, so it runs through the whole measure.
cmd_load() {
  local host=$1 rate=$2 seconds=$3 start end left out rc
  posint rate "$rate"
  seconds_arg "$seconds"
  login
  use "$host"
  workdir load
  write_script >"$run/write.sql"
  start=$(now_ms)
  end=$((start + seconds * 1000))
  echo "load $host: $rate transactions/s, from $(utc "$start") for $seconds s"
  while left=$(((end - $(now_ms) + 999) / 1000)) && [ "$left" -gt 0 ]; do
    rc=0
    out=$(pgbench -n -c 4 -j 2 -R "$rate" -T "$left" -D "videos=$videos" -f "$run/write.sql" 2>&1) || rc=$?
    summary <<<"$out"
    [ "$rc" = 0 ] || echo "pgbench ended with $rc at $(utc "$(now_ms)"); load starts again for the time left"
    [ "$rc" = 0 ] || sleep 1
  done
  echo "load $host ended $(utc "$(now_ms)")"
}

# poll_sql ID: polls in one session until the mark ID is visible, each statement on a new snapshot, or raises an
# error after lag_limit seconds.
poll_sql() {
  cat <<EOF
DO \$\$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
  LOOP
    PERFORM 1 FROM lag_marks WHERE id = '$1';
    EXIT WHEN FOUND;
    IF clock_timestamp() - t0 > interval '$lag_limit seconds' THEN
      RAISE EXCEPTION 'mark $1 not seen';
    END IF;
    PERFORM pg_sleep($poll);
  END LOOP;
END
\$\$;
EOF
}

# Replica lag: the poller connects to the reader first, then a mark is written on the writer; the lag runs from the
# write's return to the poller's, both on this clock.
cmd_lag() {
  local writer=$1 reader=$2 samples=${3:-30} n id pid t seen missed=0 sorted
  local -a lats=()
  posint samples "$samples"
  use "$reader"
  use "$writer"
  login
  workdir lag
  for ((n = 1; n <= samples; n++)); do
    id="lag-$(now_ms)-$n"
    # The poller becomes psql itself, so that the kill below ends its session on the reader, not only a subshell.
    (use "$reader" && exec psql -X -q -t -A -v ON_ERROR_STOP=1 -f - <<<"$(poll_sql "$id")") >"$run/lag.out" 2>&1 &
    pid=$!
    sleep 1
    if ! (use "$writer" && sql -c "INSERT INTO lag_marks (id) VALUES ('$id')") >/dev/null 2>"$run/lag.err"; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      missed=$((missed + 1))
      echo "lag $n: write failed on the writer: $(head -n 1 "$run/lag.err")"
      continue
    fi
    t=$(now_ms)
    if wait "$pid"; then
      seen=$(now_ms)
      lats+=("$((seen - t))")
      echo "lag $n: $((seen - t)) ms (written $(utc "$t"), seen on the reader $(utc "$seen"))"
    else
      missed=$((missed + 1))
      echo "lag $n: not seen on the reader within $lag_limit s (written $(utc "$t")): $(head -n 1 "$run/lag.out")"
    fi
  done
  if [ "${#lats[@]}" -gt 0 ]; then
    sorted=$(printf '%s\n' "${lats[@]}" | sort -n)
    echo "replica lag $writer -> $reader over ${#lats[@]} samples: median" \
      "$(sed -n "$((${#lats[@]} / 2 + 1))p" <<<"$sorted") ms, max $(tail -n 1 <<<"$sorted") ms" \
      "(resolution: poll every $poll s)"
  fi
  [ "$missed" = 0 ] || fail "$missed of $samples samples never reached the reader"
}

# address HOST: the IPv4 address the VPC resolver gives for HOST right now, after its CNAMEs; empty without one.
address() {
  dig "@$resolver" +short +time=1 +tries=1 "$1" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | tail -n 1 || true
}

# probe_loop MODE SECONDS HOST: one line per attempt: start as UTC and epoch ms, end as UTC and epoch ms, address, ok
# or fail, first line of the error. Each attempt resolves the name again and opens a new connection to that address;
# TLS checks the name. An attempt with no answer within connect_timeout seconds is ended and fails.
probe_loop() {
  local mode=$1 seconds=$2 host=$3 stmt t end addr status reason rc ended
  use "$host"
  case $mode in
    write) stmt="INSERT INTO probe_marks (host) VALUES ('$host')" ;;
    read) stmt="SELECT view_count FROM view_counts WHERE video_id = md5('video-1')::uuid" ;;
  esac
  end=$(($(now_ms) + seconds * 1000))
  while [ "$(now_ms)" -lt "$end" ]; do
    t=$(now_ms)
    addr=$(address "$host")
    status=fail rc=0
    if [ -z "$addr" ]; then
      reason="no address for $host"
    else
      reason=$(PGHOSTADDR=$addr timeout "$connect_timeout" psql -X -q -t -A -v ON_ERROR_STOP=1 -c "$stmt" 2>&1 \
        >/dev/null) || rc=$?
      case $rc in
        0) status=ok reason= ;;
        124) reason="no answer within $connect_timeout s" ;;
      esac
    fi
    ended=$(now_ms)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(utc "$t")" "$t" "$(utc "$ended")" "$ended" "${addr:--}" "$status" \
      "$(head -n 1 <<<"$reason" | tr '\t' ' ')"
    [ $((ended - t)) -ge "$period_ms" ] || sleep "$(secs $((period_ms - ended + t)))"
  done
}

# window LOG: each chain of failed attempts in a probe log, timed from the end of the last success before it to the
# end of the first success after it: a success counts once its answer arrives. A chain that has no success on one side
# has no window, and says so instead of printing a number.
cmd_window() {
  local log=$1
  [ -s "$log" ] || fail "no probe log $log"
  awk -F'\t' -v period="$period_ms" -v timeout="$connect_timeout" '
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
        printf " window not closed\nlast error: %s\n", reason
      }
      fails = 0
    }
    $6 == "ok" {
      if (fails > 0) chain(1)
      last_ok = $4; last_ok_utc = $3; oks++
      if ($4 - $2 > slowest) slowest = $4 - $2
      next
    }
    $6 == "fail" { if (fails == 0) first_fail = $1; last_fail = $3; fails++; failed++; reason = $7; next }
    END {
      if (fails > 0) chain(0)
      if (failed == 0) printf "no failed attempt in %d attempts: no error window\n", oks
      printf "attempts: %d ok", oks
      if (oks > 0) printf " (slowest %d ms)", slowest
      printf ", %d failed; a new one every %d ms or when the last ends, each cut off after %d s (resolution)\n",
        failed, period, timeout
    }' "$log"
}

# Probes on one or two endpoints side by side, so that both see the same failover.
cmd_probe() {
  local mode=$1 seconds=$2 i host
  local -a pids=() hosts=()
  shift 2 || true
  case $mode in
    write | read) ;;
    *) fail "probe mode must be write or read" ;;
  esac
  seconds_arg "$seconds"
  [ $# -ge 1 ] && [ $# -le 2 ] || fail "probe takes one or two endpoints"
  for host in "$@"; do use "$host"; done
  login
  workdir probe
  echo "probe $mode from $(utc "$(now_ms)") for $seconds s"
  i=0
  for host in "$@"; do
    i=$((i + 1))
    probe_loop "$mode" "$seconds" "$host" >"$run/probe-$i.log" &
    pids+=("$!")
    hosts+=("$host")
  done
  for i in "${!pids[@]}"; do wait "${pids[$i]}" || true; done
  for i in "${!hosts[@]}"; do
    echo "== ${hosts[$i]} ($mode, log $run/probe-$((i + 1)).log)"
    cmd_window "$run/probe-$((i + 1)).log"
  done
}

# Many short-lived clients: pgbench opens a new connection for each transaction (-C), as a burst of functions would.
cmd_burst() {
  local host=$1 clients=$2 seconds=$3 jobs=2 start out rc=0
  posint clients "$clients"
  seconds_arg "$seconds"
  [ "$clients" -ge 2 ] || jobs=1
  login
  use "$host"
  workdir burst
  read_script >"$run/read.sql"
  start=$(now_ms)
  out=$(pgbench -n -C -c "$clients" -j "$jobs" -T "$seconds" -D "videos=$videos" -f "$run/read.sql" 2>&1) || rc=$?
  echo "burst $host: $clients clients, a new connection per transaction, $(utc "$start") to $(utc "$(now_ms)")"
  summary <<<"$out"
  [ "$rc" = 0 ] || echo "pgbench ended with $rc"
}

# p95 FILE...: the 95th percentile by nearest rank of the latencies (microseconds, third field) of pgbench logs: the
# value of rank ceil(0.95 n) among the n sorted latencies. Failed or skipped transactions carry no latency.
p95() {
  local sorted n rank other
  sorted=$(awk '$3 ~ /^[0-9]+$/ {print $3}' "$@" | sort -n)
  other=$(awk '$3 !~ /^[0-9]+$/' "$@" | wc -l | tr -d ' ')
  n=$(grep -c . <<<"$sorted" || true)
  [ "$n" -gt 0 ] || fail "no transaction with a latency in the pgbench log"
  rank=$(((95 * n + 99) / 100))
  echo "p95 read latency: $(us "$(sed -n "${rank}p" <<<"$sorted")") ms (nearest rank $rank of $n transactions)," \
    "max $(us "$(tail -n 1 <<<"$sorted")") ms; failed or skipped: $other"
}

# us MICROSECONDS: as milliseconds with three decimals.
us() { printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"; }

cmd_read() {
  local host=$1 rate=$2 seconds=$3 start out rc=0
  posint rate "$rate"
  seconds_arg "$seconds"
  login
  use "$host"
  workdir read
  read_script >"$run/read.sql"
  start=$(now_ms)
  out=$(pgbench -n -c 4 -j 2 -R "$rate" -T "$seconds" -D "videos=$videos" -f "$run/read.sql" \
    --log --log-prefix="$run/p95" 2>&1) || rc=$?
  echo "read $host: $rate transactions/s, $(utc "$start") to $(utc "$(now_ms)") (pgbench logs in $run)"
  summary <<<"$out"
  [ "$rc" = 0 ] || echo "pgbench ended with $rc"
  compgen -G "$run/p95.*" >/dev/null || fail "pgbench wrote no log"
  p95 "$run"/p95.*
}

need() { [ "$1" -ge "$2" ] || fail "usage: ${usage}"; }
usage="pg.sh init HOST | load HOST RATE SECONDS | lag WRITER READER [SAMPLES] | probe write|read SECONDS HOST [HOST] |"
usage+=" burst HOST CLIENTS SECONDS | read HOST RATE SECONDS | window LOG"

cmd=${1:-}
shift || true
case $cmd in
  init) need $# 1 && cmd_init "$1" ;;
  load) need $# 3 && cmd_load "$1" "$2" "$3" ;;
  lag) need $# 2 && cmd_lag "$1" "$2" "${3:-}" ;;
  probe) need $# 3 && cmd_probe "$@" ;;
  burst) need $# 3 && cmd_burst "$1" "$2" "$3" ;;
  read) need $# 3 && cmd_read "$1" "$2" "$3" ;;
  window) need $# 1 && cmd_window "$1" ;;
  *) fail "usage: $usage" ;;
esac
