#!/usr/bin/env bash
# Measurements of the serverless-variant lab, run on the learner's machine with profile anhnv-stg: API latency under a
# k6 load, end-to-end latency and usage from CloudWatch, the duplicate test on the view queue, and both transcode paths.
# Reads the lab's resources by their fixed names; writes only test views, messages and uploads. Prints each number
# with its unit and the UTC time; exits 1 when a check fails.

# Design notes: serverless-variant/README.md.
# Usage: scripts/measure.sh load URL [RATE] [DURATION]
#        SVP_AWS_STG_ACCOUNT_ID=<id> scripts/measure.sh e2e [MINUTES] | duplicate | transcode
set -euo pipefail
export AWS_PAGER=""

readonly profile=anhnv-stg
readonly region=ap-southeast-1
readonly lab=svp-lab-sls
readonly table=svp-lab-sls-views
# Same pin as K6_IMAGE in the Makefile of svp-backend.
readonly k6_image=grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8
# Seconds a wait may last, and between two polls.
readonly limit=${SVP_SLS_LIMIT:-180}
readonly poll=${SVP_SLS_POLL:-5}

fail() {
  echo "measure: $*" >&2
  exit 1
}

aws_() {
  aws --profile "${profile}" --region "${region}" "$@"
}

now() { date -u +%s; }
# utc EPOCH: the time as RFC 3339 in UTC, with BSD or GNU date.
utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
new_id() { uuidgen | tr '[:upper:]' '[:lower:]'; }

check_account() {
  local got
  [[ ${SVP_AWS_STG_ACCOUNT_ID:-} =~ ^[0-9]{12}$ ]] ||
    fail "export SVP_AWS_STG_ACCOUNT_ID=<the 12 digits of account svp-stg> first (never in a file)"
  got=$(aws_ sts get-caller-identity --query Account --output text) || fail "sts get-caller-identity"
  [[ "${got}" == "${SVP_AWS_STG_ACCOUNT_ID}" ]] || fail "profile ${profile} signs in to ${got}, not to SVP_AWS_STG_ACCOUNT_ID"
}

# load URL RATE DURATION: k6 posts views of ten random videos at RATE per second for DURATION and prints the latency
# percentiles of the API and the count of each status. The URL holds {id}, as terraform output view_url prints it.
load() {
  local url=$1 rate=${2:-20} duration=${3:-5m} ids
  [[ "${url}" == https://*'{id}'* ]] || fail "load: give the view_url output of the root (https://.../videos/{id}/views)"
  if ! [[ "${rate}" =~ ^[0-9]+$ ]] || ((rate < 1 || rate > 50)); then
    fail "load: RATE must be 1 to 50, the stage throttle"
  fi
  ids=$(new_id)
  for _ in 2 3 4 5 6 7 8 9 10; do ids="${ids},$(new_id)"; done
  echo "load start $(utc "$(now)") rate ${rate}/s duration ${duration}"
  env -u DOCKER_DEFAULT_PLATFORM docker run --rm -i -e "URL=${url}" -e "RATE=${rate}" -e "DURATION=${duration}" \
    -e "IDS=${ids}" "${k6_image}" run --quiet - <<'EOF'
import http from 'k6/http';

const ids = __ENV.IDS.split(',');

export const options = {
  scenarios: {
    views: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE),
      timeUnit: '1s',
      duration: __ENV.DURATION,
      preAllocatedVUs: 50,
    },
  },
  summaryTrendStats: ['p(50)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const id = ids[Math.floor(Math.random() * ids.length)];
  http.post(__ENV.URL.replace('{id}', id), null, { tags: { name: 'views' } });
}

export function handleSummary(data) {
  const d = data.metrics.http_req_duration.values;
  const reqs = data.metrics.http_reqs.values.count;
  const failed = data.metrics.http_req_failed.values.passes;
  return {
    stdout: `api latency p50 ${d['p(50)'].toFixed(1)} ms, p95 ${d['p(95)'].toFixed(1)} ms, ` +
      `p99 ${d['p(99)'].toFixed(1)} ms, max ${d.max.toFixed(1)} ms\n` +
      `requests ${reqs}, not 2xx ${failed}\n`,
  };
}
EOF
  echo "load end $(utc "$(now)")"
}

# stat NAMESPACE METRIC DIMENSION STATISTIC START END: one statistic of a metric over [START, END], one period.
stat() {
  local period=$(($6 - $5))
  period=$(((period + 59) / 60 * 60))
  aws_ cloudwatch get-metric-statistics --namespace "$1" --metric-name "$2" --dimensions "$3" \
    --start-time "$5" --end-time "$6" --period "${period}" --statistics "$4" \
    --query "Datapoints[0].$4" --output text
}

# e2e MINUTES: percentiles of EndToEndLatencyMs and the usage behind the cost per million events, over the last
# MINUTES minutes. Run it a few minutes after a load: CloudWatch needs time to extract the EMF metrics.
e2e() {
  local minutes=${1:-15} end start period dim
  if ! [[ "${minutes}" =~ ^[0-9]+$ ]] || ((minutes < 1)); then
    fail "e2e: MINUTES must be a whole number of at least 1"
  fi
  end=$(now)
  start=$((end - minutes * 60))
  period=$((minutes * 60))
  echo "window $(utc "${start}") to $(utc "${end}")"
  aws_ cloudwatch get-metric-statistics --namespace "${lab}" --metric-name EndToEndLatencyMs \
    --dimensions Name=Function,Value=counter --start-time "${start}" --end-time "${end}" --period "${period}" \
    --extended-statistics p50 p95 p99 --output json |
    jq -r '.Datapoints[0].ExtendedStatistics // empty
      | "end-to-end latency p50 \(.p50) ms, p95 \(.p95) ms, p99 \(.p99) ms"' | grep . ||
    fail "e2e: no EndToEndLatencyMs in the window (no load yet, or CloudWatch has not extracted it)"
  echo "events counted $(stat "${lab}" EndToEndLatencyMs Name=Function,Value=counter SampleCount "${start}" "${end}")"
  echo "duplicates skipped $(stat "${lab}" DuplicatesSkipped Name=Function,Value=counter Sum "${start}" "${end}")"
  echo "api requests $(stat AWS/ApiGateway Count Name=ApiName,Value="${table}" Sum "${start}" "${end}")"
  dim=Name=FunctionName,Value=${lab}-counter
  echo "counter invocations $(stat AWS/Lambda Invocations "${dim}" Sum "${start}" "${end}")"
  echo "counter duration average $(stat AWS/Lambda Duration "${dim}" Average "${start}" "${end}") ms"
  dim=Name=QueueName,Value=${table}
  echo "sqs messages sent $(stat AWS/SQS NumberOfMessagesSent "${dim}" Sum "${start}" "${end}")"
  echo "sqs empty receives $(stat AWS/SQS NumberOfEmptyReceives "${dim}" Sum "${start}" "${end}")"
  echo "dynamodb write units $(stat AWS/DynamoDB ConsumedWriteCapacityUnits Name=TableName,Value="${table}" Sum \
    "${start}" "${end}")"
}

# views VIDEO: the counter of the video, 0 when it has none yet.
views() {
  local n
  n=$(aws_ dynamodb get-item --table-name "${table}" --key "{\"pk\":{\"S\":\"video#$1\"}}" \
    --query 'Item.views.N' --output text)
  [[ "${n}" =~ ^[0-9]+$ ]] && echo "${n}" || echo 0
}

# skipped SINCE ID...: the first id among ID... of a message the counter logged as a skipped duplicate after SINCE (ms).
skipped() {
  local since=$1
  shift
  aws_ logs filter-log-events --log-group-name "/aws/lambda/${lab}-counter" --start-time "${since}" \
    --query 'events[].message' --output json |
    jq -r --args '[.[] | fromjson? | objects | select(.msg == "duplicate view skipped") | .message_id
      | select(IN($ARGS.positional[]))] | first // empty' "$@"
}

# duplicate: sends the same view twice, same body and same event_id, as a redelivery would, and checks it counts once.
# It waits on these two messages only, never on the whole queue, which may hold the messages of other tests.
duplicate() {
  local queue video event visibility since deadline id ids=() n copy=
  queue=$(aws_ sqs get-queue-url --queue-name "${table}" --query QueueUrl --output text) || fail "no queue ${table}"
  # A copy that hits a transaction conflict goes back to the queue and comes again after the visibility timeout.
  visibility=$(aws_ sqs get-queue-attributes --queue-url "${queue}" --attribute-names VisibilityTimeout \
    --query Attributes.VisibilityTimeout --output text)
  [[ "${visibility}" =~ ^[0-9]+$ ]] || fail "duplicate: no visibility timeout on queue ${table}"
  video=$(new_id)
  event="duplicate-test-$(new_id)"
  since=$(($(now) * 1000))
  for _ in 1 2; do
    id=$(aws_ sqs send-message --queue-url "${queue}" --message-body "{\"video_id\":\"${video}\"}" \
      --message-attributes "event_id={DataType=String,StringValue=${event}}" --query MessageId --output text) ||
      fail "duplicate: send-message"
    ids+=("${id}")
  done
  echo "sent 2 messages ${ids[*]}, event_id ${event}, video ${video}, at $(utc "$(now)")"
  deadline=$(($(now) + visibility + limit))
  while :; do
    n=$(views "${video}")
    ((n > 1)) && break
    if ((n == 1)); then
      copy=$(skipped "${since}" "${ids[@]}")
      [[ -n "${copy}" ]] && break
    fi
    (($(now) < deadline)) ||
      fail "duplicate: no outcome after $((visibility + limit)) s: ${n} views of ${video}, no copy logged as skipped"
    sleep "${poll}"
  done
  echo "views of video ${video}: ${n} (expected 1)${copy:+, message ${copy} skipped as a duplicate} at $(utc "$(now)")"
  [[ "${n}" == 1 ]] || fail "duplicate: the same event_id counted ${n} times"
}

# outcome KEY SINCE: detail-type and error of the transcode event of KEY published after SINCE (ms), tab-separated.
outcome() {
  aws_ logs filter-log-events --log-group-name "/aws/events/${lab}-transcode" --start-time "$2" \
    --query 'events[].message' --output json |
    jq -r --arg k "$1" '.[] | fromjson | select(.detail.source_key == $k)
      | [."detail-type", (.time | fromdateiso8601 | tostring), (.detail.error // "")] | @tsv' | head -n 1
}

# transcode: uploads one valid and one invalid object and waits for the event of each; prints the outcome and the time
# from the upload to the event (the event time has a one-second resolution).
transcode() {
  local bucket valid invalid key start since deadline line type at error status=0
  bucket="${lab}-uploads-${SVP_AWS_STG_ACCOUNT_ID}-${region}"
  # Global, so the exit trap still sees it once this function has returned.
  upload_file=$(mktemp)
  trap 'rm -f "${upload_file}"' EXIT
  head -c 1024 /dev/urandom >"${upload_file}"
  valid="uploads/$(new_id).mp4"
  invalid="uploads/$(new_id).txt"
  start=$(now)
  since=$((start * 1000))
  for key in "${valid}" "${invalid}"; do
    aws_ s3api put-object --bucket "${bucket}" --key "${key}" --body "${upload_file}" --query ETag --output text >/dev/null
  done
  echo "uploaded ${valid} and ${invalid} at $(utc "${start}")"
  for key in "${valid}" "${invalid}"; do
    deadline=$(($(now) + limit))
    until line=$(outcome "${key}" "${since}") && [[ -n "${line}" ]]; do
      (($(now) < deadline)) || fail "transcode: no event for ${key} after ${limit} s"
      sleep "${poll}"
    done
    IFS=$'\t' read -r type at error <<<"${line}"
    echo "${key}: ${type} ${error:+(${error}) }after $((${at%.*} - start)) s"
  done
  [[ "$(outcome "${valid}" "${since}" | cut -f1)" == transcode.completed ]] || status=1
  [[ "$(outcome "${invalid}" "${since}" | cut -f1)" == transcode.failed ]] || status=1
  ((status == 0)) || fail "transcode: expected transcode.completed for .mp4 and transcode.failed for .txt"
}

main() {
  local command=${1:-}
  shift || true
  case "${command}" in
    load) load "$@" ;;
    e2e | duplicate | transcode)
      check_account
      "${command}" "$@"
      ;;
    *) fail "usage: SVP_AWS_STG_ACCOUNT_ID=<id> $0 load URL [RATE] [DURATION] | e2e [MINUTES] | duplicate | transcode" ;;
  esac
}

main "$@"
