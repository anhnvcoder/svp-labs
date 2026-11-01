#!/usr/bin/env bash
# multi.sh BACKEND: which vuln bundle Kyverno and cosign read when one image carries several, and how long a
# verification takes as their number grows. GHCR keeps only what the workflow leaves there (after prune, one vuln
# bundle), so this runs on a copy: the release index of bundle-spike and the real keyless bundles the workflow pushed
# for it (signature, provenance, the vuln bundles of build and of both rescans: the two that prune took out of the
# referrer list are still in the package, untagged, and are fetched by digest), copied into a temporary registry that
# only the tool containers reach (they join its network namespace; nothing is published). The bundles are not
# re-signed: each copy is the bundle the workflow wrote, under a manifest that differs at most by one annotation
# (spike.copy), which changes the manifest's digest. Nothing is signed here. registry:3 answers the referrers API and
# lists referrers in the order they were pushed; GHCR has no referrers API, and the fallback tag index that cosign
# writes there is sorted by digest. A copy pushed last whose digest sorts after every other is last in both orders.
#
# Cases, each printing the referrer list in the order the registry returns it, what Kyverno read (policy.sh's policy
# with show.yaml appended), whether a policy whose maxAttestationAge admits only the newest vuln bundle passes, how
# many vuln envelopes cosign verify-attestation returns, and the time of a Kyverno CLI run of the policy:
#   ordered    the three vuln bundles as the workflow pushed them, oldest first (their digests also sort that way)
#   reversed   ordered, plus the oldest vuln bundle once more, pushed last, under a manifest whose digest sorts after
#              every other
#   pad-N      reversed, plus copies of the newest vuln bundle pushed after it, up to N vuln bundles (N = 10, 30)
# BACKEND is a clone of svp-backend (policy.sh renders its chart svp-policy). Needs Docker, helm, jq; reads GHCR
# anonymously (package bundle-spike is public).
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: multi.sh BACKEND" >&2; exit 2; }
backend=$(cd "$1" && pwd)

d() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }
COSIGN=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8
ORAS=ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb
KYVERNO=${KYVERNO:-ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a}
REGISTRY=docker.io/library/registry:3@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3
SRC=ghcr.io/anhnvcoder/svp-labs/bundle-spike
DST=localhost:5000/anhnvcoder/svp-labs/bundle-spike
# Run 41311972410 (build): the release index and its bundles; runs 41312225051, 41312503891 (rescan): one vuln each.
RELEASE=sha256:1f6154f1d726771265309311d0114383cd086c4f27eb9dafb40fb0a8de15f866
SIGNATURE=sha256:0fc372d37509473b6041f0ce83ff151fbe1fd60943a3e9b1092862348356b9df
PROVENANCE=sha256:076edcd7485bb1c1b5172cb9b72cdeffdd4ad9323a4f5d5d715d3c3d3c76e49c
VULN_BUILD=sha256:24758370dedca3f5920354545a55adaa3636ea577aaaaf645dbaa552a633e295   # scanFinishedOn 13:36:10Z
VULN_RESCAN1=sha256:627ba7675922bbb091c51e4d5413cbd41ab245f19e52999ac0870f5788dead97 # scanFinishedOn 13:38:27Z
VULN_RESCAN2=sha256:dee76329e2b8ef353b738bd4bfc0b8ebde836c3f62a3d6d9aec9c4b017ad95ea # scanFinishedOn 13:42:00Z
BUNDLE_TYPE=application/vnd.dev.sigstore.bundle.v0.3+json
ISS=https://token.actions.githubusercontent.com
ID=https://github.com/anhnvcoder/svp-labs/.github/workflows/bundle-spike.yml@refs/heads/main

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
reg=bundle-spike-reg-$$
cleanup() {
  d rm -f "$reg" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

d run -d --name "$reg" "$REGISTRY" >/dev/null
net=(--network "container:$reg")
oras() { d run --rm "${net[@]}" -v "$work:/w" -w /w "$ORAS" "$@"; }
cosign() { d run --rm "${net[@]}" "$COSIGN" "$@"; }
for _ in $(seq 1 30); do
  oras repo ls --plain-http localhost:5000 >/dev/null 2>&1 && break
  sleep 1
done

# The policy for the copy: the chart's own, with the image prefix of source labs moved to the copy's registry (the
# glob, and the escaped prefix in check 1's regular expression); the identity stays the workflow's.
policy() { # policy OUT [MAX_AGE]
  "$here/policy.sh" "$backend" "$work/rendered.yaml" ${2:+"$2"} >/dev/null
  sed -e 's#ghcr\\.io/anhnvcoder/svp-labs/#localhost:5000/anhnvcoder/svp-labs/#g' \
    -e 's#ghcr.io/anhnvcoder/svp-labs/#localhost:5000/anhnvcoder/svp-labs/#g' "$work/rendered.yaml" >"$work/$1"
}
policy policy.yaml
cat "$work/policy.yaml" "$here/show.yaml" >"$work/policy-show.yaml"
cat >"$work/pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: release
  namespace: svp
spec:
  containers:
    - name: c
      image: $DST@$RELEASE
EOF

oras copy --to-plain-http "$SRC@$RELEASE" "$DST:release" >/dev/null
# Each bundle by its digest: its manifest names the release as subject, so the registry lists it as a referrer.
for b in "$SIGNATURE" "$PROVENANCE" "$VULN_BUILD" "$VULN_RESCAN1" "$VULN_RESCAN2"; do
  oras copy --to-plain-http "$SRC@$b" "$DST:b-${b:7:12}" >/dev/null
done

# copy_bundle DIGEST LABEL TEST: pushes the bundle manifest DIGEST again with annotation spike.copy=LABEL-<n>, for the
# first n whose new digest passes TEST (a bash test on $new); prints the new digest. A new LABEL gives a new copy.
copy_bundle() {
  local src=$1 label=$2 test=$3 n new
  oras manifest fetch --plain-http "$DST@$src" >"$work/m.json"
  for n in $(seq 1 5000); do
    jq -c --arg n "$label-$n" '.annotations["spike.copy"] = $n' "$work/m.json" >"$work/c.json"
    new=sha256:$(shasum -a 256 "$work/c.json" | cut -d' ' -f1)
    if eval "$test"; then
      oras manifest push --plain-http --media-type application/vnd.oci.image.manifest.v1+json "$DST:c-${new:7:12}" c.json >/dev/null
      echo "$new"
      return
    fi
  done
  echo "FAIL  no copy of $src passes $test" >&2
  return 1
}

kyv() { d run --rm "${net[@]}" -v "$work:/w:ro" -w /w "$KYVERNO" apply "$1" --resource pod.yaml 2>&1 | sed -n '/^Applying/,$p' | grep -v '^Applying\|^$' || true; }

report() { # report CASE
  local start end age vulns
  echo "=== $1"
  echo "referrers, in the order the registry returns them:"
  oras discover --plain-http --format json --artifact-type "$BUNDLE_TYPE" "$DST@$RELEASE" |
    jq -r '(.referrers // .manifests // [])[] | "  \(.digest) \(.annotations["dev.sigstore.bundle.predicateType"])\(if .annotations["spike.copy"] then " (copy)" else "" end)"'
  echo "kyverno, what checks 4-10 read:"
  kyv policy-show.yaml | sed 's/^/  /'
  # Halfway between the scans of 13:38:27Z and 13:42:00Z: only the newest vuln bundle is younger.
  age=$(($(date -u +%s) - $(date -u -j -f %Y-%m-%dT%H:%M:%SZ 2026-11-01T13:40:14Z +%s)))
  policy policy-age.yaml "${age}s"
  echo "kyverno, maxAttestationAge ${age}s (only the newest vuln bundle within it):"
  kyv policy-age.yaml | sed 's/^/  /'
  vulns=$(cosign verify-attestation --allow-http-registry --type vuln --certificate-identity "$ID" \
    --certificate-oidc-issuer "$ISS" "$DST@$RELEASE" 2>/dev/null |
    jq -r '.payload | @base64d | fromjson | .predicate.metadata.scanFinishedOn' | sort | uniq -c | tr -s ' ' | paste -sd, -) || vulns="(failed)"
  echo "cosign verify-attestation --type vuln, envelopes per scanFinishedOn: $vulns"
  start=$(date +%s)
  kyv policy.yaml | sed 's/^/  /'
  end=$(date +%s)
  echo "kyverno apply policy.yaml: $((end - start)) s"
}

# Baseline: the same CLI run on a pod whose image no glob matches (check 1 refuses it, no registry is asked).
sed "s#image: $DST@#image: localhost:5000/other@#" "$work/pod.yaml" >"$work/pod-other.yaml"
start=$(date +%s)
d run --rm "${net[@]}" -v "$work:/w:ro" -w /w "$KYVERNO" apply policy.yaml --resource pod-other.yaml >/dev/null 2>&1 || true
echo "baseline (no image verified): $(($(date +%s) - start)) s"

report ordered
last=$(oras discover --plain-http --format json --artifact-type "$BUNDLE_TYPE" "$DST@$RELEASE" |
  jq -r '[(.referrers // .manifests // [])[].digest] | sort | last')
copy=$(copy_bundle "$VULN_BUILD" reversed "[[ \$new > $last ]]")
echo "copy of the vuln bundle of 13:36:10Z: $copy"
report reversed
for n in 10 30; do
  have=$(oras discover --plain-http --format json --artifact-type "$BUNDLE_TYPE" "$DST@$RELEASE" |
    jq '[(.referrers // .manifests // [])[] | select(.annotations["dev.sigstore.bundle.predicateType"] == "https://cosign.sigstore.dev/attestation/vuln/v1")] | length')
  while [ "$have" -lt "$n" ]; do
    copy_bundle "$VULN_RESCAN2" "pad-$have" true >/dev/null
    have=$((have + 1))
  done
  report "pad-$n"
done
