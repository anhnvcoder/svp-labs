#!/usr/bin/env bash
# Drills of the multi-region-dr lab, run on the learner's machine with profile anhnv-stg: start the heartbeat writers,
# read ReplicaLag, time Cross-Region Replication, simulate the loss of the primary Region and measure RTO and RPO of the
# read replica and of the replicated backups, then delete what the drill made outside Terraform. Prints results only.

# The bastions run heartbeat.sh through SSM Run Command; the times of the rows come from their clocks, T0 from this one.
# Design notes: multi-region-dr/README.md.
# Usage: SVP_AWS_STG_ACCOUNT_ID=<id> scripts/drill.sh start | lag | crr [COUNT] | failover | cleanup | purge
set -euo pipefail

profile=anhnv-stg
primary_region=ap-southeast-1
dr_region=us-east-1
lab=svp-lab-dr
record=db.svp-lab-dr.internal
zone=svp-lab-dr.internal
ttl=10
hb=/opt/svp-lab-dr/heartbeat.sh
# Seconds a wait may last, and between two polls of a database.
limit=${SVP_DR_LIMIT:-3600}
poll=${SVP_DR_POLL:-10}

fail() {
  echo "drill: $*" >&2
  exit 1
}

aws_() {
  local region=$1
  shift
  aws --profile "$profile" --region "$region" "$@"
}

now() { date -u +%s; }
# utc EPOCH: the time as RFC 3339 in UTC, with BSD or GNU date.
utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

check_account() {
  local got
  [[ ${SVP_AWS_STG_ACCOUNT_ID:-} =~ ^[0-9]{12}$ ]] ||
    fail "export SVP_AWS_STG_ACCOUNT_ID=<the 12 digits of account svp-stg> first (never in a file)"
  got=$(aws_ "$primary_region" sts get-caller-identity --query Account --output text) || fail "sts get-caller-identity"
  [ "$got" = "$SVP_AWS_STG_ACCOUNT_ID" ] || fail "profile $profile signs in to $got, not to SVP_AWS_STG_ACCOUNT_ID"
  account=$got
}

# bastion REGION SIDE: the id of the running bastion of that side.
bastion() {
  local id
  id=$(aws_ "$1" ec2 describe-instances --filters "Name=tag:Name,Values=$lab-bastion-$2" \
    Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)
  [[ $id =~ ^i-[0-9a-f]+$ ]] || fail "no running bastion $lab-bastion-$2 in $1 (terraform apply first)"
  printf '%s' "$id"
}

# ssm REGION INSTANCE COMMAND: runs COMMAND on the instance and prints its output.
ssm() {
  local region=$1 id=$2 command=$3 cid out status deadline
  cid=$(aws_ "$region" ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$(jq -cn --arg c "$command" '{commands: [$c]}')" --query Command.CommandId --output text) ||
    fail "ssm send-command to $id"
  deadline=$(($(now) + 300))
  while :; do
    out=$(aws_ "$region" ssm get-command-invocation --command-id "$cid" --instance-id "$id" --output json \
      2>/dev/null) || out='{}'
    status=$(jq -r '.Status // "Pending"' <<<"$out")
    case $status in
      Success)
        jq -r '.StandardOutputContent' <<<"$out"
        return 0
        ;;
      Pending | InProgress | Delayed) ;;
      *)
        jq -r '.StandardErrorContent // empty' <<<"$out" >&2
        fail "'$command' on $id ended $status"
        ;;
    esac
    [ "$(now)" -lt "$deadline" ] || fail "'$command' on $id still $status after 300 s"
    sleep 2
  done
}

# db REGION IDENTIFIER: status, source of replication (None once promoted) and host of the instance, tab-separated.
db() {
  aws_ "$1" rds describe-db-instances --db-instance-identifier "$2" --output text \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,Endpoint.Address]'
}

# wait_db REGION IDENTIFIER DEADLINE [standalone]: waits until the instance is available, and no longer a replica
# with standalone; prints its host.
wait_db() {
  local status source host
  while :; do
    IFS=$'\t' read -r status source host < <(db "$1" "$2" 2>/dev/null || true)
    if [ "${status:-}" = available ] && { [ -z "${4:-}" ] || [ "${source:-}" = None ]; }; then
      printf '%s' "$host"
      return 0
    fi
    [ "$(now)" -lt "$3" ] || fail "$2 still ${status:-missing} at the deadline"
    sleep "$poll"
  done
}

switch_down() {
  aws_ "$dr_region" cloudwatch put-metric-data --namespace "$lab" --metric-name FailoverRequested --value 1
}

# measure LABEL HOST T0 DEADLINE SWITCH: polls HOST through the DR bastion until the DR writer has a row there, then
# prints RTO and RPO. SWITCH=1 writes the switch metric at each poll, so Route 53 keeps seeing data until the end.
measure() {
  local label=$1 host=$2 t0=$3 deadline=$4 switch=$5 out primary_last dr_first
  while :; do
    [ "$switch" = 0 ] || switch_down
    out=$(ssm "$dr_region" "$dr_bastion" "$hb report $host")
    primary_last=$(sed -n 's/^primary_last=//p' <<<"$out")
    dr_first=$(sed -n 's/^dr_first=//p' <<<"$out")
    [ -z "$dr_first" ] || break
    [ "$(now)" -lt "$deadline" ] ||
      fail "$label: failover not complete after $((deadline - t0)) s: no heartbeat of side dr in $host yet"
    sleep "$poll"
  done
  echo "RTO $label: $((dr_first - t0)) s (T0 $(utc "$t0"), first row of side dr $(utc "$dr_first"))"
  if [ -n "$primary_last" ]; then
    echo "RPO $label: $((t0 - primary_last)) s (newest row of side primary $(utc "$primary_last"))"
  else
    echo "RPO $label: unknown, no heartbeat of side primary in $host (writers started after the restore point?)"
    missing=1
  fi
}

cmd_start() {
  local pb drb
  check_account
  pb=$(bastion "$primary_region" primary)
  drb=$(bastion "$dr_region" dr)
  ssm "$primary_region" "$pb" "$hb setup"
  ssm "$primary_region" "$pb" "$hb start primary"
  ssm "$dr_region" "$drb" "$hb start dr"
  echo "writers started $(utc "$(now)"): primary on $pb, dr on $drb"
}

cmd_lag() {
  local end max avg
  end=$(now)
  read -r max avg < <(aws_ "$dr_region" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag \
    --dimensions "Name=DBInstanceIdentifier,Value=$lab-replica" --start-time "$(utc $((end - 900)))" \
    --end-time "$(utc "$end")" --period 60 --statistics Maximum Average \
    --query '[max(Datapoints[].Maximum), avg(Datapoints[].Average)]' --output text)
  echo "ReplicaLag of $lab-replica over the 15 min to $(utc "$end"): max ${max:-None} s, average ${avg:-None} s"
}

cmd_crr() {
  local count=${1:-5} src dst i key t0 t1
  check_account
  src=$lab-media-$account-$primary_region
  dst=$lab-media-$account-$dr_region
  probe=$(mktemp)
  trap 'rm -f "$probe"' EXIT
  head -c 1048576 /dev/urandom >"$probe"
  for ((i = 1; i <= count; i++)); do
    key=crr-probe/$(now)-$i.bin
    t0=$(now)
    aws_ "$primary_region" s3api put-object --bucket "$src" --key "$key" --body "$probe" >/dev/null
    until aws_ "$dr_region" s3api head-object --bucket "$dst" --key "$key" >/dev/null 2>&1; do
      [ "$(now)" -lt $((t0 + limit)) ] || fail "CRR: $key not in $dst after $limit s"
      sleep 1
    done
    t1=$(now)
    echo "CRR $key: $((t1 - t0)) s (put $(utc "$t0"), seen in $dst $(utc "$t1"), 1 MiB)"
  done
}

cmd_failover() {
  local t0 deadline sg rule client lag query backup lrt dr_sg replica_host pitr_host zone_id change
  check_account
  dr_bastion=$(bastion "$dr_region" dr)
  sg=$(aws_ "$primary_region" ec2 describe-security-groups --filters "Name=group-name,Values=$lab-primary-db" \
    --query 'SecurityGroups[0].GroupId' --output text)
  # shellcheck disable=SC2016 # the backquotes are a JMESPath literal
  read -r rule client < <(aws_ "$primary_region" ec2 describe-security-group-rules --output text \
    --filters "Name=group-id,Values=$sg" \
    --query 'SecurityGroupRules[?IsEgress==`false`] | [0].[SecurityGroupRuleId,ReferencedGroupInfo.GroupId]')
  [[ ${rule:-} =~ ^sgr- ]] ||
    fail "no inbound rule on $lab-primary-db ($sg): already cut off? Failback step 1 of the README reopens it"
  dr_sg=$(aws_ "$dr_region" ec2 describe-security-groups --filters "Name=group-name,Values=$lab-replica-db" \
    --query 'SecurityGroups[0].GroupId' --output text)
  # Checked before T0: a backup that cannot be restored stops the drill while the primary is still reachable.
  query="DBInstanceAutomatedBackups[?DBInstanceIdentifier=='$lab-primary']"
  query+=" | [0].[DBInstanceAutomatedBackupsArn,RestoreWindow.LatestTime]"
  read -r backup lrt < <(aws_ "$dr_region" rds describe-db-instance-automated-backups --output text --query "$query")
  [[ ${backup:-} =~ ^arn: ]] || fail "no replicated backup of $lab-primary in $dr_region"
  [[ ${lrt:-} =~ ^[0-9]{4}- ]] ||
    fail "the replicated backup of $lab-primary has no restorable time yet; run again later"
  echo "replicated backups: latest restorable time $lrt before T0"

  t0=$(now)
  deadline=$((t0 + limit))
  echo "T0 $(utc "$t0"): the primary Region is lost"
  aws_ "$primary_region" ec2 revoke-security-group-ingress --group-id "$sg" --security-group-rule-ids "$rule" >/dev/null
  echo "primary cut off: rule $rule of $sg revoked (it let in bastion group $client; failback restores it)"
  lag=$(aws_ "$dr_region" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag \
    --dimensions "Name=DBInstanceIdentifier,Value=$lab-replica" --start-time "$(utc $((t0 - 300)))" \
    --end-time "$(utc "$t0")" --period 60 --statistics Maximum --query 'max(Datapoints[].Maximum)' --output text)
  echo "ReplicaLag over the 5 min before T0: max $lag s (what a real loss of the Region could lose)"

  aws_ "$dr_region" rds restore-db-instance-to-point-in-time --source-db-instance-automated-backups-arn "$backup" \
    --target-db-instance-identifier "$lab-pitr" --use-latest-restorable-time --db-instance-class db.t4g.micro \
    --db-subnet-group-name "$lab-replica" --vpc-security-group-ids "$dr_sg" --no-publicly-accessible --no-multi-az \
    --backup-retention-period 0 --tags Key=Project,Value=svp Key=Lab,Value=multi-region-dr >/dev/null
  echo "backup and restore: $lab-pitr restoring from $backup"
  aws_ "$dr_region" rds promote-read-replica --db-instance-identifier "$lab-replica" \
    --backup-retention-period 1 >/dev/null
  echo "pilot light: $lab-replica promoting"

  replica_host=$(wait_db "$dr_region" "$lab-replica" "$deadline" standalone)
  echo "pilot light: $lab-replica standalone $(utc "$(now)"); failover switch down"
  measure pilot-light "$replica_host" "$t0" "$deadline" 1

  pitr_host=$(wait_db "$dr_region" "$lab-pitr" "$deadline")
  echo "backup and restore: $lab-pitr available $(utc "$(now)"); secondary record of $record now points at it"
  zone_id=$(aws_ "$dr_region" route53 list-hosted-zones-by-name --dns-name "$zone" \
    --query "HostedZones[?Name=='$zone.' && Config.PrivateZone] | [0].Id" --output text)
  change=$(jq -cn --arg n "$record" --arg h "$pitr_host" --argjson ttl "$ttl" '{Changes: [{Action: "UPSERT",
    ResourceRecordSet: {Name: $n, Type: "CNAME", SetIdentifier: "secondary", Failover: "SECONDARY", TTL: $ttl,
    ResourceRecords: [{Value: $h}]}}]}')
  aws_ "$dr_region" route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "$change" >/dev/null
  measure backup-restore "$pitr_host" "$t0" "$deadline" 0
}

# Before terraform destroy: the writers stop, and the instances made outside Terraform go.
cmd_cleanup() {
  local region id region_id pb drb
  check_account
  pb=$(bastion "$primary_region" primary) && ssm "$primary_region" "$pb" "$hb stop" || true
  drb=$(bastion "$dr_region" dr) && ssm "$dr_region" "$drb" "$hb stop" || true
  for region_id in "$dr_region $lab-pitr" "$primary_region $lab-fb"; do
    read -r region id <<<"$region_id"
    db "$region" "$id" >/dev/null 2>&1 || continue
    aws_ "$region" rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot \
      --delete-automated-backups >/dev/null
    echo "deleting $id in $region"
    aws_ "$region" rds wait db-instance-deleted --db-instance-identifier "$id"
    echo "$id deleted $(utc "$(now)")"
  done
}

# After terraform destroy: stopping the backup replication keeps the replicated backups until their retention ends.
cmd_purge() {
  local region arn
  check_account
  for region in "$primary_region" "$dr_region"; do
    for arn in $(aws_ "$region" rds describe-db-instance-automated-backups --output text --query \
      "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, '$lab-')].DBInstanceAutomatedBackupsArn"); do
      [ "$arn" != None ] || continue
      aws_ "$region" rds delete-db-instance-automated-backup --db-instance-automated-backups-arn "$arn" >/dev/null
      echo "deleted automated backup $arn"
    done
  done
  echo "purge done $(utc "$(now)")"
}

missing=0
account=
dr_bastion=
probe=
case ${1:-} in
  start) cmd_start ;;
  lag) cmd_lag ;;
  crr) cmd_crr "${2:-5}" ;;
  failover) cmd_failover ;;
  cleanup) cmd_cleanup ;;
  purge) cmd_purge ;;
  *) fail "usage: drill.sh start | lag | crr [COUNT] | failover | cleanup | purge" ;;
esac
exit "$missing"
