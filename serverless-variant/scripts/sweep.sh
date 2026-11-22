#!/usr/bin/env bash
# Leftover sweep of the serverless-variant lab after terraform destroy, on the learner's machine with profile
# anhnv-stg: lists, read-only, what still carries tag Lab=serverless-variant or the prefix svp-lab-sls in
# ap-southeast-1 and in IAM. Every list should be empty; the script exits 1 when one is not.
# Usage: scripts/sweep.sh
set -euo pipefail
export AWS_PAGER=""

readonly profile=anhnv-stg
readonly region=ap-southeast-1
readonly lab=svp-lab-sls
found=0
failed=0

aws_() {
  aws --profile "${profile}" --region "${region}" "$@"
}

# list TITLE COMMAND...: prints TITLE and what COMMAND lists, one item per line; "None" and blanks count as nothing,
# a failing COMMAND prints ERROR and fails the sweep instead of reading as empty.
list() {
  local title=$1 out
  shift
  if ! out=$("$@"); then
    printf 'ERROR %s\n' "${title}"
    failed=1
    return 0
  fi
  out=$(tr '\t' '\n' <<<"${out}" | grep -v -e '^None$' -e '^$' || true)
  if [[ -n "${out}" ]]; then
    printf 'LEFT  %s\n%s\n' "${title}" "${out}"
    found=1
  else
    printf 'none  %s\n' "${title}"
  fi
}

list "resources tagged Lab=serverless-variant" aws_ resourcegroupstaggingapi get-resources \
  --tag-filters Key=Lab,Values=serverless-variant --query 'ResourceTagMappingList[].ResourceARN' --output text
list "Lambda functions" aws_ lambda list-functions --output text \
  --query "Functions[?starts_with(FunctionName, '${lab}-')].FunctionName"
list "event source mappings" aws_ lambda list-event-source-mappings --output text \
  --query "EventSourceMappings[?contains(EventSourceArn, ':${lab}-')].UUID"
list "SQS queues" aws_ sqs list-queues --queue-name-prefix "${lab}-" --query 'QueueUrls[]' --output text
list "DynamoDB tables" aws_ dynamodb list-tables --output text --query "TableNames[?starts_with(@, '${lab}-')]"
list "REST APIs" aws_ apigateway get-rest-apis --output text --query "items[?starts_with(name, '${lab}-')].id"
list "state machines" aws_ stepfunctions list-state-machines --output text \
  --query "stateMachines[?starts_with(name, '${lab}-')].stateMachineArn"
list "event buses" aws_ events list-event-buses --name-prefix "${lab}" --query 'EventBuses[].Name' --output text
list "rules of the default bus" aws_ events list-rules --name-prefix "${lab}-" --query 'Rules[].Name' --output text
list "log groups" aws_ logs describe-log-groups --log-group-name-pattern "${lab}-" \
  --query 'logGroups[].logGroupName' --output text
list "CloudWatch Logs resource policies" aws_ logs describe-resource-policies --output text \
  --query "resourcePolicies[?starts_with(policyName, '${lab}-')].policyName"
list "S3 buckets" aws_ s3api list-buckets --prefix "${lab}-" --query 'Buckets[].Name' --output text
list "IAM roles" aws_ iam list-roles --output text --query "Roles[?starts_with(RoleName, '${lab}-')].RoleName"

((found == 0)) || echo "sweep: resources left; delete them, then sweep again" >&2
((failed == 0)) || echo "sweep: lists marked ERROR were not read (an expired session?); fix that, then sweep again" >&2
((found == 0 && failed == 0)) || exit 1
echo "sweep: nothing left"
