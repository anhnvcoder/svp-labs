#!/usr/bin/env bash
# Heartbeat of the multi-region-dr lab: write inserts a row each second through db.<zone>; report reads a host's rows.
# Reads /etc/svp-lab-dr.conf (from the user data) and the password from Secrets Manager of its own Region.
# Runs on: instance

# Each attempt resolves the CNAME, then connects to the RDS host it names with verify-full, since the certificate
# carries that host and not the CNAME; the row carries this machine's clock, and the log gets one line per attempt.
# Usage: heartbeat.sh setup | start primary|dr | write primary|dr [ATTEMPTS] | stop | report HOST
set -euo pipefail
export AWS_PAGER=""

conf=${SVP_DR_CONF:-/etc/svp-lab-dr.conf}
# shellcheck source=/dev/null
. "$conf"
: "${SVP_DR_REGION:?} ${SVP_DR_SECRET_ID:?} ${SVP_DR_NAME:?} ${SVP_DR_DB:?}"
: "${SVP_DR_USER:?} ${SVP_DR_CA:?} ${SVP_DR_RUN:?}"

fail() {
  echo "heartbeat: $*" >&2
  exit 1
}

# utc EPOCH: the time as RFC 3339 in UTC, with BSD or GNU date.
utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# pgpass: a password file only this process can read, removed on exit, instead of PGPASSWORD, which other users may
# see in the environment of the process. The generated password holds letters and digits only, nothing to escape.
pgpass() {
  local pw
  PGPASSFILE=$(umask 077 && mktemp)
  export PGPASSFILE
  trap 'rm -f "$PGPASSFILE"' EXIT
  pw=$(aws secretsmanager get-secret-value --secret-id "$SVP_DR_SECRET_ID" --query SecretString --output text \
    --region "$SVP_DR_REGION") || fail "cannot read secret $SVP_DR_SECRET_ID in $SVP_DR_REGION"
  printf '*:*:*:%s:%s\n' "$SVP_DR_USER" "$pw" >"$PGPASSFILE"
}

# sql HOST STATEMENT: runs STATEMENT on HOST over TLS checked against the RDS bundle; a host that does not answer
# fails after two seconds, the resolution of the RTO.
sql() {
  local conninfo="host=$1 port=5432 dbname=$SVP_DR_DB user=$SVP_DR_USER sslmode=verify-full sslrootcert=$SVP_DR_CA"
  psql -X -q -t -A -v ON_ERROR_STOP=1 "$conninfo connect_timeout=2" -c "$2"
}

# target: the host the CNAME db.<zone> names right now, without the final dot; empty when there is no answer.
target() {
  local t
  t=$(dig +short +time=1 +tries=1 "$SVP_DR_NAME" CNAME 2>/dev/null | head -n 1) || true
  printf '%s' "${t%.}"
}

side_arg() {
  case ${1:-} in
    primary | dr) ;;
    *) fail "side must be primary or dr" ;;
  esac
}

cmd_setup() {
  local host
  pgpass
  host=$(target)
  [ -n "$host" ] || fail "no CNAME for $SVP_DR_NAME"
  sql "$host" "CREATE TABLE IF NOT EXISTS heartbeat (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    side text NOT NULL CHECK (side IN ('primary', 'dr')),
    client_ts timestamptz NOT NULL,
    server_ts timestamptz NOT NULL DEFAULT now())"
  echo "table heartbeat ready on $host"
}

# One line per attempt: UTC time, epoch, host the CNAME named, ok or fail, and the first line of the error.
cmd_write() {
  local side=$1 attempts=${2:-0} n=0 ts host status reason
  side_arg "$side"
  pgpass
  while [ "$attempts" -eq 0 ] || [ "$n" -lt "$attempts" ]; do
    n=$((n + 1))
    ts=$(date -u +%s)
    host=$(target)
    status=fail reason=
    if [ -z "$host" ]; then
      reason="no CNAME for $SVP_DR_NAME"
    elif reason=$(sql "$host" "INSERT INTO heartbeat (side, client_ts) VALUES ('$side', to_timestamp($ts))" 2>&1); then
      status=ok reason=
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(utc "$ts")" "$ts" "${host:--}" "$status" "$(head -n 1 <<<"$reason" | tr '\t' ' ')"
    [ "$(date -u +%s)" -gt "$ts" ] || sleep 1
  done
}

cmd_start() {
  local side=$1
  side_arg "$side"
  mkdir -p "$SVP_DR_RUN"
  if [ -s "$SVP_DR_RUN/$side.pid" ] && kill -0 "$(cat "$SVP_DR_RUN/$side.pid")" 2>/dev/null; then
    echo "writer $side already running, pid $(cat "$SVP_DR_RUN/$side.pid")"
    return 0
  fi
  setsid nohup "$0" write "$side" >>"$SVP_DR_RUN/$side.log" 2>&1 </dev/null &
  echo $! >"$SVP_DR_RUN/$side.pid"
  echo "writer $side started, pid $!, log $SVP_DR_RUN/$side.log"
}

cmd_stop() {
  local f
  for f in "$SVP_DR_RUN"/*.pid; do
    [ -e "$f" ] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
    echo "writer $(basename "$f" .pid) stopped"
  done
}

cmd_report() {
  local host=$1
  [ -n "$host" ] || fail "report needs a host"
  pgpass
  sql "$host" "SELECT 'primary_last=' || coalesce(floor(extract(epoch FROM max(client_ts)))::bigint::text, '')
      FROM heartbeat WHERE side = 'primary'
    UNION ALL
    SELECT 'dr_first=' || coalesce(floor(extract(epoch FROM min(client_ts)))::bigint::text, '')
      FROM heartbeat WHERE side = 'dr'"
}

case ${1:-} in
  setup) cmd_setup ;;
  start) cmd_start "${2:-}" ;;
  write) cmd_write "${2:-}" "${3:-0}" ;;
  stop) cmd_stop ;;
  report) cmd_report "${2:-}" ;;
  *) fail "usage: heartbeat.sh setup | start primary|dr | write primary|dr [ATTEMPTS] | stop | report HOST" ;;
esac
