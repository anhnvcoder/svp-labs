#!/usr/bin/env bash
# policy.sh BACKEND OUT [MAX_AGE]: renders the real admission policy of svp-backend (chart deploy/helm/svp-policy of
# the clone BACKEND) to OUT, with build provenance required, for the Kyverno CLI to apply to this spike's pods. The
# chart is copied to a temporary directory and its table of release sources (files/sources.json) gets one more
# source, this repository: prefix ghcr.io/anhnvcoder/svp-labs/, image bundle-spike, signed by
# .github/workflows/bundle-spike.yml on main. Nothing in BACKEND changes. MAX_AGE (a CEL duration, 72h by default
# as in the chart) is the oldest scanFinishedOn the policy admits: a few seconds for the rescan case, so only the
# newest vuln bundle is within it. Needs helm and jq; renders only, reaches no cluster.
set -euo pipefail

[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: policy.sh BACKEND OUT [MAX_AGE]" >&2; exit 2; }
chart=$1/deploy/helm/svp-policy
out=$2
age=${3:-72h}
[ -f "$chart/files/sources.json" ] || { echo "FAIL  $chart is not chart svp-policy (no files/sources.json)" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$chart" "$work/svp-policy"
jq '.sources += [{
  name: "labs",
  repository: "https://github.com/anhnvcoder/svp-labs",
  imagePrefix: "ghcr.io/anhnvcoder/svp-labs/",
  services: ["bundle-spike"],
  drillImages: [],
  issuer: "https://token.actions.githubusercontent.com",
  subject: "https://github.com/anhnvcoder/svp-labs/.github/workflows/bundle-spike.yml@refs/heads/main",
  provenanceRef: "refs/heads/main"
}]' "$chart/files/sources.json" >"$work/svp-policy/files/sources.json"
helm template svp-policy "$work/svp-policy" --set imageVerification.requireProvenance=true \
  --set "imageVerification.maxAttestationAge=$age" >"$out"
echo "ok    svp-policy of $(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "$1") with source labs, requireProvenance true, maxAttestationAge $age: $out"
