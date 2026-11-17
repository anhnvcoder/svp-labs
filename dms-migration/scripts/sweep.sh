#!/usr/bin/env bash
# Leftover sweep of the dms-migration lab after terraform destroy, on the learner's machine with profile anhnv-stg:
# lists, read-only, what still carries tag Lab=dms-migration or the prefix svp-lab-dms in ap-southeast-1 and in IAM.
# Every list should be empty; the script exits 1 when one is not or could not be read.
# Usage: SVP_AWS_STG_ACCOUNT_ID=<id> scripts/sweep.sh
set -euo pipefail

profile=anhnv-stg
region=ap-southeast-1
lab=svp-lab-dms
found=0
failed=0

fail() {
  echo "sweep: $*" >&2
  exit 1
}

aws_() { aws --profile "$profile" --region "$region" "$@"; }

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
account=$(aws_ sts get-caller-identity --query Account --output text) || fail "sts get-caller-identity"
[ "$account" = "$SVP_AWS_STG_ACCOUNT_ID" ] ||
  fail "profile $profile signs in to $account, not to SVP_AWS_STG_ACCOUNT_ID"

list "resources tagged Lab=dms-migration" aws_ resourcegroupstaggingapi get-resources \
  --tag-filters Key=Lab,Values=dms-migration --query 'ResourceTagMappingList[].ResourceARN' --output text
list "DMS replication tasks" aws_ dms describe-replication-tasks --without-settings --output text \
  --query "ReplicationTasks[?starts_with(ReplicationTaskIdentifier, '$lab')].ReplicationTaskIdentifier"
list "DMS replication instances" aws_ dms describe-replication-instances --output text \
  --query "ReplicationInstances[?starts_with(ReplicationInstanceIdentifier, '$lab')].ReplicationInstanceIdentifier"
list "DMS endpoints" aws_ dms describe-endpoints --output text \
  --query "Endpoints[?starts_with(EndpointIdentifier, '$lab')].EndpointIdentifier"
list "DMS certificates" aws_ dms describe-certificates --output text \
  --query "Certificates[?starts_with(CertificateIdentifier, '$lab')].CertificateIdentifier"
list "DMS replication subnet groups" aws_ dms describe-replication-subnet-groups --output text \
  --query "ReplicationSubnetGroups[?starts_with(ReplicationSubnetGroupIdentifier, '$lab')].ReplicationSubnetGroupIdentifier"
list "DB instances" aws_ rds describe-db-instances --output text \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, '$lab-')].DBInstanceIdentifier"
list "DB snapshots" aws_ rds describe-db-snapshots --output text \
  --query "DBSnapshots[?starts_with(DBInstanceIdentifier, '$lab-')].DBSnapshotIdentifier"
list "automated backups" aws_ rds describe-db-instance-automated-backups --output text \
  --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, '$lab-')].DBInstanceAutomatedBackupsArn"
list "secrets, those scheduled for deletion included" aws_ secretsmanager list-secrets --include-planned-deletion \
  --filters "Key=name,Values=$lab" --query 'SecretList[].Name' --output text
list "SSM parameters" aws_ ssm get-parameters-by-path --path "/$lab" --recursive --query 'Parameters[].Name' --output text
list "running or stopped instances" aws_ ec2 describe-instances --output text \
  --filters "Name=tag:Name,Values=$lab-*" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId'
list "VPCs" aws_ ec2 describe-vpcs --filters "Name=tag:Name,Values=$lab-*" --query 'Vpcs[].VpcId' --output text
list "VPC endpoints" aws_ ec2 describe-vpc-endpoints --filters "Name=tag:Name,Values=$lab-*" \
  --query 'VpcEndpoints[].VpcEndpointId' --output text
list "VPC peering connections not deleted" aws_ ec2 describe-vpc-peering-connections \
  --filters "Name=tag:Name,Values=$lab-*" Name=status-code,Values=pending-acceptance,provisioning,active \
  --query 'VpcPeeringConnections[].VpcPeeringConnectionId' --output text
list "network interfaces of the lab's security groups" aws_ ec2 describe-network-interfaces \
  --filters "Name=group-name,Values=$lab*" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
list "CloudWatch log groups of the task" aws_ logs describe-log-groups --log-group-name-prefix "dms-tasks-$lab" \
  --query 'logGroups[].logGroupName' --output text
list "IAM roles" aws_ iam list-roles --output text --query "Roles[?starts_with(RoleName, '$lab-')].RoleName"

# Account-wide roles under the names DMS requires: the destroy removes them only when the lab created them.
if roles=$(aws_ iam list-roles --output text \
  --query "Roles[?RoleName=='dms-vpc-role' || RoleName=='dms-cloudwatch-logs-role'].RoleName"); then
  echo "info  account-wide DMS roles (expected only when they were there before the session): $(tr '\t' ' ' <<<"$roles")"
else
  echo "ERROR account-wide DMS roles"
  failed=1
fi

[ "$found" = 0 ] || echo "sweep: leftovers above; delete them, then run the sweep again" >&2
[ "$failed" = 0 ] ||
  echo "sweep: lists marked ERROR were not read (an expired session?); fix that, then run the sweep again" >&2
[ "$found$failed" = 00 ] || exit 1
echo "sweep: nothing left"
