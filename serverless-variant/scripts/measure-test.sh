#!/usr/bin/env bash
# Runs on: any machine with jq, without network or credentials: fake aws, docker and uuidgen first on PATH answer
# for AWS, k6 and the ids. Checks measure.sh: the numbers each subcommand prints, the checks that fail it, the pinned
# k6 image, and the profile and region of every aws call.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/measure.sh"
readonly script
tmp="$(mktemp -d)"
readonly tmp
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Every command below finds the fakes first; nothing reaches AWS or a registry.
mkdir "${tmp}/bin"
export PATH="${tmp}/bin:${PATH}"

cat >"${tmp}/bin/uuidgen" <<'EOF'
#!/usr/bin/env bash
# Numbered ids, so each run knows the keys measure.sh makes.
n=$(($(cat "${FAKE_IDS}" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${FAKE_IDS}"
printf '0000000%d-AAAA-4BBB-8CCC-DDDDDDDDDDDD\n' "${n}"
EOF

cat >"${tmp}/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Logs the arguments and the k6 script on stdin, and prints the summary k6 would.
{ printf 'ARGS'; printf ' %s' "$@"; echo; } >>"${FAKE_LOG}"
cat >"${FAKE_STDIN}"
echo "api latency p50 41.0 ms, p95 88.5 ms, p99 120.3 ms, max 300.0 ms"
EOF

cat >"${tmp}/bin/aws" <<'EOF'
#!/usr/bin/env bash
# Logs each call; answers the calls of measure.sh from the FAKE_* variables of the test.
echo "$*" >>"${FAKE_LOG}"
arg() {
  local want=$1
  shift
  while (($#)); do
    if [[ "$1" == "${want}" ]]; then
      echo "$2"
      return
    fi
    shift
  done
}
case "$5 $6" in
  "sts get-caller-identity") echo "${FAKE_ACCOUNT}" ;;
  "cloudwatch get-metric-statistics")
    if [[ "$*" == *"--extended-statistics"* ]]; then
      echo '{"Datapoints":[{"ExtendedStatistics":{"p50":812.0,"p95":1540.5,"p99":2210.0}}]}'
    else
      case "$(arg --metric-name "$@")" in
        Duration) echo 23.4 ;;
        *) echo 600.0 ;;
      esac
    fi
    ;;
  "sqs get-queue-url") echo "https://sqs.ap-southeast-1.amazonaws.com/000000000000/svp-lab-sls-views" ;;
  "sqs send-message") echo "msg-$(grep -c 'sqs send-message' "${FAKE_LOG}")" ;;
  "sqs get-queue-attributes") echo "${FAKE_VISIBILITY}" ;;
  "dynamodb get-item") echo "${FAKE_VIEWS}" ;;
  "s3api put-object") echo '"etag"' ;;
  "logs filter-log-events")
    if [[ "$(arg --log-group-name "$@")" == /aws/lambda/svp-lab-sls-counter ]]; then
      # What the counter writes: platform lines, EMF, a record of another test, and the copy FAKE_SKIP_ID skipped.
      jq -n -c --arg id "${FAKE_SKIP_ID}" '["START RequestId: r1 Version: $LATEST", "42",
        ({"Function": "counter", "DuplicatesSkipped": 1} | tojson),
        ({msg: "record not counted", message_id: "msg-2"} | tojson)]
        + if $id == "" then [] else [{msg: "duplicate view skipped", message_id: $id} | tojson] end'
      exit
    fi
    # One event per key uploaded so far: completed for .mp4, failed with the function's message otherwise.
    grep -o 'put-object .*--key uploads/[^ ]*' "${FAKE_LOG}" | sed 's/.*--key //' | sort -u |
      jq -R -s -c --arg t "${FAKE_EVENT_TIME}" 'split("\n") | map(select(. != "")) | map(
        if endswith(".mp4") then {"detail-type": "transcode.completed", time: $t, detail: {source_key: .}}
        else {"detail-type": "transcode.failed", time: $t, detail: {source_key: ., error: "invalid input: ext"}} end
        | tojson)'
    ;;
  *)
    echo "unexpected call: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "${tmp}/bin/uuidgen" "${tmp}/bin/docker" "${tmp}/bin/aws"
[[ "$(command -v aws)" == "${tmp}/bin/aws" ]] || fail "the fake aws is not first on PATH"
[[ "$(command -v docker)" == "${tmp}/bin/docker" ]] || fail "the fake docker is not first on PATH"

# run ARGS...: runs measure.sh with the fakes; sets out (stdout and stderr) and rc.
run() {
  : >"${tmp}/log"
  rm -f "${tmp}/ids"
  set +e
  out="$(SVP_AWS_STG_ACCOUNT_ID="${ACCOUNT-000000000000}" FAKE_ACCOUNT=000000000000 FAKE_VIEWS="${VIEWS-1}" \
    FAKE_EVENT_TIME="${EVENT_TIME-2030-01-01T00:00:07Z}" FAKE_LOG="${tmp}/log" FAKE_IDS="${tmp}/ids" \
    FAKE_STDIN="${tmp}/stdin" FAKE_SKIP_ID="${SKIP_ID-msg-2}" FAKE_VISIBILITY=0 SVP_SLS_POLL=0 \
    SVP_SLS_LIMIT="${LIMIT-5}" AWS_PROFILE=leak AWS_ACCESS_KEY_ID=leak \
    bash "${script}" "$@" 2>&1)"
  rc=$?
  set -e
}

every_call_scoped() {
  ! grep -v -e '^ARGS' "${tmp}/log" | grep -v -- '^--profile anhnv-stg --region ap-southeast-1 ' ||
    fail "$1: every aws call must name the profile and the region: $(cat "${tmp}/log")"
}

url='https://abc123.execute-api.ap-southeast-1.amazonaws.com/lab/videos/{id}/views'

run load "${url}" 20 1m
((rc == 0)) || fail "load: rc ${rc}: ${out}"
[[ "${out}" == *"api latency p50 41.0 ms, p95 88.5 ms, p99 120.3 ms"* ]] || fail "load: no latency line: ${out}"
[[ "${out}" =~ load\ start\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ rate\ 20/s ]] || fail "load: no UTC start: ${out}"
grep -q ' grafana/k6:[0-9.]*@sha256:[0-9a-f]\{64\} run --quiet -$' "${tmp}/log" ||
  fail "load: k6 must run from its image pinned by digest: $(cat "${tmp}/log")"
grep -q " -e URL=${url} -e RATE=20 -e DURATION=1m " "${tmp}/log" || fail "load: URL, RATE, DURATION: $(cat "${tmp}/log")"
ids=$(sed -n 's/.* -e IDS=\([^ ]*\) .*/\1/p' "${tmp}/log")
[[ "$(tr ',' '\n' <<<"${ids}" | sort -u | wc -l | tr -d ' ')" == 10 ]] || fail "load: ten distinct video ids: ${ids}"
[[ "${ids}" == "${ids,,}" ]] || fail "load: video ids must be lower case: ${ids}"
! grep -q -e ' -e AWS_' -e '/\.aws' "${tmp}/log" || fail "load: no AWS variable or file reaches the container: $(cat "${tmp}/log")"
grep -q "executor: 'constant-arrival-rate'" "${tmp}/stdin" || fail "load: k6 holds a constant arrival rate"

run load "${url}" 51
((rc == 1)) && [[ "${out}" == *"RATE must be 1 to 50"* ]] || fail "load: a rate above the throttle is refused: ${out}"
run load 'https://example.invalid/views'
((rc == 1)) && [[ "${out}" == *"view_url output"* ]] || fail "load: a URL without {id} is refused: ${out}"
! grep -q '^ARGS' "${tmp}/log" || fail "load: nothing runs on a usage error"

run e2e 15
((rc == 0)) || fail "e2e: rc ${rc}: ${out}"
[[ "${out}" == *"end-to-end latency p50 812.0 ms, p95 1540.5 ms, p99 2210.0 ms"* ]] || fail "e2e: percentiles: ${out}"
[[ "${out}" == *"counter duration average 23.4 ms"* && "${out}" == *"dynamodb write units 600.0"* ]] ||
  fail "e2e: usage lines: ${out}"
[[ "${out}" =~ window\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ to ]] || fail "e2e: no UTC window: ${out}"
grep -q -- '--namespace svp-lab-sls --metric-name EndToEndLatencyMs --dimensions Name=Function,Value=counter ' \
  "${tmp}/log" || fail "e2e: the EMF metric of the contract: $(cat "${tmp}/log")"
grep -q -- '--period 900 ' "${tmp}/log" || fail "e2e: one period covers the window: $(cat "${tmp}/log")"
every_call_scoped e2e

run duplicate
((rc == 0)) || fail "duplicate: rc ${rc}: ${out}"
[[ "${out}" == *"views of video 00000001-aaaa-4bbb-8ccc-dddddddddddd: 1 (expected 1), message msg-2 skipped"* ]] ||
  fail "duplicate: ${out}"
grep -q -- 'logs filter-log-events --log-group-name /aws/lambda/svp-lab-sls-counter ' "${tmp}/log" ||
  fail "duplicate: the skipped copy is read from the counter's log group: $(cat "${tmp}/log")"
! grep -q 'ApproximateNumberOf' "${tmp}/log" || fail "duplicate: waits on its own messages, not on the queue's backlog"
[[ "$(grep -c 'sqs send-message' "${tmp}/log")" == 2 ]] || fail "duplicate: two sends: $(cat "${tmp}/log")"
[[ "$(grep 'sqs send-message' "${tmp}/log" | sed 's/.*--message-body //' | sort -u | wc -l | tr -d ' ')" == 1 ]] ||
  fail "duplicate: both sends carry the same body and event_id: $(cat "${tmp}/log")"
grep -q 'event_id={DataType=String,StringValue=duplicate-test-' "${tmp}/log" || fail "duplicate: event_id attribute"
every_call_scoped duplicate

VIEWS=2 run duplicate
((rc == 1)) && [[ "${out}" == *"counted 2 times"* ]] || fail "duplicate: two views must fail: ${out}"
# A copy of another test skipped meanwhile is not one of these two messages.
SKIP_ID=msg-9 LIMIT=1 run duplicate
((rc == 1)) && [[ "${out}" == *"no outcome after 1 s"* && "${out}" != *"counted"* ]] ||
  fail "duplicate: without its own copy skipped, it times out and says so: ${out}"

EVENT_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" run transcode
((rc == 0)) || fail "transcode: rc ${rc}: ${out}"
[[ "${out}" =~ uploads/00000001-aaaa-4bbb-8ccc-dddddddddddd\.mp4:\ transcode\.completed\ after\ -?[0-9]+\ s ]] ||
  fail "transcode: the .mp4 completes: ${out}"
[[ "${out}" =~ uploads/00000002-aaaa-4bbb-8ccc-dddddddddddd\.txt:\ transcode\.failed\ \(invalid\ input:\ ext\)\ after ]] ||
  fail "transcode: the .txt fails with the function's message: ${out}"
grep -q -- '--bucket svp-lab-sls-uploads-000000000000-ap-southeast-1 --key uploads/' "${tmp}/log" ||
  fail "transcode: uploads go under uploads/ of the lab bucket: $(cat "${tmp}/log")"
every_call_scoped transcode

ACCOUNT=111111111111 run duplicate
((rc == 1)) && [[ "${out}" == *"not to SVP_AWS_STG_ACCOUNT_ID"* ]] || fail "another account must stop the run: ${out}"
! grep -q 'send-message' "${tmp}/log" || fail "nothing is sent to another account"

ACCOUNT="" run e2e
((rc == 1)) && [[ "${out}" == *"export SVP_AWS_STG_ACCOUNT_ID"* ]] || fail "a missing account id must stop the run: ${out}"
[[ ! -s "${tmp}/log" ]] || fail "no aws call runs without the account id: $(cat "${tmp}/log")"

echo "ok: measure.sh"
