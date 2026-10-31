#!/usr/bin/env bash
# Mixed image: what Kyverno's ImageValidatingPolicy does with one image that carries cosign's old format (.sig and
# .att tags) and also a Sigstore bundle as an OCI 1.1 referrer, which is what a release would look like if only its
# provenance moved to actions/attest. Everything runs against a temporary registry that only the tool containers reach
# (they join its network namespace; nothing is published), removed on exit with the work directory. Needs Docker
# (and jq on the machine for mode mixed); images are pulled anonymously, nothing is signed with a GitHub or Sigstore login: what is signed here is
# signed with a throwaway key made for the run, without a transparency log, so nothing leaves the machine.
#
# Usage: ./mixed.sh MODE (KYVERNO=<kyverno-cli image> to run another CLI than the one the lab pins)
#   legacy  control: a copy of a real release of svp-backend (gateway, keyless signature, vuln and provenance in the
#           old format, with their Rekor proofs) and nothing else; policy-mixed.yaml must admit it.
#   mixed   the same copy plus one bundle referrer: the bundle actions/attest wrote for the spike image (a valid
#           Sigstore bundle, but for another digest and another identity). Whether Kyverno still reads the old .sig
#           once a bundle referrer exists.
#   moved   the same copy plus one bundle referrer that is valid for it: a provenance attestation of this very digest,
#           signed with the throwaway key, which policy-mixed.yaml accepts beside the identity of svp-backend. A
#           release whose provenance alone moved to a bundle: which check refuses it, the old .att (vuln) still there.
#   keybundle  a copy of the spike image with no .sig at all and two bundle referrers, provenance and vuln, signed
#           with the throwaway key; policy-keybundle.yaml. Whether bundles alone pass verifyImageSignatures, and
#           whether two bundles of two predicate types are each found by their own attestation.
set -euo pipefail

mode=${1:-}
case $mode in
  legacy | mixed | moved | keybundle) ;;
  *) echo "usage: $0 legacy|mixed|moved|keybundle" >&2; exit 2 ;;
esac

d() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }
COSIGN=ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8
ORAS=ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb
# The CLI of the Kyverno the lab runs (base/kyverno.yaml of svp-gitops pins every Kyverno image at v1.19.1).
KYVERNO=${KYVERNO:-ghcr.io/kyverno/kyverno-cli:v1.19.1@sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a}
REGISTRY=docker.io/library/registry:3@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3
# The release of gateway in stg when this was written (envs/stg/images/gateway.yaml of svp-gitops).
RELEASE=ghcr.io/anhnvcoder/svp-backend/gateway
RELEASE_DIGEST=sha256:15c32ac48a6fd3b67ebe7f0e9549eb9c7accfafdbdd93ece96a273142e634e3c
SPIKE=ghcr.io/anhnvcoder/svp-labs/attest-spike@sha256:6ef501da57a3f43709b43d4cf0619a3753edcfdb10d9c2e1119567401654f8a7
SPIKE_BUNDLE=ghcr.io/anhnvcoder/svp-labs/attest-spike@sha256:a0055e311652b4ce639b36674e3ba16a89575b380c1dfb1237f9904d1c1aa46b

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
reg=attest-spike-reg-$$
cleanup() {
  d rm -f "$reg" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

d run -d --name "$reg" "$REGISTRY" >/dev/null
net=(--network "container:$reg")
oras() { d run --rm "${net[@]}" -v "$work:/w" -w /w "$ORAS" "$@"; }
cosign() { d run --rm "${net[@]}" -v "$work:/w" -w /w -e COSIGN_PASSWORD= "$COSIGN" "$@"; }
for _ in $(seq 1 30); do
  oras repo ls --plain-http localhost:5000 >/dev/null 2>&1 && break
  sleep 1
done

cosign generate-key-pair >/dev/null 2>&1
keyopts=(--key cosign.key --yes --new-bundle-format=true --use-signing-config=false --tlog-upload=false --allow-http-registry)
if [[ $mode == keybundle ]]; then
  repo=localhost:5000/spike
  oras copy --to-plain-http "$SPIKE" "$repo:v1" >/dev/null
  image=$repo@$(oras resolve --plain-http "$repo:v1")
  printf '{"buildDefinition":{"buildType":"https://actions.github.io/buildtypes/workflow/v1","externalParameters":{"workflow":{"repository":"https://github.com/anhnvcoder/svp-labs","ref":"refs/heads/main"}}},"runDetails":{"builder":{"id":"https://github.com/anhnvcoder/svp-labs/.github/workflows/attest-spike.yml@refs/heads/main"}}}' >"$work/provenance.json"
  printf '{"scanner":{"result":{"platforms":[]}},"metadata":{"scanFinishedOn":"2026-11-01T00:00:00Z"}}' >"$work/vuln.json"
  cosign attest "${keyopts[@]}" --type slsaprovenance1 --predicate provenance.json "$image" >/dev/null 2>&1
  cosign attest "${keyopts[@]}" --type vuln --predicate vuln.json "$image" >/dev/null 2>&1
  template=$here/policy-keybundle.yaml
else
  repo=localhost:5000/gateway
  # The index with both platforms, then its old-format signature and attestations, which live under tags.
  oras copy --to-plain-http "$RELEASE@$RELEASE_DIGEST" "$repo:release" >/dev/null
  for suffix in sig att; do
    tag=sha256-${RELEASE_DIGEST#sha256:}.$suffix
    oras copy --to-plain-http "$RELEASE:$tag" "$repo:$tag" >/dev/null
  done
  image=$repo@$RELEASE_DIGEST
  if [[ $mode == mixed ]]; then
    oras manifest fetch "$SPIKE_BUNDLE" >"$work/bundle-manifest.json"
    layer=$(jq -r '.layers[0].digest' "$work/bundle-manifest.json")
    oras blob fetch --output bundle.json "${SPIKE_BUNDLE%@*}@$layer"
    oras attach --plain-http --artifact-type application/vnd.dev.sigstore.bundle.v0.3+json \
      "$image" bundle.json:application/vnd.dev.sigstore.bundle.v0.3+json >/dev/null
  elif [[ $mode == moved ]]; then
    printf '{"buildDefinition":{"buildType":"https://actions.github.io/buildtypes/workflow/v1","externalParameters":{"workflow":{"repository":"https://github.com/anhnvcoder/svp-backend","ref":"refs/heads/main"}}},"runDetails":{"builder":{"id":"https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main"}}}' >"$work/provenance.json"
    cosign attest "${keyopts[@]}" --type slsaprovenance1 --predicate provenance.json "$image" >/dev/null 2>&1
  fi
  template=$here/policy-mixed.yaml
fi

echo "mode: $mode, image: $image"
echo "tags (old format):"
oras repo tags --plain-http "$repo" | sed 's/^/  /'
echo "referrers (new format):"
oras discover --plain-http --format tree "$image" | sed 's/^/  /'

# The template's placeholders: @IMAGE@ (the glob of the copy) and, on a line of its own, @KEY@ (the public key).
while IFS= read -r line; do
  case $line in
    "            @KEY@") sed 's/^/            /' "$work/cosign.pub" ;;
    *) printf '%s\n' "${line//@IMAGE@/$repo@*}" ;;
  esac
done <"$template" >"$work/policy.yaml"
cat >"$work/pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $mode
  namespace: spike
spec:
  containers:
    - name: c
      image: $image
EOF
echo "kyverno apply $(basename "$template") --resource pod.yaml:"
d run --rm "${net[@]}" -v "$work:/w:ro" -w /w "$KYVERNO" apply policy.yaml --resource pod.yaml 2>&1 | sed -n '/^Applying/,$p' || true # exit 1 when the policy refuses

# The same question for the script side (deploy/ci/verify-release.sh runs cosign verify, then cosign
# verify-attestation): on the gateway copy, does cosign still find the old-format signature and vuln attestation?
if [[ $mode != keybundle ]]; then
  identity=(--certificate-identity https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
    --certificate-oidc-issuer https://token.actions.githubusercontent.com)
  for check in "verify" "verify-attestation --type vuln"; do
    echo "cosign $check (identity of svp-backend):"
    set +e
    # shellcheck disable=SC2086 # $check is two or three words on purpose
    out=$(cosign $check --allow-http-registry "${identity[@]}" "$image" 2>&1 >/dev/null)
    status=$?
    set -e
    printf '%s\n' "$out" | tail -n 1 | sed 's/^/  /'
    echo "  exit $status"
  done
fi
