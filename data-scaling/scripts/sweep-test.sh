#!/usr/bin/env bash
# Self-test of sweep.sh with a fake aws first on PATH: no network, no account. Covers a clean account, a leftover, a
# list that cannot be read (an expired session), a missing account variable and a wrong account; the fake refuses any
# verb that is not a read.
# Usage: bash scripts/sweep-test.sh
# shellcheck disable=SC2016 # bash -c '...' expands its own arguments, not this shell
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin=$work/bin answers=$work/answers
mkdir -p "$bin" "$answers"
log=$work/calls.log
failures=0

unset SVP_AWS_STG_ACCOUNT_ID AWS_PAGER AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export FAKE_LOG=$log FAKE_DIR=$work

# The fake aws answers $answers/<service>_<command>, else lists nothing; an answer that reads FAIL exits 255 as the CLI
# does when the session has expired. It refuses, with 97, another profile or Region and any verb that writes.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ "$1 $2 $3 $4" = "--profile anhnv-stg --region ap-southeast-1" ] ||
  { echo "fake aws: not --profile anhnv-stg --region ap-southeast-1 first" >&2; exit 97; }
case "$5 $6" in
  "sts get-caller-identity") ;;
  sts\ *) echo "fake aws: sts $6 is not a read of the sweep" >&2; exit 97 ;;
  *\ describe-* | *\ list-* | *\ get-*) ;;
  *) echo "fake aws: $5 $6 is not a read" >&2; exit 97 ;;
esac
file=$FAKE_DIR/answers/$5_$6
[ -e "$file" ] || exit 0
[ "$(cat "$file")" != FAIL ] || { echo "Error when retrieving token from sso: Token has expired" >&2; exit 255; }
cat "$file"
EOF
chmod +x "$bin/aws"
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
sweep() {
  rc=0
  : >"$log"
  SVP_AWS_STG_ACCOUNT_ID=${account-000000000000} bash "$src/sweep.sh" >"$work/out" 2>"$work/err" || rc=$?
}
reset() {
  rm -f "$answers"/*
  echo 000000000000 >"$answers/sts_get-caller-identity"
  echo None >"$answers/rds_describe-db-snapshots"
}

# --- the fake itself --------------------------------------------------------------------------------------------------
for verb in "rds delete-db-instance" "ec2 terminate-instances" "elasticache modify-replication-group" \
  "secretsmanager delete-secret" "sts assume-role"; do
  read -r service command <<<"$verb"
  expect "the fake aws refuses $verb" \
    bash -c '! aws --profile anhnv-stg --region ap-southeast-1 "$1" "$2" 2>/dev/null' \
    _ "$service" "$command"
done
expect "the fake aws refuses another Region" \
  bash -c '! aws --profile anhnv-stg --region us-east-1 rds describe-db-instances 2>/dev/null'

# --- a clean account --------------------------------------------------------------------------------------------------
reset
sweep
expect "a clean account ends 0" [ "$rc" = 0 ]
expect "and says nothing is left" grep -qx 'sweep: nothing left' "$work/out"
expect "every list reads none, None included" bash -c '! grep -Ev "^none  " "$1" | grep -v "^sweep: "' _ "$work/out"
expect "a kind with nothing left reads none" grep -qx 'none  DB snapshots' "$work/out"
expect "the fake aws refused no call: only reads, one profile, one Region" [ ! -s "$work/err" ]
expect "the account is checked before any list" bash -c 'head -n 1 "$1" | grep -q " sts get-caller-identity "' _ "$log"
expect "every kind of the lab is listed" bash -c 'for k in "Lab=data-scaling" "DB clusters" "DB instances" \
  "DB proxies" "DB cluster snapshots" "DB snapshots" "DB cluster automated backups" "DB instance automated backups" \
  "ElastiCache replication groups" "ElastiCache cache clusters" "ElastiCache snapshots" "ElastiCache users" \
  "ElastiCache user groups" "instances not terminated" "network interfaces" "Elastic IP addresses" "secrets" \
  "log groups" "IAM roles"; do grep -q "^none  .*$k" "$1" || { echo "missing: $k" >&2; exit 1; }; done' _ "$work/out"
expect "secrets scheduled for deletion are listed too" \
  grep -q 'secretsmanager list-secrets --include-planned-deletion' "$log"
expect "log groups match the prefix anywhere in the name" \
  grep -q 'logs describe-log-groups --log-group-name-pattern svp-lab-ds-' "$log"

# --- a leftover -------------------------------------------------------------------------------------------------------
reset
printf 'svp-lab-ds-aurora\n' >"$answers/rds_describe-db-clusters"
printf '/aws/rds/proxy/svp-lab-ds-proxy\n' >"$answers/logs_describe-log-groups"
sweep
expect "a leftover ends 1" [ "$rc" = 1 ]
expect "and is listed under its title" bash -c 'grep -A 1 "^LEFT  DB clusters$" "$1" | grep -qx svp-lab-ds-aurora' \
  _ "$work/out"
expect "the log group of RDS Proxy is a leftover" bash -c 'grep -A 1 "^LEFT  log groups" "$1" |
  grep -qx /aws/rds/proxy/svp-lab-ds-proxy' _ "$work/out"
expect "and nothing is said to be clean" bash -c '! grep -q "nothing left" "$1"' _ "$work/out"

# --- a list that cannot be read ---------------------------------------------------------------------------------------
reset
echo FAIL >"$answers/rds_describe-db-cluster-automated-backups"
sweep
expect "a failed list ends non-zero" [ "$rc" != 0 ]
expect "and is marked ERROR, not none" bash -c 'grep -q "^ERROR DB cluster automated backups" "$1" &&
  ! grep -q "^none  DB cluster automated backups" "$1"' _ "$work/out"
expect "and nothing is said to be clean" bash -c '! grep -q "nothing left" "$1"' _ "$work/out"
expect "the error says why" grep -q 'lists marked ERROR were not read' "$work/err"
expect "the other lists still run" grep -q '^none  IAM roles$' "$work/out"

# --- an expired session, a missing or wrong account -------------------------------------------------------------------
reset
echo FAIL >"$answers/sts_get-caller-identity"
sweep
expect "an expired session fails before any list" \
  bash -c '[ "$1" != 0 ] && [ ! -s "$2" ] && [ "$(wc -l <"$3")" -eq 1 ]' \
  _ "$rc" "$work/out" "$log"
reset
account='' sweep
expect "no account variable: fails without an aws call" bash -c '[ "$1" != 0 ] && [ ! -s "$2" ]' _ "$rc" "$log"
echo 444444444444 >"$answers/sts_get-caller-identity"
sweep
expect "another account: fails before any list" bash -c '[ "$1" != 0 ] && grep -q "signs in to 444444444444" "$2" &&
  [ "$(wc -l <"$3")" -eq 1 ] && ! grep -q "nothing left" "$4"' _ "$rc" "$work/err" "$log" "$work/out"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
