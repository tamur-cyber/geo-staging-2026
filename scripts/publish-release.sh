#!/usr/bin/env bash
#
# Publish the verified sources as assets of a release on a PINNED, DATED tag.
#
# The split this implements: GIT HOLDS THE RECORD, RELEASES HOLD THE BYTES.
# manifest.txt stays in git as the provenance record; the zips become release
# assets. The files already committed under data/ are LEFT EXACTLY AS THEY ARE
# -- this script never deletes, ignores or rewrites anything in the tree.
#
# The tag is dated and pinned, never "latest". A /releases/latest/download/<file>
# URL resolves "latest" at request time and 404s the moment a newer release does
# not carry that exact filename, so it is not a stable address for a consumer.
#
# TAG COLLISION POLICY -- three states, and the third is the point:
#   tag absent               -> create the release, upload the assets
#   tag present, identical   -> do nothing, log it, succeed (the run is a no-op)
#   tag present, DIFFERENT   -> FAIL LOUDLY, upload nothing, change nothing
# A published provenance asset is never overwritten. If the bytes behind a tag
# have changed, that is a finding for a human, not something to paper over.
#
# "Identical" is decided by DOWNLOADING each published asset and hashing it
# against the pin in sources.json -- not by trusting a size, a name or a field
# the API reports about itself.
#
# Usage:
#   scripts/publish-release.sh [--sources FILE] [--dest DIR] [--tag TAG] [--repo OWNER/REPO]
#
# Environment:
#   GITHUB_TOKEN     required. In Actions this is minted per job by GitHub and
#                    needs `permissions: contents: write`. No stored secret.
#   GITHUB_API_URL   default https://api.github.com  (overridden by tests)
#   GITHUB_REPOSITORY  default for --repo
#
# Exit codes:
#   0  release created and uploaded, or already present and identical
#   1  collision with differing content, or an upload/API failure
#   2  bad invocation

set -euo pipefail

SOURCES_FILE="sources.json"
DEST_DIR="data"
TAG=""
REPO="${GITHUB_REPOSITORY:-}"
API="${GITHUB_API_URL:-https://api.github.com}"

while [ $# -gt 0 ]; do
  case "$1" in
    --sources) SOURCES_FILE="${2:?}"; shift 2 ;;
    --dest)    DEST_DIR="${2:?}";     shift 2 ;;
    --tag)     TAG="${2:?}";          shift 2 ;;
    --repo)    REPO="${2:?}";         shift 2 ;;
    *) echo "publish-release: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "${GITHUB_TOKEN:-}" ] || { echo "publish-release: GITHUB_TOKEN is not set" >&2; exit 2; }
[ -n "$REPO" ] || { echo "publish-release: no repository (--repo or GITHUB_REPOSITORY)" >&2; exit 2; }
[ -f "$SOURCES_FILE" ] || { echo "publish-release: no such sources file: $SOURCES_FILE" >&2; exit 2; }

# A dated tag, in UTC, so two runs on the same day address the same release and
# meet the collision policy above rather than quietly making a second one.
[ -n "$TAG" ] || TAG="sources-$(date -u +%Y-%m-%d)"

TOTAL="$(jq -r '.sources | length' "$SOURCES_FILE")"

# The attribution is READ from sources.json, never carried here. Three
# hand-maintained copies of this sentence is exactly how it came to be wrong in
# all three places at once; sources.json is the one canonical copy and
# tests/run.sh checks README.md and LICENSE against it.
ATTRIBUTION="$(jq -r '.attribution // empty' "$SOURCES_FILE")"
[ -n "$ATTRIBUTION" ] || { echo "publish-release: $SOURCES_FILE carries no .attribution -- refusing to publish a release with no Statistics Canada attribution" >&2; exit 2; }
API="${API%/}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-release.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# api <method> <url> [curl args...]
# Leaves the response body in the file named by $API_BODY and the status in
# $HTTP_STATUS. It deliberately does NOT print the body: capturing this with
# `$(api ...)` would run it in a SUBSHELL, so the HTTP_STATUS assignment would
# be discarded and every status check would read a stale or unset value. That
# was a real bug here, caught by `set -u` on the first run of the suite.
HTTP_STATUS=""
API_BODY=""
api() {
  local method="$1" url="$2"; shift 2
  API_BODY="$WORK/api.out"
  HTTP_STATUS="$(curl --silent --show-error -w '%{http_code}' -o "$API_BODY" \
    -X "$method" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: geo-staging-2026-publish-release" \
    "$@" "$url")"
}

echo "publish-release: repo $REPO"
echo "publish-release: tag  $TAG"
echo "publish-release: api  $API"
echo

# ---- does the tag already have a release? --------------------------------
api GET "$API/repos/$REPO/releases/tags/$TAG"
status="$HTTP_STATUS"

if [ "$status" = "200" ]; then
  echo "publish-release: a release already exists on tag $TAG -- comparing published bytes against the pins"
  cp "$API_BODY" "$WORK/release.json"

  differ=0
  declare -a PROBLEMS=()
  for i in $(seq 0 $((TOTAL - 1))); do
    name="$(jq -r ".sources[$i].name"   "$SOURCES_FILE")"
    want="$(jq -r ".sources[$i].sha256" "$SOURCES_FILE")"

    asset_url="$(jq -r --arg n "$name" '.assets[]? | select(.name == $n) | .url' "$WORK/release.json" | head -1)"
    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
      PROBLEMS+=("$name: pinned source is NOT among the published assets")
      differ=1
      continue
    fi

    rc=0
    curl -fL --silent --show-error \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/octet-stream" \
      -H "User-Agent: geo-staging-2026-publish-release" \
      -o "$WORK/published-$name" "$asset_url" || rc=$?
    if [ "$rc" -ne 0 ]; then
      PROBLEMS+=("$name: published asset could not be downloaded for comparison (curl exit $rc)")
      differ=1
      continue
    fi

    got="$(sha256sum "$WORK/published-$name" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
      PROBLEMS+=("$name: published sha256 $got does not match pinned $want")
      differ=1
    else
      echo "  identical  $name  $got"
    fi
  done

  if [ "$differ" -ne 0 ]; then
    echo
    echo "publish-release: TAG COLLISION WITH DIFFERING CONTENT on $TAG."
    for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
    echo
    echo "publish-release: refusing to overwrite a published provenance asset. Nothing was uploaded."
    echo "publish-release: if the sources have legitimately changed, publish under a NEW dated tag."
    exit 1
  fi

  echo
  echo "publish-release: all $TOTAL asset(s) on $TAG are byte-identical to the pins. Nothing to do."
  exit 0

elif [ "$status" != "404" ]; then
  echo "publish-release: unexpected HTTP $status looking up tag $TAG" >&2
  cat "$API_BODY" >&2
  exit 1
fi

# ---- tag absent: create the release and upload -----------------------------
echo "publish-release: no release on tag $TAG -- creating it"

for i in $(seq 0 $((TOTAL - 1))); do
  name="$(jq -r ".sources[$i].name" "$SOURCES_FILE")"
  [ -f "$DEST_DIR/$name" ] || { echo "publish-release: $DEST_DIR/$name is missing -- run stage-sources.sh first" >&2; exit 1; }
done

notes="Statistics Canada open-licence source files, verified byte-for-byte against the pinned sizes and SHA-256 values in sources.json.

$ATTRIBUTION"

payload="$(jq -n --arg tag "$TAG" --arg name "$TAG" --arg body "$notes" \
  '{tag_name: $tag, name: $name, body: $body, draft: false, prerelease: false}')"

api POST "$API/repos/$REPO/releases" -H "Content-Type: application/json" -d "$payload"
status="$HTTP_STATUS"
if [ "$status" != "201" ]; then
  echo "publish-release: failed to create release (HTTP $status)" >&2
  cat "$API_BODY" >&2
  exit 1
fi
cp "$API_BODY" "$WORK/created.json"

upload_url="$(jq -r '.upload_url' "$WORK/created.json")"
upload_url="${upload_url%%\{*}"          # strip the RFC 6570 "{?name,label}" suffix
[ -n "$upload_url" ] && [ "$upload_url" != "null" ] \
  || { echo "publish-release: created release carried no upload_url" >&2; exit 1; }

echo "publish-release: uploading $TOTAL asset(s)"
for i in $(seq 0 $((TOTAL - 1))); do
  name="$(jq -r ".sources[$i].name" "$SOURCES_FILE")"
  sz="$(  jq -r ".sources[$i].bytes" "$SOURCES_FILE")"
  api POST "$upload_url?name=$name" \
      -H "Content-Type: application/zip" \
      --data-binary "@$DEST_DIR/$name"
  status="$HTTP_STATUS"
  if [ "$status" != "201" ]; then
    echo "publish-release: failed to upload $name (HTTP $status)" >&2
    cat "$API_BODY" >&2
    exit 1
  fi
  echo "  uploaded  $name  $sz bytes"
done

echo
echo "publish-release: release $TAG published with $TOTAL asset(s)."
echo "publish-release: assets are downloadable, unauthenticated, at"
echo "  https://github.com/$REPO/releases/download/$TAG/<filename>"
exit 0
