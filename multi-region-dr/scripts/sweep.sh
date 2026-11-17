#!/usr/bin/env bash
# Leftover sweep of the multi-region-dr lab after terraform destroy and drill.sh purge, on the learner's machine with
# profile anhnv-stg: lists, read-only, what still carries tag Lab=multi-region-dr or the prefix svp-lab-dr in both
# Regions and in the global services. Exits 1 when a list is not empty or could not be read.
# Usage: SVP_AWS_STG_ACCOUNT_ID=<id> scripts/sweep.sh
set -euo pipefail

profile=anhnv-stg
lab=svp-lab-dr
found=0
failed=0

fail() {
  echo "sweep: $*" >&2
  exit 1
}

aws_() {
  local region=$1
  shift
  aws --profile "$profile" --region "$region" "$@"
}

# list TITLE COMMAND...: prints TITLE and what COMMAND lists, one item per line; "None" and blanks count as nothing.
# A list that could not be read proves nothing, so it is marked ERROR, never none.
list() {
  local title=$1 out
  shift
  if ! out=$("$@"); then
    printf 'ERROR %s\n' "$title"
    failed=1
    return 0
  fi
  out=$(tr '\t' '\n' <<<"$out" | grep -v -e '^None$' -e '^$' || true)
  if [ -n "$out" ]; then
    printf 'LEFT  %s\n%s\n' "$title" "$out"
    found=1
  else
    printf 'none  %s\n' "$title"
  fi
}

[[ ${SVP_AWS_STG_ACCOUNT_ID:-} =~ ^[0-9]{12}$ ]] ||
  fail "export SVP_AWS_STG_ACCOUNT_ID=<the 12 digits of account svp-stg> first (never in a file)"
account=$(aws_ ap-southeast-1 sts get-caller-identity --query Account --output text) || fail "sts get-caller-identity"
[ "$account" = "$SVP_AWS_STG_ACCOUNT_ID" ] ||
  fail "profile $profile signs in to $account, not to SVP_AWS_STG_ACCOUNT_ID"

for region in ap-southeast-1 us-east-1; do
  list "$region: resources tagged Lab=multi-region-dr" aws_ "$region" resourcegroupstaggingapi get-resources \
    --tag-filters Key=Lab,Values=multi-region-dr --query 'ResourceTagMappingList[].ResourceARN' --output text
  list "$region: DB instances" aws_ "$region" rds describe-db-instances --output text \
    --query "DBInstances[?starts_with(DBInstanceIdentifier, '$lab-')].DBInstanceIdentifier"
  list "$region: automated backups, replicated ones included" \
    aws_ "$region" rds describe-db-instance-automated-backups --output text \
    --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, '$lab-')].DBInstanceAutomatedBackupsArn"
  list "$region: DB snapshots" aws_ "$region" rds describe-db-snapshots --output text \
    --query "DBSnapshots[?starts_with(DBInstanceIdentifier, '$lab-')].DBSnapshotIdentifier"
  list "$region: secrets" aws_ "$region" secretsmanager list-secrets --include-planned-deletion --output text \
    --filters "Key=name,Values=$lab" --query 'SecretList[].Name'
  list "$region: running or stopped instances" aws_ "$region" ec2 describe-instances --output text \
    --filters "Name=tag:Name,Values=$lab-*" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId'
  list "$region: VPCs" aws_ "$region" ec2 describe-vpcs --filters "Name=tag:Name,Values=$lab-*" --output text \
    --query 'Vpcs[].VpcId'
  list "$region: network interfaces of the lab's security groups" aws_ "$region" ec2 describe-network-interfaces \
    --filters "Name=group-name,Values=$lab-*" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
  list "$region: CloudWatch alarms" aws_ "$region" cloudwatch describe-alarms --alarm-name-prefix "$lab" \
    --query 'MetricAlarms[].AlarmName' --output text
done

list "S3 buckets" aws_ us-east-1 s3api list-buckets --prefix "$lab-" --query 'Buckets[].Name' --output text
list "Route 53 private zone" aws_ us-east-1 route53 list-hosted-zones-by-name --dns-name "$lab.internal" \
  --query "HostedZones[?Name=='$lab.internal.'].Id" --output text
list "Route 53 health checks on the switch alarm" aws_ us-east-1 route53 list-health-checks --output text \
  --query "HealthChecks[?HealthCheckConfig.AlarmIdentifier.Name=='$lab-failover'].Id"
list "IAM roles" aws_ us-east-1 iam list-roles --output text \
  --query "Roles[?starts_with(RoleName, '$lab-')].RoleName"

[ "$found" = 0 ] || echo "sweep: leftovers above; delete them, then run the sweep again" >&2
[ "$failed" = 0 ] ||
  echo "sweep: lists marked ERROR were not read (an expired session?); fix that, then run the sweep again" >&2
[ "$found$failed" = 00 ] || exit 1
echo "sweep: nothing left"
