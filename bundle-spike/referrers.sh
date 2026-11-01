#!/usr/bin/env bash
# referrers.sh list|prune IMAGE@DIGEST: the Sigstore bundles attached to one image as OCI referrers.
#
#   list   prints one line per bundle referrer: referrer digest, what it holds (the predicateType of its DSSE statement,
#          or "signature" for the message signature of cosign sign), and for a vuln attestation its scanFinishedOn.
#          Read from each bundle itself (manifest, then its one layer), not from annotations. Anonymous on a public
#          package; works on a machine.
#   prune  keeps the vuln bundle with the newest scanFinishedOn and removes every other vuln bundle: first with
#          `oras manifest delete` (the registry API), then, for one still listed, by deleting its package version with
#          the GitHub REST API (GH_TOKEN, the job's GITHUB_TOKEN with packages: write). Prints what each way answered,
#          then lists again. Workflow only: it needs the job's registry login (ORAS_CONFIG) and token.
#
# oras runs from the image svp-backend pins (ORAS_IMAGE of its Makefile). ORAS_CONFIG, when set, is a docker config
# file mounted read-only for oras to log in with.
set -euo pipefail

ORAS=ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb
BUNDLE_TYPE=application/vnd.dev.sigstore.bundle.v0.3+json
VULN_TYPE=https://cosign.sigstore.dev/attestation/vuln/v1

[ $# -eq 2 ] || { echo "usage: referrers.sh list|prune IMAGE@DIGEST" >&2; exit 2; }
cmd=$1 ref=$2
[[ $ref =~ ^(ghcr\.io/([a-z0-9-]+)/([a-z0-9._/-]+))@(sha256:[0-9a-f]{64})$ ]] ||
  { echo "FAIL  $ref is not ghcr.io/<owner>/<package>@sha256:<64 hex>" >&2; exit 2; }
repo=${BASH_REMATCH[1]} owner=${BASH_REMATCH[2]} package=${BASH_REMATCH[3]}

oras() {
  local cfg=()
  # The login file is readable by its owner only: oras runs as that user.
  [ -z "${ORAS_CONFIG:-}" ] || cfg=(-v "$ORAS_CONFIG:/config.json:ro" --user "$(id -u):$(id -g)")
  env -u DOCKER_DEFAULT_PLATFORM docker run --rm ${cfg[@]+"${cfg[@]}"} "$ORAS" "$@" \
    ${ORAS_CONFIG:+--registry-config /config.json}
}

# list_lines: "<referrer digest> <content> <scanFinishedOn or ->" per bundle referrer of ref.
list_lines() {
  local digests d layer bundle
  digests=$(oras discover --format json --artifact-type "$BUNDLE_TYPE" "$ref" |
    jq -r '(.referrers // .manifests // [])[].digest') || { echo "FAIL  discover the referrers of $ref" >&2; return 1; }
  for d in $digests; do
    layer=$(oras manifest fetch "$repo@$d" | jq -r '.layers[0].digest') || { echo "FAIL  fetch $repo@$d" >&2; return 1; }
    bundle=$(oras blob fetch --output - "$repo@$layer") || { echo "FAIL  fetch $repo@$layer" >&2; return 1; }
    jq -r --arg d "$d" '
      if .dsseEnvelope then (.dsseEnvelope.payload | @base64d | fromjson) as $s
        | "\($d) \($s.predicateType) \($s.predicate.metadata.scanFinishedOn // "-")"
      else "\($d) signature -" end' <<<"$bundle"
  done
}

case $cmd in
list)
  list_lines | sort -k2,2 -k3,3
  ;;
prune)
  lines=$(list_lines)
  echo "before:"
  printf '%s\n' "$lines"
  old=$(printf '%s\n' "$lines" | awk -v t="$VULN_TYPE" '$2 == t' | sort -k3,3 | sed '$d' | cut -d' ' -f1)
  [ -n "$old" ] || { echo "no vuln bundle but the newest: nothing to remove"; exit 0; }
  status=0
  for d in $old; do
    echo "remove $repo@$d"
    if oras manifest delete --force "$repo@$d"; then
      echo "  oras manifest delete: exit 0"
    else
      echo "  oras manifest delete: exit $?"
    fi
    if list_lines | cut -d' ' -f1 | grep -qx "$d"; then
      id=$(gh api --paginate "/users/$owner/packages/container/${package//\//%2F}/versions" |
        jq -r --arg d "$d" '.[] | select(.name == $d) | .id') || id=
      if [ -z "$id" ]; then
        echo "  GitHub API: no package version named $d"
        status=1
      elif gh api -X DELETE "/users/$owner/packages/container/${package//\//%2F}/versions/$id"; then
        echo "  GitHub API: package version $id deleted"
      else
        echo "  GitHub API: delete of package version $id failed"
        status=1
      fi
    fi
  done
  echo "after:"
  list_lines | sort -k2,2 -k3,3
  exit "$status"
  ;;
*)
  echo "usage: referrers.sh list|prune IMAGE@DIGEST" >&2
  exit 2
  ;;
esac
