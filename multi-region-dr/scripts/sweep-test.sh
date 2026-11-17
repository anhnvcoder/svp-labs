#!/usr/bin/env bash
# Self-test of sweep.sh with a fake aws first on PATH: no network, no account. Covers a clean account, a leftover, a
# list that cannot be read (an expired session), a missing account variable and a wrong account.
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

unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export FAKE_LOG=$log FAKE_DIR=$work

# The fake aws answers $answers/<region>_<service>_<command>, else $answers/<service>_<command>, else lists nothing;
# an answer that reads FAIL exits 255 as the CLI does when the session has expired.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ "$1 $2" = "--profile anhnv-stg" ] || { echo "fake aws: not --profile anhnv-stg first" >&2; exit 97; }
[ "$3" = --region ] && case $4 in ap-southeast-1 | us-east-1) true ;; *) false ;; esac ||
  { echo "fake aws: --region $4 is not one of the two Regions" >&2; exit 97; }
file=$FAKE_DIR/answers/$4_$5_$6
[ -e "$file" ] || file=$FAKE_DIR/answers/$5_$6
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

# --- a clean account --------------------------------------------------------------------------------------------------
reset
sweep
expect "a clean account ends 0" [ "$rc" = 0 ]
expect "and says nothing is left" grep -qx 'sweep: nothing left' "$work/out"
expect "every list reads none, None included" bash -c '! grep -Ev "^none  " "$1" | grep -v "^sweep: "' _ "$work/out"
expect "both Regions are swept" bash -c 'grep -q "^none  ap-southeast-1: DB instances$" "$1" &&
  grep -q "^none  us-east-1: DB instances$" "$1"' _ "$work/out"
expect "the fake aws refused no call" [ ! -s "$work/err" ]
expect "the account is checked before any list" bash -c 'head -n 1 "$1" | grep -q " sts get-caller-identity "' _ "$log"

# --- a leftover -------------------------------------------------------------------------------------------------------
reset
printf 'svp-lab-dr-pitr\n' >"$answers/us-east-1_rds_describe-db-instances"
sweep
expect "a leftover ends 1" [ "$rc" = 1 ]
expect "and is listed under its title" bash -c 'grep -A 1 "^LEFT  us-east-1: DB instances$" "$1" | grep -qx svp-lab-dr-pitr' \
  _ "$work/out"
expect "and nothing is said to be clean" bash -c '! grep -q "nothing left" "$1"' _ "$work/out"

# --- a list that cannot be read ---------------------------------------------------------------------------------------
reset
echo FAIL >"$answers/us-east-1_rds_describe-db-instance-automated-backups"
sweep
expect "a failed list ends 1" [ "$rc" = 1 ]
expect "and is marked ERROR, not none" bash -c 'grep -q "^ERROR us-east-1: automated backups" "$1" &&
  ! grep -q "^none  us-east-1: automated backups" "$1"' _ "$work/out"
expect "and nothing is said to be clean" bash -c '! grep -q "nothing left" "$1"' _ "$work/out"
expect "the error says why" grep -q 'lists marked ERROR were not read' "$work/err"
expect "the other lists still run" grep -q '^none  IAM roles$' "$work/out"

# --- an expired session, a missing or wrong account -------------------------------------------------------------------
reset
echo FAIL >"$answers/sts_get-caller-identity"
sweep
expect "an expired session fails before any list" bash -c '[ "$1" = 1 ] && [ ! -s "$2" ] && [ "$(wc -l <"$3")" -eq 1 ]' \
  _ "$rc" "$work/out" "$log"
reset
account='' sweep
expect "no account variable: fails without an aws call" bash -c '[ "$1" = 1 ] && [ ! -s "$2" ]' _ "$rc" "$log"
echo 444444444444 >"$answers/sts_get-caller-identity"
sweep
expect "another account: fails before any list" bash -c '[ "$1" = 1 ] && grep -q "signs in to 444444444444" "$2" &&
  [ "$(wc -l <"$3")" -eq 1 ]' _ "$rc" "$work/err" "$log"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
