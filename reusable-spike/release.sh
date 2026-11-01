#!/usr/bin/env bash
# release.sh PATH CODE_ROOT: stands in for the backend's deploy/ci/*.sh when they run from a reusable workflow or a
# composite action instead of a pinned checkout. Builds the image of CODE_ROOT (the caller's tree), pushes it, signs it
# keyless and attests a small vuln predicate, both in the Sigstore bundle format; writes digest to GITHUB_OUTPUT.
# PATH is reusable or composite: it goes into a label, so the two ways give two digests under one package.
#
# It prints where it runs from (script_root: the tree this file was read from) and what it builds (code_root), with
# the commit of each when they are git checkouts, so the run log shows which copy of the scripts ran.
#
# Needs cosign on PATH, `docker login ghcr.io`, and the id-token permission of the job. Runs in CI only.
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

[ $# -eq 2 ] || fail "usage: release.sh reusable|composite CODE_ROOT"
case $1 in reusable | composite) ;; *) fail "PATH must be reusable or composite, not $1" ;; esac
spike_path=$1
code_root=$(cd "$2" && pwd) || fail "$2 is not a folder"
script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=ghcr.io/anhnvcoder/svp-labs/reusable-spike

commit_of() { git -C "$1" rev-parse --verify HEAD 2>/dev/null || echo "not a git checkout"; }
echo "script_root=$script_root commit=$(commit_of "$script_root")"
echo "code_root=$code_root commit=$(commit_of "$code_root")"
[ -f "$code_root/reusable-spike/image/Dockerfile" ] || fail "$code_root has no reusable-spike/image/Dockerfile"

# BuildKit's own provenance and SBOM stay off: the image is one plain manifest, and what is attached to it is only
# what this script and actions/attest make.
docker buildx build \
  --provenance=false --sbom=false \
  --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
  --label "spike.path=$spike_path" \
  --tag "$image:${GITHUB_SHA::12}-$spike_path" \
  --metadata-file "$RUNNER_TEMP/build-$spike_path.json" \
  --push "$code_root/reusable-spike/image"
digest=$(jq -r '."containerimage.digest"' "$RUNNER_TEMP/build-$spike_path.json")
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail "no image digest in the build metadata: $digest"

# The vuln predicate has the shape cosign parses (CosignVulnPredicate); the image has no OS, so there is no result.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg now "$now" --arg run "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" '{
  invocation: {uri: $run},
  scanner: {uri: "https://github.com/anhnvcoder/svp-labs/tree/main/reusable-spike", version: "spike", result: {}},
  metadata: {scanStartedOn: $now, scanFinishedOn: $now}
}' >"$RUNNER_TEMP/vuln-$spike_path.json"

bundle=(--yes --new-bundle-format=true)
cosign sign "${bundle[@]}" "$image@$digest" || fail "sign $image@$digest"
cosign attest "${bundle[@]}" --type vuln --predicate "$RUNNER_TEMP/vuln-$spike_path.json" "$image@$digest" ||
  fail "attest vuln on $image@$digest"

echo "digest=$digest" >>"$GITHUB_OUTPUT"
echo "image=$image@$digest"
