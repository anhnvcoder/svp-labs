#!/usr/bin/env bash
# vuln-predicate.sh OUT INDEX IMAGE: writes to OUT a vuln predicate in the shape deploy/ci/vuln-predicate.sh of
# svp-backend writes, for the image index IMAGE whose raw manifest is the file INDEX: invocation, scanner and
# metadata, predicate.scanner.result.platforms exactly [linux/amd64, linux/arm64] in that order, each
# {platform, digest, report}, and metadata.scanFinishedOn the time of this run (RFC 3339 UTC). The image is FROM
# scratch, so nothing is scanned: each report is an empty trivy report (SchemaVersion 2, no Results), which is what
# trivy writes for an image without packages. What the spike tests is how the policy and cosign read the attestation,
# not the scan. Run in the workflow (GITHUB_* name the run); on a machine each of those reads "local".
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: vuln-predicate.sh OUT INDEX IMAGE" >&2; exit 2; }
out=$1 index=$2 image=$3

digest_of() {
  jq -r --arg a "$1" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a)]
    | if length == 1 then .[0].digest else empty end' "$index"
}
amd64=$(digest_of amd64)
arm64=$(digest_of arm64)
for d in "$amd64" "$arm64"; do
  [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FAIL  $index is not an index of one linux/amd64 and one linux/arm64 manifest" >&2; exit 2; }
done

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
server=${GITHUB_SERVER_URL:-}
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="$server/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}"
  event=$GITHUB_RUN_ID
  builder="$server/${GITHUB_WORKFLOW_REF:-}"
else
  run_url=local event=local builder=local
fi

jq -n --arg uri "$run_url" --arg event "$event" --arg builder "$builder" --arg now "$now" \
  --arg image "$image" --arg amd64 "$amd64" --arg arm64 "$arm64" '
  def report($d): {SchemaVersion: 2, ArtifactName: "\($image)@\($d)", ArtifactType: "container_image", Results: []};
  {
    invocation: {uri: $uri, event_id: $event, "builder.id": $builder, parameters: null},
    scanner: {
      uri: "pkg:github/aquasecurity/trivy",
      version: "none (FROM scratch, nothing scanned)",
      db: {uri: "none", version: $now},
      result: {platforms: [
        {platform: "linux/amd64", digest: $amd64, report: report($amd64)},
        {platform: "linux/arm64", digest: $arm64, report: report($arm64)}
      ]}
    },
    metadata: {scanStartedOn: $now, scanFinishedOn: $now}
  }' >"$out"
echo "ok    vuln predicate of $image (scanFinishedOn $now) written to $out"
