#!/usr/bin/env bash
# Self-test of drill.sh with fake aws, date and sleep first on PATH: no network, no account. Covers RTO and RPO of both
# paths, the checks made before T0, a failover not done by the deadline, a missing primary heartbeat, a wrong account,
# CRR timing, the start of the writers and the purge of replicated backups.

# The fake aws refuses a call without --profile anhnv-stg or with a Region the organization denies; the fake clock
# moves 10 s per reading, so every wait reaches its deadline.
# Usage: bash scripts/drill-test.sh
# shellcheck disable=SC2016 # bash -c '...' and the fakes expand their own arguments, not this shell
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
export FAKE_LOG=$log FAKE_DIR=$work REAL_DATE
REAL_DATE=$(command -v date)
command -v jq >/dev/null || { echo "FAIL  jq is needed by drill.sh and this test" >&2; exit 1; }

# The fake aws answers $answers/<service>_<command>[_<subject>] (the subject: the bastion side, the security group, the
# DB instance or the report host); <file>.<n> is the answer of the nth call when it exists, the highest one after.
# An answer that reads FAIL exits 254. get-command-invocation reports InProgress once per command, then Success.
cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$FAKE_LOG"
[ "$1 $2" = "--profile anhnv-stg" ] || { echo "fake aws: not --profile anhnv-stg first" >&2; exit 97; }
[ "$3" = --region ] && case $4 in ap-southeast-1 | us-east-1) true ;; *) false ;; esac ||
  { echo "fake aws: --region $4 is not one of the two Regions" >&2; exit 97; }
key=$5_$6
shift 6
args=" $* "
case $key in
  ec2_describe-instances) key+=_${args##*Values=svp-lab-dr-bastion-}; key=${key%% *} ;;
  ec2_describe-security-groups) key+=_${args##*Values=svp-lab-dr-}; key=${key%% *} ;;
  rds_describe-db-instances) key+=_${args##*--db-instance-identifier }; key=${key%% *} ;;
  ssm_send-command)
    n=$(($(cat "$FAKE_DIR/cmd.n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_DIR/cmd.n"
    printf '%s\n' "${args#*--parameters }" | sed 's/ --query.*//' >"$FAKE_DIR/cmd-$n"
    echo "cmd-$n"
    exit 0
    ;;
  ssm_get-command-invocation)
    cid=${args##*--command-id }; cid=${cid%% *}
    if [ ! -e "$FAKE_DIR/$cid.seen" ]; then
      : >"$FAKE_DIR/$cid.seen"
      echo '{"Status": "InProgress"}'
      exit 0
    fi
    command=$(cat "$FAKE_DIR/$cid")
    case $command in
      *" report "*) host=${command##* report }; host=${host%%\"*}; key=report_$host ;;
      *) echo '{"Status": "Success", "StandardOutputContent": "done"}'; exit 0 ;;
    esac
    ;;
esac
n=$(($(cat "$FAKE_DIR/$key.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/$key.n"
file=$FAKE_DIR/answers/$key
while [ "$n" -gt 1 ] && [ ! -e "$file.$n" ]; do n=$((n - 1)); done
[ ! -e "$file.$n" ] || file=$file.$n
[ -e "$file" ] || { echo "fake aws: no answer for $key" >&2; exit 96; }
answer=$(cat "$file")
[ "$answer" != FAIL ] || { echo "An error occurred (NotFound)" >&2; exit 254; }
case $key in
  report_*) jq -cn --arg o "$(tr '|' '\n' <<<"$answer")" '{Status: "Success", StandardOutputContent: $o}' ;;
  *) printf '%s\n' "$answer" ;;
esac
EOF

# date -u +%s moves 10 s per call from 1800000000; any other use of date is the real one.
cat >"$bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "-u +%s" ]; then
  n=$(($(cat "$FAKE_DIR/date.n" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$FAKE_DIR/date.n"
  echo $((1800000000 + 10 * n))
else
  exec "$REAL_DATE" "$@"
fi
EOF
printf '#!/bin/sh\n' >"$bin/sleep"
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
# answer KEY TEXT...: the answers of KEY, the first TEXT for the first call and so on.
answer() {
  local key=$1 n=0
  shift
  rm -f "$answers/$key" "$answers/$key".*
  for text in "$@"; do
    n=$((n + 1))
    printf '%b\n' "$text" >"$answers/$key.$n"
  done
}
reset() {
  rm -f "$work"/*.n "$work"/cmd-* "$work"/*.seen
  : >"$log"
}
drill() {
  rc=0
  SVP_AWS_STG_ACCOUNT_ID=000000000000 bash "$src/drill.sh" "$@" >"$work/out" 2>"$work/err" || rc=$?
}
# number LABEL KIND: the seconds of line "<KIND> <LABEL>: <n> s" of the output.
number() { sed -n "s/^$2 $1: \([0-9-]*\) s.*/\1/p" "$work/out"; }
# order PATTERN...: the calls matching each PATTERN appear in this order in the log.
order() {
  local last=0 line
  for p in "$@"; do
    line=$(grep -n -- "$p" "$log" | head -n 1 | cut -d: -f1)
    [ -n "$line" ] && [ "$line" -gt "$last" ] || return 1
    last=$line
  done
}

replica=svp-lab-dr-replica.abc.us-east-1.rds.amazonaws.com
pitr=svp-lab-dr-pitr.abc.us-east-1.rds.amazonaws.com
answer sts_get-caller-identity 000000000000
answer ec2_describe-instances_primary i-0aaaaaaaaaaaaaaa1
answer ec2_describe-instances_dr i-0bbbbbbbbbbbbbbb2
answer ec2_describe-security-groups_primary-db sg-0aaaaaaaaaaaaaaa1
answer ec2_describe-security-groups_replica-db sg-0bbbbbbbbbbbbbbb2
answer ec2_describe-security-group-rules 'sgr-0123456789abcdef0\tsg-0ccccccccccccccc3'
answer ec2_revoke-security-group-ingress ''
answer cloudwatch_get-metric-statistics '2.0'
answer cloudwatch_put-metric-data ''
backups='arn:aws:rds:us-east-1:000000000000:auto-backup:ab-0123\t2027-01-15T07:55:00+00:00'
answer rds_describe-db-instance-automated-backups "$backups"
answer rds_restore-db-instance-to-point-in-time ''
answer rds_promote-read-replica ''
answer route53_list-hosted-zones-by-name /hostedzone/Z0123456789ABC
answer route53_change-resource-record-sets ''

# set_failover REPLICA_REPORTS PITR_REPORTS: the database answers of the drill, '|' between the lines of one answer.
set_failover() {
  reset
  answer rds_describe-db-instances_svp-lab-dr-replica "available\tsvp-lab-dr-primary\t$replica" \
    "modifying\tsvp-lab-dr-primary\t$replica" "available\tNone\t$replica"
  answer rds_describe-db-instances_svp-lab-dr-pitr FAIL "creating\tNone\tNone" "available\tNone\t$pitr"
  IFS=, read -r -a r <<<"$1"
  answer "report_$replica" "${r[@]}"
  IFS=, read -r -a r <<<"$2"
  answer "report_$pitr" "${r[@]}"
}

# --- failover: both paths recover -------------------------------------------------------------------------------------
set_failover 'primary_last=1800000001|dr_first=,primary_last=1800000001|dr_first=1800000300' \
  'primary_last=1799999700|dr_first=1800000900'
drill failover
expect "failover ends 0" [ "$rc" = 0 ]
expect "the fake aws refused no call" [ ! -s "$work/err" ]
rto=$(number pilot-light RTO) rpo=$(number pilot-light RPO)
expect "pilot light: RTO and RPO add up to first dr row minus newest primary row" [ $((rto + rpo)) = 299 ]
expect "pilot light: RTO counts from T0 to the first dr row" grep -q "^RTO pilot-light: $rto s (T0 .*Z, first row of side dr" "$work/out"
t0=$((1800000300 - rto))
expect "T0 printed is the T0 of the numbers" grep -q "^T0 $("$REAL_DATE" -u -r "$t0" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  "$REAL_DATE" -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ):" "$work/out"
rto_b=$(number backup-restore RTO) rpo_b=$(number backup-restore RPO)
expect "backup and restore: same T0" [ $((t0 + rto_b)) = 1800000900 ]
expect "backup and restore: RPO from the newest primary row restored" [ $((t0 - rpo_b)) = 1799999700 ]
expect "ReplicaLag before T0 is reported" grep -q '^ReplicaLag over the 5 min before T0: max 2.0 s' "$work/out"
expect "cut off, then restore, then promote, then the switch" order 'revoke-security-group-ingress --group-id sg-0aaaaaaaaaaaaaaa1 --security-group-rule-ids sgr-0123456789abcdef0' \
  'restore-db-instance-to-point-in-time' 'promote-read-replica' 'put-metric-data'
expect "the replicated backup is checked before the primary is cut off" order 'describe-db-instance-automated-backups' \
  'revoke-security-group-ingress'
expect "the primary is cut off in its own Region" grep -q -- '--region ap-southeast-1 ec2 revoke-security-group-ingress' "$log"
expect "the restore uses the replicated backup at its latest restorable time, in the DR subnets" \
  grep -q -- '--region us-east-1 rds restore-db-instance-to-point-in-time --source-db-instance-automated-backups-arn arn:aws:rds:us-east-1:000000000000:auto-backup:ab-0123 --target-db-instance-identifier svp-lab-dr-pitr --use-latest-restorable-time .*--db-subnet-group-name svp-lab-dr-replica --vpc-security-group-ids sg-0bbbbbbbbbbbbbbb2' "$log"
expect "the promotion turns backups on" grep -q -- 'promote-read-replica --db-instance-identifier svp-lab-dr-replica --backup-retention-period 1' "$log"
expect "the switch is the FailoverRequested metric of the DR Region" \
  grep -q -- '--region us-east-1 cloudwatch put-metric-data --namespace svp-lab-dr --metric-name FailoverRequested --value 1' "$log"
expect "the switch waits for the promotion" order "describe-db-instances --db-instance-identifier svp-lab-dr-replica" 'put-metric-data'
expect "the secondary record moves to the restored instance after the pilot light measure" \
  grep -q "route53 change-resource-record-sets --hosted-zone-id /hostedzone/Z0123456789ABC .*\"SetIdentifier\":\"secondary\".*\"Value\":\"$pitr\"" "$log"
expect "reports run on the DR bastion" [ "$(grep -c 'ssm send-command --instance-ids i-0bbbbbbbbbbbbbbb2' "$log")" = 3 ]

# --- failover: no dr row by the deadline ------------------------------------------------------------------------------
set_failover 'primary_last=1800000001|dr_first=' 'primary_last=1799999700|dr_first='
SVP_DR_LIMIT=300 drill failover
expect "a failover not done by the deadline fails" [ "$rc" = 1 ]
expect "and says so with the deadline" grep -q "pilot-light: failover not complete after 300 s: no heartbeat of side dr in $replica" "$work/err"
expect "and prints no RTO" bash -c '! grep -q "^RTO" "$1"' _ "$work/out"

# --- failover: no primary heartbeat -----------------------------------------------------------------------------------
set_failover 'primary_last=|dr_first=1800000300' 'primary_last=|dr_first=1800000900'
drill failover
expect "a missing primary heartbeat ends 1" [ "$rc" = 1 ]
expect "RPO is unknown, not a number" grep -q "^RPO pilot-light: unknown, no heartbeat of side primary in $replica" "$work/out"
expect "the other path is still measured" grep -q '^RTO backup-restore: ' "$work/out"

# --- failover: a precondition fails before T0 -------------------------------------------------------------------------
# nothing_changed: the drill printed no T0 and called nothing that changes the account.
nothing_changed() { ! grep -q '^T0' "$work/out" && ! grep -Eq 'revoke|restore|promote|put-metric' "$log"; }
set_failover 'primary_last=1800000001|dr_first=1800000300' 'primary_last=1799999700|dr_first=1800000900'
answer rds_describe-db-instance-automated-backups 'None'
drill failover
expect "no replicated backup: fails and says so" \
  bash -c '[ "$1" = 1 ] && grep -q "no replicated backup of svp-lab-dr-primary in us-east-1" "$2"' _ "$rc" "$work/err"
expect "no replicated backup: nothing changed" nothing_changed
set_failover 'primary_last=1800000001|dr_first=1800000300' 'primary_last=1799999700|dr_first=1800000900'
answer rds_describe-db-instance-automated-backups 'arn:aws:rds:us-east-1:000000000000:auto-backup:ab-0123\tNone'
drill failover
expect "a replicated backup with no restore window yet: fails and says so" \
  bash -c '[ "$1" = 1 ] && grep -q "has no restorable time yet" "$2"' _ "$rc" "$work/err"
expect "a replicated backup with no restore window yet: nothing changed" nothing_changed
answer rds_describe-db-instance-automated-backups "$backups"
set_failover 'primary_last=1800000001|dr_first=1800000300' 'primary_last=1799999700|dr_first=1800000900'
answer ec2_describe-security-group-rules 'None\tNone'
drill failover
expect "a primary already cut off: fails and names the way to reopen it" \
  bash -c '[ "$1" = 1 ] && grep -q "already cut off? Failback step 1 of the README reopens it" "$2"' _ "$rc" "$work/err"
expect "a primary already cut off: nothing changed" nothing_changed
answer ec2_describe-security-group-rules 'sgr-0123456789abcdef0\tsg-0ccccccccccccccc3'

# --- account ----------------------------------------------------------------------------------------------------------
reset
rc=0
bash "$src/drill.sh" failover >"$work/out" 2>"$work/err" || rc=$?
expect "no account variable: fails" [ "$rc" = 1 ]
expect "no account variable: no aws call" [ ! -s "$log" ]
reset
answer sts_get-caller-identity 444444444444
drill failover
expect "another account: fails before any change" bash -c '[ "$1" = 1 ] && ! grep -Eq "revoke|restore|promote|put-metric" "$2"' _ "$rc" "$log"
answer sts_get-caller-identity 000000000000

# --- crr --------------------------------------------------------------------------------------------------------------
reset
answer s3api_put-object ''
answer s3api_head-object FAIL FAIL ''
drill crr 1
expect "crr ends 0" [ "$rc" = 0 ]
expect "crr puts into the primary bucket and polls the DR bucket" order \
  '--region ap-southeast-1 s3api put-object --bucket svp-lab-dr-media-000000000000-ap-southeast-1 --key crr-probe/' \
  '--region us-east-1 s3api head-object --bucket svp-lab-dr-media-000000000000-us-east-1 --key crr-probe/'
expect "crr prints the seconds until the object is in the DR bucket" \
  grep -Eq '^CRR crr-probe/[0-9]+-1.bin: [0-9]+ s \(put .*Z, seen in svp-lab-dr-media-000000000000-us-east-1 .*Z, 1 MiB\)$' "$work/out"
expect "crr polled three times" [ "$(grep -c 'head-object' "$log")" = 3 ]

# --- start ------------------------------------------------------------------------------------------------------------
reset
drill start
expect "start ends 0" [ "$rc" = 0 ]
expect "start makes the table, then starts each writer on its own side" \
  bash -c 'grep -h . "$1"/cmd-1 "$1"/cmd-2 "$1"/cmd-3 | tr -d "\n" | grep -q "heartbeat.sh setup.*heartbeat.sh start primary.*heartbeat.sh start dr"' _ "$work"
expect "the DR writer starts in the DR Region" grep -q -- '--region us-east-1 ssm send-command --instance-ids i-0bbbbbbbbbbbbbbb2' "$log"

# --- purge ------------------------------------------------------------------------------------------------------------
reset
answer rds_describe-db-instance-automated-backups 'None' 'arn:aws:rds:us-east-1:000000000000:auto-backup:ab-0123'
answer rds_delete-db-instance-automated-backup ''
drill purge
expect "purge deletes the replicated backups left in the DR Region" \
  grep -q -- '--region us-east-1 rds delete-db-instance-automated-backup --db-instance-automated-backups-arn arn:aws:rds:us-east-1:000000000000:auto-backup:ab-0123' "$log"
expect "purge deletes nothing else" [ "$(grep -c 'delete-db-instance-automated-backup ' "$log")" = 1 ]

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "ok    every check passed"
