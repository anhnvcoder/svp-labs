#!/usr/bin/env bash
# Runs on: any machine, without network or credentials: a fake aws first on PATH answers for Reachability Analyzer.
# Checks reachability.sh: the verdict for each expected result, the exit status, the cleanup on every way out and the
# profile and region of every aws call.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/reachability.sh"
readonly script
tmp="$(mktemp -d)"
readonly tmp
trap 'rm -rf "${tmp}"' EXIT

# Every command below finds the fake aws first; nothing reaches AWS.
mkdir "${tmp}/bin"
export PATH="${tmp}/bin:${PATH}"
cat >"${tmp}/bin/aws" <<'EOF'
#!/usr/bin/env bash
# Logs each call; answers the calls of reachability.sh from the FAKE_* variables of the test.
echo "$*" >>"${FAKE_LOG}"
case "$2" in
  create-network-insights-path) echo "nip-0123456789abcdef0" ;;
  start-network-insights-analysis) echo "nia-0123456789abcdef0" ;;
  describe-network-insights-analyses)
    if [[ "$*" == *".Status"* ]]; then
      n=$(($(cat "${FAKE_COUNT}" 2>/dev/null || echo 0) + 1))
      echo "${n}" >"${FAKE_COUNT}"
      if ((n < 2)); then echo running; else echo "${FAKE_STATUS:-succeeded}"; fi
    else
      printf '%s\t%s\n' "${FAKE_FOUND}" "${FAKE_CODES:-}"
    fi
    ;;
  delete-network-insights-analysis | delete-network-insights-path) ;;
  *)
    echo "unexpected call: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "${tmp}/bin/aws"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ "$(command -v aws)" == "${tmp}/bin/aws" ]] || fail "the fake aws is not first on PATH"

# Runs reachability.sh with: expected result, what the fake reports as NetworkPathFound, explanation codes, final
# status. Sets out (stdout and stderr) and rc.
run() {
  : >"${tmp}/log"
  rm -f "${tmp}/count"
  set +e
  out="$(AWS_PROFILE="${PROFILE-anhnv-sso}" FAKE_LOG="${tmp}/log" \
    FAKE_COUNT="${tmp}/count" FAKE_FOUND="$2" FAKE_CODES="$3" FAKE_STATUS="$4" REACHABILITY_POLL_SECONDS=0 \
    bash "${script}" stg-to-prd arn:aws:ec2:ap-southeast-1:000000000000:instance/i-0aaaaaaaaaaaaaaa1 \
    arn:aws:ec2:ap-southeast-1:444444444444:instance/i-0bbbbbbbbbbbbbbb2 80 "$1" 2>&1)"
  rc=$?
  set -e
}

expect_cleanup() {
  local a p
  a="$(grep -n 'delete-network-insights-analysis --network-insights-analysis-id nia-0123456789abcdef0' "${tmp}/log" \
    | cut -d: -f1)" || fail "$1: the analysis is not deleted: $(cat "${tmp}/log")"
  p="$(grep -n 'delete-network-insights-path --network-insights-path-id nip-0123456789abcdef0' "${tmp}/log" \
    | cut -d: -f1)" || fail "$1: the path is not deleted: $(cat "${tmp}/log")"
  ((a < p)) || fail "$1: the path is deleted before its analysis"
}

run unreachable False BLACKHOLE succeeded
((rc == 0)) || fail "expected unreachable, found unreachable: rc ${rc}: ${out}"
[[ "${out}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ path=stg-to-prd\ expected=unreachable\ found=unreachable\ verdict=PASS\ elapsed=[0-9]+s\ explanation=BLACKHOLE$ ]] \
  || fail "unexpected line: ${out}"
[[ "$(cat "${tmp}/count")" == 2 ]] || fail "the status must be read until it leaves running"
! grep -v -- '--profile anhnv-sso --region ap-southeast-1$' "${tmp}/log" \
  || fail "every aws call must name the profile and the region"
grep -q -- '--protocol tcp --destination-port 80 ' "${tmp}/log" || fail "the path must test TCP 80: $(cat "${tmp}/log")"
grep -q 'Key=Lab,Value=multi-account-networking' "${tmp}/log" || fail "the path must carry the Lab tag"
expect_cleanup "PASS"

run reachable False "" succeeded
((rc == 1)) || fail "expected reachable, found unreachable: rc ${rc}, want 1: ${out}"
[[ "${out}" == *"found=unreachable verdict=FAIL "*"explanation=-" ]] || fail "unexpected line: ${out}"
expect_cleanup "FAIL"

run reachable True "" succeeded
((rc == 0)) || fail "expected reachable, found reachable: rc ${rc}: ${out}"
[[ "${out}" == *"found=reachable verdict=PASS "* ]] || fail "unexpected line: ${out}"

run reachable True "" failed
((rc == 1)) || fail "a failed analysis must exit 1: rc ${rc}: ${out}"
[[ "${out}" == *"ended failed"* ]] || fail "a failed analysis must say so: ${out}"
expect_cleanup "failed analysis"

PROFILE="" run unreachable False "" succeeded
((rc == 2)) || fail "no AWS_PROFILE must exit 2: rc ${rc}: ${out}"
[[ ! -s "${tmp}/log" ]] || fail "no aws call may run without AWS_PROFILE: $(cat "${tmp}/log")"

run maybe False "" succeeded
((rc == 2)) || fail "an unknown expected result must exit 2: rc ${rc}: ${out}"
[[ ! -s "${tmp}/log" ]] || fail "no aws call may run on a usage error"

echo "ok: reachability.sh"
