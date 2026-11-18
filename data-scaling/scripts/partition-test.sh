#!/usr/bin/env bash
# Self-test of partition.sh with fake docker, aws and sleep first on PATH: no container, no network, no account. Covers
# the run's table and p95 by nearest rank, the docker run (no network, no port, pinned image, memory bound), removal
# on success and failure, a name already taken, bad arguments, the 30-day mark past the gap and unequal cleanups.
# Usage: bash scripts/partition-test.sh
# shellcheck disable=SC2016 # bash -c '...' and the fakes expand their own arguments, not this shell
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin state=$work/state
mkdir -p "$bin" "$state" "$work/tmp"
log=$work/calls.log
failures=0
container=svp-lab-ds-partition
image=docker.io/library/postgres:17.11-trixie@sha256:ff87138949ad9a46f32ff23bd6852b52ce024a13dffe9b4087be98292cdd3b4f

# The machine's shell sets this for other projects; the script must drop it on every docker call.
export DOCKER_DEFAULT_PLATFORM=linux/amd64
export FAKE_LOG=$log FAKE_DIR=$state TMPDIR=$work/tmp

# The fake docker logs each call with the platform variable it saw. exists.container and exists.volume stand for the
# objects; psql answers $FAKE_DIR/out.<file of -f> or a query of -c; cat of a pgbench log answers $FAKE_DIR/log.<kind>.
# A call whose arguments contain the text of $FAKE_DIR/fail exits 3.
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $* | platform=${DOCKER_DEFAULT_PLATFORM-unset}" >>"$FAKE_LOG"
if [ -s "$FAKE_DIR/fail" ] && [[ " $* " == *"$(cat "$FAKE_DIR/fail")"* ]]; then
  echo "fake docker: failing as asked" >&2
  exit 3
fi
[ ! -e "$FAKE_DIR/no_daemon" ] || [ "$1" != info ] || exit 1
case "$1 ${2:-}" in
  "info "*) exit 0 ;;
  "container inspect" | "volume inspect") [ -e "$FAKE_DIR/exists.${1}" ] ;;
  "volume rm") rm -f "$FAKE_DIR/exists.volume" ;;
  "rm "*) rm -f "$FAKE_DIR/exists.container" ;;
  "run "*) touch "$FAKE_DIR/exists.container" "$FAKE_DIR/exists.volume"; echo 0123456789ab ;;
  "inspect "*) echo true ;;
  "logs "*) echo 'PostgreSQL init process complete; ready for start up.' ;;
  "exec "*)
    args=" $* "
    case $args in
      *" pg_isready "* | *" mkdir "* | *" pgbench "*) exit 0 ;;
      *" sh -c cat /tmp/svp-lab/"*-read.*) cat "$FAKE_DIR/log.read" ;;
      *" sh -c cat /tmp/svp-lab/"*-write.*) cat "$FAKE_DIR/log.write" ;;
      *" -f /lab/"*)
        file=${args##* -f /lab/}
        file=${file%%.sql*}
        [ ! -e "$FAKE_DIR/out.$file" ] || cat "$FAKE_DIR/out.$file" ;;
      *"SHOW server_version"*) echo '17.11 (fake)' ;;
      *"now() - interval '30 days' <"*) cat "$FAKE_DIR/in_time" ;;
      *) echo "fake docker: unexpected exec $*" >&2; exit 98 ;;
    esac ;;
  *) echo "fake docker: unexpected call $*" >&2; exit 98 ;;
esac
EOF
# The script runs nothing on AWS: any aws call is logged and fails.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
exit 99
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/sleep"
chmod +x "$bin/docker" "$bin/aws" "$bin/sleep"
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
run() {
  rc=0
  : >"$log"
  bash "$src/partition.sh" "$@" >"$work/out" 2>"$work/err" || rc=$?
}
reset() {
  rm -f "$state"/*
  echo t >"$state/in_time"
  echo 'load|200|20|5|20|1000|618|30900|1000|4792320|6455296|33|20068019|2026-10-18 21:20:10+00' >"$state/out.load"
  echo 'delete|1000|1|10|11|143360|136192|1000|5242880|5242880' >"$state/out.prune-delete"
  echo 'detach|1000|1|1|4|119808|117760|0|7340032|6291456' >"$state/out.prune-detach"
  # Latencies 1 to 20 ms and one failed transaction: rank ceil(0.95 * 20) = 19 is 19 ms, the max 20 ms.
  for i in $(seq 20); do echo "0 $i $((i * 1000)) 0 1763400000 0 5"; done >"$state/log.read"
  echo "0 21 failed 0 1763400000 0 5" >>"$state/log.read"
  printf '0 1 30000 0 1763400000 0 5\n0 2 40000 0 1763400000 0 5\n' >"$state/log.write"
  cat >"$state/out.explain" <<'PLAN'
Limit  (actual time=0.029..0.044 rows=11 loops=1)
  Buffers: shared hit=48
  ->  Append  (actual time=0.013..0.018 rows=11 loops=1)
        Subplans Removed: 1
        ->  Index Only Scan Backward using timeline_p20261118_pkey on timeline_p20261118 t_3  (actual rows=0 loops=1)
              Index Cond: (user_id = 'c4ca4238-a0b9-2382-0dcc-509a6f75849b'::uuid)
        ->  Index Only Scan Backward using timeline_p20261117_pkey on timeline_p20261117 t_2  (actual rows=11 loops=1)
        ->  Index Only Scan Backward using timeline_p20261116_pkey on timeline_p20261116 t_1  (never executed)
Planning Time: 0.999 ms
Execution Time: 0.163 ms
----
Limit  (actual time=0.2..0.3 rows=11 loops=1)
  Buffers: shared hit=79
  ->  Append  (actual time=0.2..0.25 rows=11 loops=1)
        Subplans Removed: 1
        ->  Index Only Scan Backward using timeline_p20261118_pkey on timeline_p20261118 t_3  (actual rows=0 loops=1)
        ->  Index Only Scan Backward using timeline_p20261117_pkey on timeline_p20261117 t_2  (actual rows=0 loops=1)
        ->  Index Only Scan Backward using timeline_p20261116_pkey on timeline_p20261116 t_1  (actual rows=11 loops=1)
Planning Time: 0.838 ms
Execution Time: 0.223 ms
PLAN
}
# removed: the trap removed the container and its volume, and the temporary directory is gone.
removed() {
  grep -q "^docker rm -f -v $container " "$log" && grep -q "^docker volume rm $container " "$log" &&
    [ ! -e "$state/exists.container" ] && [ ! -e "$state/exists.volume" ] && [ -z "$(ls -A "$work/tmp")" ]
}

# --- a whole run ------------------------------------------------------------------------------------------------------
reset
run 200 5 20
expect "a run ends 0" [ "$rc" = 0 ]
expect "every docker call runs without DOCKER_DEFAULT_PLATFORM" bash -c '! grep -v "platform=unset$" "$1"' _ "$log"
expect "no aws call" bash -c '! grep -q "^aws " "$1"' _ "$log"
expect "the container has no network and no published port, a bounded memory and the pinned image" \
  bash -c 'l=$(grep "^docker run " "$1"); [[ $l == *" --network none "* && $l == *" --memory 2g "* &&
    $l == *" $2 "* && $l == *" -v $3:/var/lib/postgresql/data "* && $l == *":/lab:ro "* ]] &&
    ! grep -qE "^docker run .*( -p | --publish| -P )" "$1"' _ "$log" "$image" "$container"
expect "the name is checked before the container starts" bash -c 'grep -n "" "$1" |
  awk -F: "/docker container inspect/ && !c {c=\$1} /docker run / {r=\$1} END {exit !(c && r && c < r)}"' _ "$log"
expect "every SQL file the script names exists" bash -c 'for f in $(grep -oE "/lab/[a-z-]+\.sql" "$1" | sort -u); do
  [ -f "$2/../partition/${f#/lab/}" ] || { echo "missing $f" >&2; exit 1; }; done' _ "$log" "$src"
expect "the four measures read and write with prepared statements at fixed rates" bash -c '
  [ "$(grep -c "pgbench -n -M prepared .* -R 200 -T 60 .* -f /lab/read.sql --log" "$1")" = 4 ] &&
  [ "$(grep -c "pgbench -n -M prepared .* -R 1 -T 60 .* -f /lab/write.sql --log" "$1")" = 4 ]' _ "$log"
expect "DELETE runs on the plain table, DETACH on the partitioned one" bash -c '
  grep -q "PGOPTIONS=-c search_path=plain,public .* -f /lab/prune-delete.sql" "$1" &&
  grep -q "PGOPTIONS=-c search_path=part,public .* -f /lab/prune-detach.sql" "$1"' _ "$log"
expect "p95 by nearest rank, max, count and failed of each measure" bash -c '
  row="^(plain|partitioned)[+A-Z]* +[0-9T:-]+Z +19\.000 +20\.000 +20 +1 +40\.000 +40\.000 +2 +0$"
  [ "$(grep -cE "$row" "$1")" = 4 ]' \
  _ "$work/out"
expect "the cleanup rows" bash -c '
  grep -qE "^DELETE in batches +1000 +1 +10 +11 +140 KiB +133 KiB +1000 +5 MiB, 5 MiB$" "$1" &&
  grep -qE "^DETACH \+ DROP +1000 +1 +1 +4 +117 KiB +115 KiB +0 +7 MiB, 6 MiB$" "$1"' _ "$work/out"
expect "the plan rows" bash -c 'grep -qE "^partitioned, first page +3 +1 +1 +0\.999 +0\.163  shared hit=48$" "$1" &&
  grep -qE "^partitioned, 15 days back +3 +1 +0 +0\.838 +0\.223  shared hit=79$" "$1"' _ "$work/out"
expect "the printed plan keeps nodes only" bash -c 'grep -q "^    ->  Append" "$1" && ! grep -q "Index Cond" "$1"' \
  _ "$work/out"
expect "the data line" grep -q '^data: 200 users, 20 authors, 5 follows each (1000 rows), 20 videos a day' "$work/out"
expect "a run removes the container, its volume and its temporary directory" removed

# --- the name is taken ------------------------------------------------------------------------------------------------
for kind in container volume; do
  reset
  touch "$state/exists.$kind"
  run
  expect "a $kind named $container: refused" \
    bash -c '[ "$1" != 0 ] && grep -q "named svp-lab-ds-partition exists" "$2"' \
    _ "$rc" "$work/err"
  expect "and nothing is started or removed" bash -c '! grep -qE "^docker (run|rm|volume rm) " "$1"' _ "$log"
  expect "and the $kind is still there" [ -e "$state/exists.$kind" ]
done

# --- failures after the start -----------------------------------------------------------------------------------------
reset
echo /lab/load.sql >"$state/fail"
run
expect "a failed load ends non-zero" [ "$rc" != 0 ]
expect "and still removes everything" removed

reset
echo f >"$state/in_time"
run
expect "the 30-day mark past the gap: fails before a cleanup" bash -c '[ "$1" != 0 ] &&
  grep -q "would not remove the same rows" "$2" && ! grep -q "/lab/prune-" "$3"' _ "$rc" "$work/err" "$log"
expect "and removes everything" removed

reset
echo 'detach|999|1|1|4|119808|117760|0|7340032|6291456' >"$state/out.prune-detach"
run
expect "cleanups that removed different rows: fail" bash -c '[ "$1" != 0 ] &&
  grep -q "removed different rows: DELETE 1000, DETACH 999" "$2"' _ "$rc" "$work/err"
expect "and remove everything" removed

reset
: >"$state/log.read"
run
expect "a pgbench log without a latency fails" bash -c '[ "$1" != 0 ] && grep -q "no transaction with a latency" "$2"' \
  _ "$rc" "$work/err"
expect "and removes everything" removed

# --- arguments and Docker ---------------------------------------------------------------------------------------------
for args in "0" "abc" "200 21" "200 5 -1"; do
  reset
  read -ra argv <<<"$args"
  run "${argv[@]}"
  expect "arguments '$args': refused without a container" bash -c '[ "$1" != 0 ] && ! grep -q "^docker run " "$2"' \
    _ "$rc" "$log"
done
reset
touch "$state/no_daemon"
run
expect "Docker not running: refused without a container" bash -c '
  [ "$1" != 0 ] && grep -q "Docker is not running" "$2" &&
  ! grep -q "^docker run " "$3"' _ "$rc" "$work/err" "$log"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
