#!/usr/bin/env bash
# Load, CDC lag and cutover of the dms-migration lab: reads /etc/svp-lab-dms.conf (from the user data), the DMS user's
# password from SSM and the target's credentials from Secrets Manager; writes rows into the source and the target.
# Runs on: instance

# The source is the local server over its Unix socket as postgres (peer authentication), the target RDS over TLS
# verify-full. Every time comes from this machine's clock in milliseconds, so a lag or a downtime never mixes clocks.
# Usage: pgload.sh init | password | setup [VIEWS] [LIKES] | start [RATE] | stop | lag [SAMPLES] | compare |
#   cutover TASK_ARN [LIMIT_S] | slots | drop-slots
set -euo pipefail

conf=${SVP_DMS_CONF:-/etc/svp-lab-dms.conf}
# shellcheck source=/dev/null
. "$conf"
: "${SVP_DMS_REGION:?} ${SVP_DMS_DB:?} ${SVP_DMS_USER:?} ${SVP_DMS_PARAMETER:?}"
: "${SVP_DMS_TARGET_SECRET:?} ${SVP_DMS_CA:?} ${SVP_DMS_RUN:?}"
run=$SVP_DMS_RUN
tables=(view_counts likes heartbeat)
# Seconds between two polls of the target, and how long one lag sample may wait.
poll=${SVP_DMS_POLL:-0.2}
sample_limit=${SVP_DMS_SAMPLE_LIMIT:-60}
# Timestamps print in UTC on both sides, so the checksums compare the same text.
export PGTZ=UTC

fail() {
  echo "pgload: $*" >&2
  exit 1
}

now_ms() { date +%s%3N; }
# utc MS: the time as RFC 3339 in UTC with milliseconds.
utc() { printf '%s.%03dZ' "$(date -u -d "@$(($1 / 1000))" +%Y-%m-%dT%H:%M:%S)" "$(($1 % 1000))"; }
# secs MS: milliseconds as seconds with three decimals.
secs() { printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"; }

as_postgres() { runuser -u postgres -- psql -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }
src() { as_postgres -d "$SVP_DMS_DB" "$@"; }

# target_login: reads the target secret into a password file only this process can read, removed on exit, instead of
# PGPASSWORD, which other users may see in the environment of the process.
target_login() {
  local json
  json=$(aws secretsmanager get-secret-value --secret-id "$SVP_DMS_TARGET_SECRET" --query SecretString --output text \
    --region "$SVP_DMS_REGION") || fail "cannot read secret $SVP_DMS_TARGET_SECRET"
  tgt_host=$(jq -r .host <<<"$json")
  tgt_port=$(jq -r .port <<<"$json")
  tgt_user=$(jq -r .username <<<"$json")
  [[ $(jq -r .password <<<"$json") =~ ^[A-Za-z0-9]+$ ]] || fail "the password in $SVP_DMS_TARGET_SECRET is not letters and digits"
  PGPASSFILE=$(umask 077 && mktemp)
  export PGPASSFILE
  trap 'rm -f "$PGPASSFILE"' EXIT
  trap 'exit 143' TERM INT
  jq -r '"*:*:*:" + .username + ":" + .password' <<<"$json" >"$PGPASSFILE"
}

tgt() {
  psql -X -q -t -A -v ON_ERROR_STOP=1 "host=$tgt_host port=$tgt_port dbname=$SVP_DMS_DB user=$tgt_user \
sslmode=verify-full sslrootcert=$SVP_DMS_CA connect_timeout=5" "$@"
}

# on SIDE ARGS...: psql on the source or the target.
on() {
  local side=$1
  shift
  case $side in
    source) src "$@" ;;
    target) tgt "$@" ;;
  esac
}

# dms_password: the parameter's value and version; retried while the instance role is still new to IAM.
dms_password() {
  local out n
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    out=$(aws ssm get-parameter --name "$SVP_DMS_PARAMETER" --with-decryption --output text \
      --query '[Parameter.Value,Parameter.Version]' --region "$SVP_DMS_REGION" 2>/dev/null) && break
    out=
    [ "$n" = 12 ] || sleep 5
  done
  [[ ${out%%$'\t'*} =~ ^[A-Za-z0-9]{16,}$ ]] || fail "cannot read a password from $SVP_DMS_PARAMETER"
  printf '%s' "$out"
}

# The statement goes to psql on stdin, never on its command line, where other users could read it.
cmd_password() {
  local out
  out=$(dms_password)
  printf "ALTER ROLE %s PASSWORD '%s';\n" "$SVP_DMS_USER" "${out%%$'\t'*}" | as_postgres -d postgres -f -
  echo "password of $SVP_DMS_USER set from $SVP_DMS_PARAMETER version ${out##*$'\t'}"
}

# DMS documents superuser for the user of a self-managed source with CDC; pg_hba.conf lets this user in over TLS from
# the DMS subnets only.
cmd_init() {
  as_postgres -d postgres -f - <<EOF
SELECT 'CREATE DATABASE $SVP_DMS_DB' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$SVP_DMS_DB')\gexec
SELECT 'CREATE ROLE $SVP_DMS_USER LOGIN SUPERUSER' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$SVP_DMS_USER')\gexec
EOF
  cmd_password
}

# A minimal copy of the engagement tables of svp; heartbeat is the lab's own. kind is varchar, not text: DMS moves
# text as a LOB.
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
CREATE TABLE IF NOT EXISTS heartbeat (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind varchar(16) NOT NULL,
  written_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
EOF
}

# Video ids are md5('video-<n>') for n from 1 to VIEWS, so the writer picks an existing video without reading a table.
cmd_setup() {
  local views=${1:-100000} likes=${2:-500000} t
  [[ $views =~ ^[1-9][0-9]*$ && $likes =~ ^[1-9][0-9]*$ ]] || fail "setup needs positive row counts"
  target_login
  schema_sql | src -f -
  schema_sql | tgt -f -
  src -f - <<EOF
INSERT INTO view_counts (video_id, view_count)
  SELECT md5('video-' || i)::uuid, (random() * 1000)::bigint FROM generate_series(1, $views) AS i ON CONFLICT DO NOTHING;
INSERT INTO likes (video_id, user_id)
  SELECT md5('video-' || (1 + i % $views))::uuid, md5('user-' || i)::uuid FROM generate_series(1, $likes) AS i
  ON CONFLICT DO NOTHING;
ANALYZE;
EOF
  mkdir -p "$run"
  echo "$views" >"$run/views"
  for t in "${tables[@]}"; do
    echo "source $t: $(src -c "SELECT count(*) FROM $t") rows; target $t: $(tgt -c "SELECT count(*) FROM $t") rows"
  done
}

# batch_sql RATE VIEWS: RATE statements, one transaction each: two view counts, one new like, one like removed.
batch_sql() {
  local i video="md5('video-' || (1 + floor(random() * $2))::int)::uuid"
  for ((i = 0; i < $1; i++)); do
    case $((i % 4)) in
      0 | 1) echo "INSERT INTO view_counts (video_id, view_count) VALUES ($video, 1) ON CONFLICT (video_id) DO UPDATE" \
        "SET view_count = view_counts.view_count + 1, updated_at = now();" ;;
      2) echo "INSERT INTO likes (video_id, user_id) VALUES ($video, gen_random_uuid()) ON CONFLICT DO NOTHING;" ;;
      3) echo "WITH v AS (SELECT $video AS id), d AS (SELECT l.video_id, l.user_id FROM likes l, v" \
        "WHERE l.video_id = v.id LIMIT 1) DELETE FROM likes l USING d" \
        "WHERE l.video_id = d.video_id AND l.user_id = d.user_id;" ;;
    esac
  done
}

# One line per second: UTC time, epoch ms, side, ok or fail. A batch that ends early sleeps the rest of the second.
cmd_write() {
  local side=$1 rate=$2 views t took
  views=$(cat "$run/views")
  [ "$side" = source ] || target_login
  while :; do
    t=$(now_ms)
    if batch_sql "$rate" "$views" | on "$side" -f - >/dev/null 2>"$run/writer.err"; then
      printf '%s\t%s\t%s\tok\n' "$(utc "$t")" "$t" "$side"
    else
      printf '%s\t%s\t%s\tfail\t%s\n' "$(utc "$t")" "$t" "$side" "$(head -n 1 "$run/writer.err")"
    fi
    took=$(($(now_ms) - t))
    [ "$took" -ge 1000 ] || sleep "$(secs $((1000 - took)))"
  done
}

writer_pid() {
  local pid
  pid=$(cat "$run/writer.pid" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

start_writer() {
  local side=$1 rate=$2
  setsid nohup bash "$0" write "$side" "$rate" >>"$run/writer.log" 2>&1 </dev/null &
  echo $! >"$run/writer.pid"
  printf '%s %s\n' "$side" "$rate" >"$run/writer.conf"
}

# The writer leads its own process group (setsid): killing the group also stops a psql in the middle of a batch, so
# nothing reaches the source after the stop.
stop_writer() {
  local pid n
  pid=$(writer_pid) || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for ((n = 0; n < 100; n++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$pid" 2>/dev/null || fail "writer $pid still running after 10 s"
  rm -f "$run/writer.pid"
}

cmd_start() {
  local rate=${1:-40} pid
  [[ $rate =~ ^[1-9][0-9]*$ ]] || fail "rate must be a positive number of statements per second"
  [ -s "$run/views" ] || fail "run setup first"
  if pid=$(writer_pid); then
    echo "writer already running, pid $pid, $(cat "$run/writer.conf")"
    return 0
  fi
  start_writer source "$rate"
  echo "writer started on the source, $rate statements per second, pid $(cat "$run/writer.pid"), log $run/writer.log"
}

cmd_stop() {
  stop_writer
  echo "writer stopped; ok and failed batches in $run/writer.log: $(grep -c $'\tok' "$run/writer.log" || true)," \
    "$(grep -c $'\tfail' "$run/writer.log" || true)"
}

# fence_seen ID LIMIT_MS: polls the target until the heartbeat row ID is there; prints the epoch ms it was seen at, or
# nothing when the deadline passes first.
fence_seen() {
  local id=$1 deadline=$2
  while :; do
    if [ "$(tgt -c "SELECT count(*) FROM heartbeat WHERE id = '$id'")" = 1 ]; then
      now_ms
      return 0
    fi
    [ "$(now_ms)" -lt "$deadline" ] || return 0
    sleep "$poll"
  done
}

heartbeat() {
  local id
  id=$(src -c "INSERT INTO heartbeat (kind) VALUES ('$1') RETURNING id")
  [[ $id =~ ^[0-9a-f-]{36}$ ]] || fail "no heartbeat id from the source: $id"
  printf '%s' "$id"
}

# CDC lag: a row written at the source, seen at the target; the time between, on this clock.
cmd_lag() {
  local samples=${1:-30} n id t seen lat missed=0 sorted sum=0
  local -a lats=()
  [[ $samples =~ ^[1-9][0-9]*$ ]] || fail "samples must be a positive number"
  target_login
  for ((n = 1; n <= samples; n++)); do
    id=$(heartbeat lag)
    t=$(now_ms)
    seen=$(fence_seen "$id" $((t + sample_limit * 1000)))
    if [ -n "$seen" ]; then
      lat=$((seen - t))
      lats+=("$lat")
      sum=$((sum + lat))
      echo "lag $n: $lat ms (written $(utc "$t"), seen on the target $(utc "$seen"))"
    else
      missed=$((missed + 1))
      echo "lag $n: not seen on the target after $sample_limit s (written $(utc "$t"))"
    fi
    [ "$n" = "$samples" ] || sleep 1
  done
  if [ "${#lats[@]}" -gt 0 ]; then
    sorted=$(printf '%s\n' "${lats[@]}" | sort -n)
    echo "CDC lag over ${#lats[@]} samples: min $(head -n 1 <<<"$sorted") ms," \
      "median $(sed -n "$((${#lats[@]} / 2 + 1))p" <<<"$sorted") ms, max $(tail -n 1 <<<"$sorted") ms," \
      "mean $((sum / ${#lats[@]})) ms"
  fi
  [ "$missed" = 0 ] || fail "$missed of $samples samples never reached the target"
}

# Row count and an order-free checksum per table: the sum of the first 60 bits of each row's md5.
checksum_sql() {
  local cols
  case $1 in
    view_counts) cols="video_id, view_count, updated_at" ;;
    likes) cols="video_id, user_id, created_at" ;;
    heartbeat) cols="id, kind, written_at" ;;
  esac
  echo "SELECT count(*) || ' ' || coalesce(sum(('x' || left(md5(concat_ws('|', $cols)), 15))::bit(60)::bigint), 0)" \
    "FROM $1"
}

compare_tables() {
  local t s d bad=0
  for t in "${tables[@]}"; do
    s=$(src -c "$(checksum_sql "$t")")
    d=$(tgt -c "$(checksum_sql "$t")")
    if [ "$s" = "$d" ]; then
      echo "compare $t: match, ${s%% *} rows, checksum ${s#* }"
    else
      echo "compare $t: MISMATCH, source ${s%% *} rows checksum ${s#* }, target ${d%% *} rows checksum ${d#* }"
      bad=1
    fi
  done
  return "$bad"
}

cmd_compare() {
  target_login
  compare_tables
}

# validated ARN: 0 when every table is Validated with nothing pending, failed or suspended; 2 on a mismatch or a
# failed record, which waiting will not fix; 1 otherwise.
validated() {
  local out state pending failed suspended t ok=0
  out=$(aws dms describe-table-statistics --replication-task-arn "$1" --output text --region "$SVP_DMS_REGION" \
    --query 'TableStatistics[].[TableName,ValidationState,ValidationPendingRecords,ValidationFailedRecords,ValidationSuspendedRecords]') ||
    return 1
  for t in "${tables[@]}"; do
    IFS=$'\t' read -r _ state pending failed suspended < <(awk -F'\t' -v t="$t" '$1 == t' <<<"$out") || return 1
    [ "$state" != "Mismatched records" ] && [ "$failed" = 0 ] || return 2
    [ "$state" = Validated ] && [ "$pending" = 0 ] && [ "$suspended" = 0 ] || ok=1
  done
  return "$ok"
}

# rollback T0 RATE REASON: the cutover stops short; the application writes to the source again.
rollback() {
  start_writer source "$2"
  echo "cutover aborted: $3; writes resumed at the source $(secs $(($(now_ms) - $1))) s after T0"
  exit 1
}

# Cutover: stop the writes, wait for the lag to drain (a fence row reaches the target) and for the validation, compare
# both sides, stop the task, then switch the writer to the target. The downtime runs from the stop to the first write.
cmd_cutover() {
  local arn=$1 limit=${2:-900} side rate t0 deadline id seen rc t1
  [[ $arn =~ ^arn:aws[a-z-]*:dms:[a-z0-9-]+:[0-9]{12}:task:[A-Za-z0-9]+$ ]] || fail "cutover needs the task ARN"
  writer_pid >/dev/null || fail "no writer running: start the load on the source first"
  read -r side rate <"$run/writer.conf"
  [ "$side" = source ] || fail "the writer already writes to the $side"
  target_login

  t0=$(now_ms)
  deadline=$((t0 + limit * 1000))
  stop_writer
  echo "T0 $(utc "$t0") ($t0): writes stopped at the source"

  id=$(heartbeat fence)
  seen=$(fence_seen "$id" "$deadline")
  [ -n "$seen" ] || rollback "$t0" "$rate" "lag not drained: fence $id not on the target after $limit s"
  echo "lag drained: fence on the target $(secs $((seen - t0))) s after T0"

  while :; do
    rc=0
    validated "$arn" || rc=$?
    [ "$rc" != 2 ] || rollback "$t0" "$rate" "validation reports mismatched or failed records"
    [ "$rc" != 0 ] || break
    [ "$(now_ms)" -lt "$deadline" ] || rollback "$t0" "$rate" "validation not complete after $limit s"
    sleep 5
  done
  echo "validation: every table Validated, nothing pending, failed or suspended, $(secs $(($(now_ms) - t0))) s after T0"

  compare_tables || rollback "$t0" "$rate" "row counts or checksums differ"
  aws dms stop-replication-task --replication-task-arn "$arn" --region "$SVP_DMS_REGION" \
    --query ReplicationTask.Status --output text >/dev/null || rollback "$t0" "$rate" "cannot stop the task"
  echo "task stopping: the target no longer takes changes from the source"

  until batch_sql "$rate" "$(cat "$run/views")" | tgt -f - >/dev/null; do
    [ "$(now_ms)" -lt "$deadline" ] || fail "no write reached the target after $limit s; the task is stopped"
    sleep 1
  done
  t1=$(now_ms)
  start_writer target "$rate"
  echo "T1 $(utc "$t1") ($t1): first write on the target; writer now on the target, pid $(cat "$run/writer.pid")"
  echo "Downtime cutover: $(secs $((t1 - t0))) s"
}

cmd_slots() {
  src -F ' ' -c "SELECT slot_name, plugin, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
    FROM pg_replication_slots"
}

# Run before the destroy: a slot left behind keeps the WAL from the point it stopped.
cmd_drop_slots() {
  local active
  active=$(src -c "SELECT count(*) FROM pg_replication_slots WHERE active")
  [ "$active" = 0 ] || fail "$active slot(s) still active: stop the task first"
  src -c "SELECT 'dropped ' || slot_name FROM (SELECT slot_name, pg_drop_replication_slot(slot_name) FROM pg_replication_slots) s"
  echo "slots left: $(src -c "SELECT count(*) FROM pg_replication_slots")"
}

mkdir -p "$run"
tgt_host='' tgt_port='' tgt_user=''
case ${1:-} in
  init) cmd_init ;;
  password) cmd_password ;;
  setup) cmd_setup "${2:-}" "${3:-}" ;;
  start) cmd_start "${2:-}" ;;
  write) cmd_write "${2:?}" "${3:?}" ;;
  stop) cmd_stop ;;
  lag) cmd_lag "${2:-}" ;;
  compare) cmd_compare ;;
  cutover) cmd_cutover "${2:-}" "${3:-}" ;;
  slots) cmd_slots ;;
  drop-slots) cmd_drop_slots ;;
  *) fail "usage: pgload.sh init | password | setup [VIEWS] [LIKES] | start [RATE] | stop | lag [SAMPLES] | compare |" \
    "cutover TASK_ARN [LIMIT_S] | slots | drop-slots" ;;
esac
