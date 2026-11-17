#!/usr/bin/env bash
# Runs on: the learner's machine, as the management account, with trusted access of Reachability Analyzer on.
# Reads one path from its arguments; writes one line (UTC time, path, expected, found, verdict, seconds, explanation
# codes) and exits 1 when the path is not as expected. It deletes the path and the analysis it creates on exit.
set -euo pipefail

readonly REGION="ap-southeast-1"
readonly LAB="multi-account-networking"
readonly POLL_SECONDS="${REACHABILITY_POLL_SECONDS:-5}"
readonly MAX_POLLS=60

path_id=""
analysis_id=""

usage() {
  echo "usage: AWS_PROFILE=<management profile> $0 <name> <source-arn> <destination-arn> <tcp-port>" \
    "reachable|unreachable" >&2
  exit 2
}

err() {
  echo "$*" >&2
}

ec2() {
  aws ec2 "$@" --profile "${AWS_PROFILE}" --region "${REGION}"
}

tags() {
  echo "ResourceType=$1,Tags=[{Key=Project,Value=svp},{Key=Lab,Value=${LAB}},{Key=Name,Value=svp-lab-net-$2}]"
}

cleanup() {
  if [[ -n "${analysis_id}" ]]; then
    ec2 delete-network-insights-analysis --network-insights-analysis-id "${analysis_id}" >/dev/null \
      || err "warning: the analysis ${analysis_id} is left; delete it by hand"
  fi
  if [[ -n "${path_id}" ]]; then
    ec2 delete-network-insights-path --network-insights-path-id "${path_id}" >/dev/null \
      || err "warning: the path ${path_id} is left; delete it by hand"
  fi
}

main() {
  [[ $# -eq 5 ]] || usage
  local name="$1" source="$2" destination="$3" port="$4" expect="$5"
  [[ "${name}" =~ ^[a-z0-9-]+$ && "${port}" =~ ^[0-9]+$ ]] || usage
  [[ "${expect}" == "reachable" || "${expect}" == "unreachable" ]] || usage
  if [[ -z "${AWS_PROFILE:-}" ]]; then
    err "AWS_PROFILE must name the profile of the management account"
    exit 2
  fi

  trap cleanup EXIT
  local start="${SECONDS}"
  path_id="$(ec2 create-network-insights-path --source "${source}" --destination "${destination}" \
    --protocol tcp --destination-port "${port}" --tag-specifications "$(tags network-insights-path "${name}")" \
    --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)"
  analysis_id="$(ec2 start-network-insights-analysis --network-insights-path-id "${path_id}" \
    --tag-specifications "$(tags network-insights-analysis "${name}")" \
    --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text)"

  local status="running" polls=0
  while [[ "${status}" == "running" ]]; do
    if ((polls >= MAX_POLLS)); then
      err "the analysis ${analysis_id} is still running after ${polls} reads"
      exit 1
    fi
    sleep "${POLL_SECONDS}"
    polls=$((polls + 1))
    status="$(ec2 describe-network-insights-analyses --network-insights-analysis-ids "${analysis_id}" \
      --query 'NetworkInsightsAnalyses[0].Status' --output text)"
  done
  if [[ "${status}" != "succeeded" ]]; then
    err "the analysis ${analysis_id} ended ${status}"
    exit 1
  fi

  # Explanations say why no path was found (the component and the reason code), so a blackhole route shows up by name.
  # The backticks are JMESPath literals for the AWS CLI, not shell.
  local found codes
  # shellcheck disable=SC2016
  read -r found codes < <(ec2 describe-network-insights-analyses --network-insights-analysis-ids "${analysis_id}" \
    --query 'NetworkInsightsAnalyses[0].[NetworkPathFound, join(`","`, Explanations[].ExplanationCode || `[]`)]' \
    --output text)
  local got="unreachable"
  if [[ "$(printf '%s' "${found}" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
    got="reachable"
  fi
  local verdict="PASS"
  if [[ "${got}" != "${expect}" ]]; then
    verdict="FAIL"
  fi

  printf '%s path=%s expected=%s found=%s verdict=%s elapsed=%ss explanation=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${name}" "${expect}" "${got}" "${verdict}" "$((SECONDS - start))" "${codes:--}"
  [[ "${verdict}" == "PASS" ]]
}

main "$@"
