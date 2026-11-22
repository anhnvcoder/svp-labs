#!/usr/bin/env bash
# Leftover sweep of the data-scaling lab after terraform destroy of each root, on the learner's machine with profile
# anhnv-stg in ap-southeast-1: lists, read-only, what still carries tag Lab=data-scaling or the prefix svp-lab-ds-.
# Prints one line per list; writes no file. Exits 1 when a list is not empty or could not be read.
# Usage: SVP_AWS_STG_ACCOUNT_ID=<id> scripts/sweep.sh
set -euo pipefail
export AWS_PAGER=""

profile=anhnv-stg
region=ap-southeast-1
lab=svp-lab-ds
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

list "resources tagged Lab=data-scaling" aws_ resourcegroupstaggingapi get-resources \
  --tag-filters Key=Lab,Values=data-scaling --query 'ResourceTagMappingList[].ResourceARN' --output text

list "DB clusters" aws_ rds describe-db-clusters --output text \
  --query "DBClusters[?starts_with(DBClusterIdentifier, '$lab-')].DBClusterIdentifier"
list "DB instances" aws_ rds describe-db-instances --output text \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, '$lab-')].DBInstanceIdentifier"
list "DB proxies" aws_ rds describe-db-proxies --output text \
  --query "DBProxies[?starts_with(DBProxyName, '$lab-')].DBProxyName"
list "DB cluster snapshots" aws_ rds describe-db-cluster-snapshots --output text \
  --query "DBClusterSnapshots[?starts_with(DBClusterIdentifier, '$lab-')].DBClusterSnapshotIdentifier"
list "DB snapshots" aws_ rds describe-db-snapshots --output text \
  --query "DBSnapshots[?starts_with(DBInstanceIdentifier, '$lab-')].DBSnapshotIdentifier"
list "DB cluster automated backups" aws_ rds describe-db-cluster-automated-backups --output text \
  --query "DBClusterAutomatedBackups[?starts_with(DBClusterIdentifier, '$lab-')].DBClusterAutomatedBackupsArn"
list "DB instance automated backups" aws_ rds describe-db-instance-automated-backups --output text \
  --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, '$lab-')].DBInstanceAutomatedBackupsArn"

list "ElastiCache replication groups" aws_ elasticache describe-replication-groups --output text \
  --query "ReplicationGroups[?starts_with(ReplicationGroupId, '$lab-')].ReplicationGroupId"
list "ElastiCache cache clusters" aws_ elasticache describe-cache-clusters --output text \
  --query "CacheClusters[?starts_with(CacheClusterId, '$lab-')].CacheClusterId"
snapshots="Snapshots[?starts_with(SnapshotName, '$lab-') || starts_with(ReplicationGroupId || '', '$lab-')]"
list "ElastiCache snapshots" aws_ elasticache describe-snapshots --output text --query "$snapshots.SnapshotName"
list "ElastiCache users" aws_ elasticache describe-users --output text \
  --query "Users[?starts_with(UserId, '$lab-') || starts_with(UserName, '$lab-')].UserId"
list "ElastiCache user groups" aws_ elasticache describe-user-groups --output text \
  --query "UserGroups[?starts_with(UserGroupId, '$lab-')].UserGroupId"

list "instances not terminated" aws_ ec2 describe-instances --output text \
  --filters "Name=tag:Name,Values=$lab-*" \
  Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId'
list "network interfaces of the lab's security groups" aws_ ec2 describe-network-interfaces --output text \
  --filters "Name=group-name,Values=$lab-*" --query 'NetworkInterfaces[].NetworkInterfaceId'
list "Elastic IP addresses" aws_ ec2 describe-addresses --output text \
  --filters "Name=tag:Name,Values=$lab-*" --query 'Addresses[].AllocationId'

list "secrets, scheduled deletions included" aws_ secretsmanager list-secrets --include-planned-deletion --output text \
  --filters "Key=name,Values=$lab-" --query 'SecretList[].Name'
# A substring pattern, not a prefix: RDS Proxy creates /aws/rds/proxy/<name>, which terraform destroy leaves behind.
list "log groups with $lab- in their name" aws_ logs describe-log-groups --log-group-name-pattern "$lab-" \
  --output text --query 'logGroups[].logGroupName'
list "IAM roles" aws_ iam list-roles --output text --query "Roles[?starts_with(RoleName, '$lab-')].RoleName"

[ "$found" = 0 ] || echo "sweep: leftovers above; delete them, then run the sweep again" >&2
[ "$failed" = 0 ] ||
  echo "sweep: lists marked ERROR were not read (an expired session?); fix that, then run the sweep again" >&2
[ "$found$failed" = 00 ] || exit 1
echo "sweep: nothing left"
