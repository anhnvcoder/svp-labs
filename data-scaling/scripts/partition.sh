#!/usr/bin/env bash
# The feed-service timeline as one table and partitioned by day on published_at, side by side on this machine: p95
# and max of the feed read beside a fan-out write load, the 30-day cleanup (batched DELETE against DETACH PARTITION
# CONCURRENTLY + DROP: time, WAL, dead rows, size) and partition pruning. Reads the SQL of data-scaling/partition/;
# writes a Postgres 17 container, its volume and a temporary directory, all removed on exit, and prints a table.

# Runs on this machine with Docker; no AWS, no network in the container. Laptop numbers compare the two tables, they
# do not predict RDS. Design notes: data-scaling/README.md.
# Usage: partition.sh [USERS [FOLLOWS [VIDEOS_PER_DAY]]]   (defaults 20000 50 300; FOLLOWS at most USERS / 10)
set -euo pipefail

name=svp-lab-ds-partition
image=docker.io/library/postgres:17.11-trixie@sha256:ff87138949ad9a46f32ff23bd6852b52ce024a13dffe9b4087be98292cdd3b4f
db=svp_lab
# A share of a 16 GB machine: the default data, two copies of the timeline, stays under 3 GB with its WAL.
memory=2g
cpus=4
# Every measure reads for the same window at the same rates, below what the container saturates at, so latency
# shows the query and not a queue; a cleanup starts cleanup_after seconds into the window.
window=60
read_rate=200
read_clients=8
write_rate=1
cleanup_after=10

src=$(cd "$(dirname "$0")/../partition" && pwd)

fail() {
  echo "partition: $*" >&2
  exit 1
}

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
posint() { [[ $2 =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive whole number, not '$2'"; }
# us MICROSECONDS: as milliseconds with three decimals.
us() { printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"; }
# kib, mib BYTES: rounded; empty (no statement counted) prints as -.
kib() { awk -v b="$1" 'BEGIN { if (b == "") print "-"; else printf "%.0f KiB", b / 1024 }'; }
mib() { awk -v b="$1" 'BEGIN { if (b == "") print "-"; else printf "%.0f MiB", b / 1048576 }'; }

# The dev machine's shell sets DOCKER_DEFAULT_PLATFORM to linux/amd64 for other projects: unset, the image runs
# natively instead of emulated.
docker() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

# psql_on SCHEMA ARGS...: psql in the container as the superuser, with the search_path that picks SCHEMA's timeline.
psql_on() {
  local schema=$1
  shift
  docker exec -e "PGOPTIONS=-c search_path=$schema,public" "$name" \
    psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d "$db" "$@"
}

# line TAG OUTPUT: the result line TAG|... of a SQL file's output.
line() {
  local l
  l=$(grep "^$1|" <<<"$2") || fail "no $1 line in the output of psql: $2"
  echo "$l"
}

cleanup() {
  local rc=$? pids
  mapfile -t pids < <(jobs -p)
  [ "${#pids[@]}" = 0 ] || kill "${pids[@]}" 2>/dev/null || true
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  docker volume rm "$name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  if docker container inspect "$name" >/dev/null 2>&1 || docker volume inspect "$name" >/dev/null 2>&1; then
    echo "partition: $name is left; remove it: docker rm -f -v $name; docker volume rm $name" >&2
    rc=1
  fi
  exit "$rc"
}

ready() {
  local logs
  for _ in $(seq 120); do
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] ||
      fail "the container stopped: $(docker logs --tail 20 "$name" 2>&1)"
    # The image's entrypoint answers on the socket during its init too, before it restarts the server for good.
    logs=$(docker logs "$name" 2>&1)
    if [[ $logs == *'PostgreSQL init process complete'* ]] && docker exec "$name" pg_isready -q -U postgres -d "$db"
    then
      return 0
    fi
    sleep 1
  done
  fail "Postgres is not ready after 120 s"
}

# bench KIND LABEL SCHEMA: pgbench running KIND.sql (read or write) for the window on SCHEMA's timeline, as the app
# role (pg_stat_statements then tells its WAL from a cleanup's), its per-transaction log in the container.
bench() {
  local rate=$read_rate clients=$read_clients jobs=2
  [ "$1" = read ] || { rate=$write_rate clients=1 jobs=1; }
  docker exec -e "PGOPTIONS=-c search_path=$3,public" "$name" pgbench -n -M prepared -U svp_app -d "$db" \
    -c "$clients" -j "$jobs" -R "$rate" -T "$window" -D "users=$users" -D "authors=$authors" -f "/lab/$1.sql" \
    --log --log-prefix="/tmp/svp-lab/$2-$1" >"$tmp/$2-$1.out" 2>&1
}

# stats FILE: p95 by nearest rank (the value of rank ceil(0.95 n) among the n sorted latencies) and max in ms of a
# pgbench log, its transaction count and the failed or skipped ones. Under -R a latency counts from the scheduled
# start, so a transaction that waited for a busy client counts its wait too.
stats() {
  local sorted n rank other
  sorted=$(awk '$3 ~ /^[0-9]+$/ {print $3}' "$1" | sort -n)
  other=$(awk '$3 !~ /^[0-9]+$/' "$1" | wc -l | tr -d ' ')
  n=$(grep -c . <<<"$sorted" || true)
  [ "$n" -gt 0 ] || fail "no transaction with a latency in $(basename "$1")"
  rank=$(((95 * n + 99) / 100))
  echo "$(us "$(sed -n "${rank}p" <<<"$sorted")") $(us "$(tail -n 1 <<<"$sorted")") $n $other"
}

# measure LABEL SCHEMA [CLEANUP]: the read and the write load side by side for the window on SCHEMA's timeline;
# CLEANUP (delete or detach: prune-CLEANUP.sql) starts cleanup_after seconds in, its result line in cleanup_line.
measure() {
  local label=$1 schema=$2 start rpid wpid rc=0 in_time
  if [ $# -gt 2 ]; then
    in_time=$(psql_on public -c "SELECT now() - interval '30 days' < '$gap_end'::timestamptz")
    [ "$in_time" = t ] || fail "the 30-day mark passed the end of the gap in the data ($gap_end):" \
      "DELETE and DETACH would not remove the same rows; run the script again"
  fi
  echo "$(utc) measuring $label (${window} s)" >&2
  start=$(utc)
  bench read "$label" "$schema" &
  rpid=$!
  bench write "$label" "$schema" &
  wpid=$!
  if [ $# -gt 2 ]; then
    sleep "$cleanup_after"
    cleanup_line=$(psql_on "$schema" -f "/lab/prune-$3.sql")
    cleanup_line=$(line "$3" "$cleanup_line")
  fi
  wait "$rpid" || rc=$?
  wait "$wpid" || rc=$?
  [ "$rc" = 0 ] || fail "pgbench of $label ended with $rc: $(cat "$tmp/$label-read.out" "$tmp/$label-write.out")"
  docker exec "$name" sh -c "cat /tmp/svp-lab/$label-read.*" >"$tmp/$label-read.log"
  docker exec "$name" sh -c "cat /tmp/svp-lab/$label-write.*" >"$tmp/$label-write.log"
  # Assigned first: a failure inside $(...) given to read would be lost.
  reads=$(stats "$tmp/$label-read.log")
  writes=$(stats "$tmp/$label-write.log")
  read -r rp95 rmax rn rother <<<"$reads"
  read -r wp95 wmax wn wother <<<"$writes"
  measures+=("$(printf '%-20s %-21s %11s %11s %6s %6s %12s %12s %6s %6s' "$label" "$start" "$rp95" "$rmax" "$rn" \
    "$rother" "$wp95" "$wmax" "$wn" "$wother")")
}

# plan_row LABEL PLAN: partitions in the plan, removed by startup pruning, never executed; planning and execution
# time and the top node's buffers of an EXPLAIN (ANALYZE, BUFFERS).
plan_row() {
  local planned removed never planning execution buffers
  planned=$(grep -cE ' on timeline_p[0-9]{8} ' <<<"$2" || true)
  removed=$({ grep -oE 'Subplans Removed: [0-9]+' <<<"$2" || true; } | awk '{ s += $3 } END { print s + 0 }')
  never=$({ grep -E ' on timeline_p[0-9]{8} ' <<<"$2" || true; } | grep -c 'never executed' || true)
  planning=$({ grep -oE 'Planning Time: [0-9.]+' <<<"$2" || true; } | awk '{ print $3 }')
  execution=$({ grep -oE 'Execution Time: [0-9.]+' <<<"$2" || true; } | awk '{ print $3 }')
  buffers=$({ grep -m 1 'Buffers:' <<<"$2" || true; } | sed 's/^ *Buffers: //')
  printf '%-26s %10s %8s %15s %12s %13s  %s\n' "$1" "$planned" "$removed" "$never" "$planning" "$execution" \
    "$buffers"
}

users=${1:-20000}
follows=${2:-50}
videos_per_day=${3:-300}
posint USERS "$users"
posint FOLLOWS "$follows"
posint VIDEOS_PER_DAY "$videos_per_day"
[ "$follows" -le $((users / 10 > 0 ? users / 10 : 1)) ] || fail "FOLLOWS must be at most USERS / 10, the authors"

docker info >/dev/null 2>&1 || fail "Docker is not running"
# The check comes before the trap: a refused run must not remove the container of the run that holds the name.
if docker container inspect "$name" >/dev/null 2>&1 || docker volume inspect "$name" >/dev/null 2>&1; then
  fail "a container or volume named $name exists: another run is going, or one was cut off;" \
    "remove it: docker rm -f -v $name; docker volume rm $name"
fi
tmp=$(mktemp -d)
trap cleanup EXIT
trap 'exit 143' TERM INT

begin=$(utc)
echo "$begin starting $name" >&2
# No network at all, so no port is published anywhere: psql and pgbench run inside over the socket. Trust is then
# the only way in that is left, and no password is generated, passed or printed.
docker run -d --name "$name" --network none --memory "$memory" --memory-swap "$memory" --cpus "$cpus" \
  --shm-size 256m -v "$name:/var/lib/postgresql/data" -v "$src:/lab:ro" \
  -e POSTGRES_DB="$db" -e POSTGRES_HOST_AUTH_METHOD=trust "$image" \
  -c shared_buffers=512MB -c max_wal_size=1GB -c maintenance_work_mem=256MB -c timezone=UTC \
  -c shared_preload_libraries=pg_stat_statements >/dev/null
ready
docker exec "$name" mkdir -p /tmp/svp-lab
version=$(psql_on public -c 'SHOW server_version')

echo "$(utc) loading" >&2
load_start=$(date +%s)
psql_on public -f /lab/schema.sql >/dev/null
loaded=$(psql_on public -v "users=$users" -v "follows=$follows" -v "videos_per_day=$videos_per_day" -f /lab/load.sql)
loaded=$(line load "$loaded")
IFS='|' read -r _ users authors follows videos_per_day n_follows n_videos rows old plain_bytes part_bytes partitions \
  db_bytes gap_end <<<"$loaded"
load_seconds=$(($(date +%s) - load_start))

measures=()
measure plain plain
measure partitioned part
echo "$(utc) explaining" >&2
plan_plain=$(psql_on plain -f /lab/explain.sql)
plan_part=$(psql_on part -f /lab/explain.sql)
measure plain+DELETE plain delete
delete_line=$cleanup_line
measure partitioned+DETACH part detach
detach_line=$cleanup_line

IFS='|' read -r _ deleted batches longest delete_ms delete_wal delete_own delete_dead delete_size0 delete_size1 \
  <<<"$delete_line"
IFS='|' read -r _ removed detached detach_ms drop_ms detach_wal detach_own detach_dead detach_size0 detach_size1 \
  <<<"$detach_line"

echo "partition: $begin to $(utc), PostgreSQL $version in $image"
echo "container: --memory $memory --cpus $cpus --network none; shared_buffers 512MB, max_wal_size 1GB, timezone UTC"
echo "data: $users users, $authors authors, $follows follows each ($n_follows rows), $videos_per_day videos a day" \
  "($n_videos videos); timeline $rows rows, $old of them in the day before the 30-day mark's day"
echo "size: plain $(mib "$plain_bytes"), partitioned $(mib "$part_bytes") in $partitions daily partitions," \
  "database $(mib "$db_bytes"); loaded in $load_seconds s"
echo "load: reads $read_rate/s by $read_clients clients, fan-out writes $write_rate video/s ($((rows / n_videos))" \
  "rows each on average), ${window} s each; a cleanup starts ${cleanup_after} s in"
echo
printf '%-20s %-21s %11s %11s %6s %6s %12s %12s %6s %6s\n' measure 'start (UTC)' 'read p95 ms' 'read max ms' reads \
  failed 'write p95 ms' 'write max ms' writes failed
printf '%s\n' "${measures[@]}"
echo
printf '%-20s %8s %7s %16s %9s %10s %10s %10s %21s\n' cleanup rows steps 'longest step ms' 'total ms' 'WAL (LSN)' \
  'WAL (own)' 'dead rows' 'size before, after'
printf '%-20s %8s %7s %16s %9s %10s %10s %10s %21s\n' 'DELETE in batches' "$deleted" "$batches" "$longest" \
  "$delete_ms" "$(kib "$delete_wal")" "$(kib "$delete_own")" "$delete_dead" \
  "$(mib "$delete_size0"), $(mib "$delete_size1")"
printf '%-20s %8s %7s %16s %9s %10s %10s %10s %21s\n' 'DETACH + DROP' "$removed" "$detached" "$detach_ms" \
  "$drop_ms" "$(kib "$detach_wal")" "$(kib "$detach_own")" "$detach_dead" \
  "$(mib "$detach_size0"), $(mib "$detach_size1")"
echo "  (DETACH: steps are partitions, longest step is the detach alone; WAL (LSN) counts every session's," \
  "the write load's too)"
echo
printf '%-26s %10s %8s %15s %12s %13s  %s\n' 'plan (user 1)' 'in plan' removed 'never executed' 'planning ms' \
  'execution ms' 'top node buffers'
plan_row 'plain, first page' "${plan_plain%%----*}"
plan_row 'partitioned, first page' "${plan_part%%----*}"
plan_row 'plain, 15 days back' "${plan_plain#*----}"
plan_row 'partitioned, 15 days back' "${plan_part#*----}"
echo
echo "plan of the partitioned first page (nodes only):"
sed -nE '/^----$/q;/Index Cond:|Heap Fetches:|Buffers:|^Planning:/d;s/^/  /p' <<<"$plan_part"

[ "$deleted" = "$removed" ] && [ "$deleted" = "$old" ] ||
  fail "the cleanups removed different rows: DELETE $deleted, DETACH $removed, loaded before the mark $old"
