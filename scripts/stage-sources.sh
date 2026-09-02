#!/usr/bin/env bash
#
# Fetch the pinned Statistics Canada open-licence sources, verify every one of
# them against sources.json, and only then write anything into place.
#
# This exists as a file rather than an inline workflow `run:` block for one
# reason: a YAML block cannot be executed by a test. tests/run.sh drives THIS
# script, exactly as .github/workflows/stage.yml drives it.
#
# The four defects this replaces, all reproduced by execution before it was
# written:
#
#   D1  A failed download left the job GREEN. The failing curl sat in an `if`
#       condition, which `set -e` exempts, so the else branch recorded "FAIL"
#       and the step still exited 0. Here every failure is counted and the
#       script exits non-zero.
#   D2  A truncated download DESTROYED the good file: curl had already written
#       a partial body over the destination before it exited 18. Here every
#       download goes to a temp directory and the destination is never opened
#       until the bytes have been verified.
#   D3  A soft-404 (HTTP 200 carrying an HTML error page) was recorded as "OK"
#       with a fresh, plausible sha256. A successful HTTP status is not a valid
#       body. Here the body must match a pinned size AND a pinned sha256.
#   D4  The manifest hashed whatever arrived, so it could never detect
#       corruption -- a receipt, not provenance. Here the expected hash is
#       known in advance and the manifest records a verified match.
#
# ALL-OR-NOTHING: every source is downloaded and verified into a temp directory
# first. Files are moved into place only if ALL of them passed. A partial
# success writes nothing at all, so a bad run cannot leave data/ half-updated.
#
# Usage:
#   scripts/stage-sources.sh [--sources FILE] [--dest DIR] [--manifest FILE]
#
# Exit codes:
#   0  every source verified and written
#   1  at least one source failed; nothing was written
#   2  bad invocation or a malformed sources file

set -euo pipefail

SOURCES_FILE="sources.json"
DEST_DIR="data"
MANIFEST_FILE="manifest.txt"

while [ $# -gt 0 ]; do
  case "$1" in
    --sources)  SOURCES_FILE="${2:?--sources needs a value}"; shift 2 ;;
    --dest)     DEST_DIR="${2:?--dest needs a value}"; shift 2 ;;
    --manifest) MANIFEST_FILE="${2:?--manifest needs a value}"; shift 2 ;;
    *) echo "stage-sources: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq   >/dev/null || { echo "stage-sources: jq not found" >&2; exit 2; }
command -v curl >/dev/null || { echo "stage-sources: curl not found" >&2; exit 2; }

[ -f "$SOURCES_FILE" ] || { echo "stage-sources: no such sources file: $SOURCES_FILE" >&2; exit 2; }
jq -e 'has("sources") and (.sources | type == "array") and (.sources | length > 0)' \
   "$SOURCES_FILE" >/dev/null 2>&1 \
  || { echo "stage-sources: $SOURCES_FILE has no non-empty .sources array" >&2; exit 2; }

# The denominator is DERIVED from the source list. The previous workflow
# hardcoded "/8", so a ninth source would have printed "TOTAL_OK 9/8" -- and,
# worse, a ninth source that FAILED would have printed "TOTAL_OK 8/8" and read
# as complete success.
TOTAL="$(jq -r '.sources | length' "$SOURCES_FILE")"

# Every path out of this script removes the temp directory, including a signal.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stage-sources.XXXXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

mkdir -p "$DEST_DIR"

ok=0
failed=0
declare -a FAILURES=()

fail() {  # fail <name> <reason>
  FAILURES+=("$1: $2")
  failed=$((failed + 1))
  echo "  FAILED  $1 -- $2"
}

echo "stage-sources: $TOTAL pinned source(s) from $SOURCES_FILE"
echo "stage-sources: staging into $WORK (destination $DEST_DIR is untouched until every source passes)"
echo

# ---- phase 1: download and verify, touching nothing outside $WORK ----------
for i in $(seq 0 $((TOTAL - 1))); do
  name="$(jq -r ".sources[$i].name"   "$SOURCES_FILE")"
  url="$( jq -r ".sources[$i].url"    "$SOURCES_FILE")"
  want_bytes="$(jq -r ".sources[$i].bytes"  "$SOURCES_FILE")"
  want_sha="$(  jq -r ".sources[$i].sha256" "$SOURCES_FILE")"

  echo "== [$((i + 1))/$TOTAL] $name"
  echo "   $url"

  if [ -z "$name" ] || [ "$name" = "null" ] || [ "$url" = "null" ] \
     || [ "$want_bytes" = "null" ] || [ "$want_sha" = "null" ]; then
    echo "stage-sources: source index $i is missing name/url/bytes/sha256" >&2
    exit 2
  fi
  # A name that escapes the destination directory would let a sources file
  # write anywhere on the runner.
  case "$name" in
    */*|*..*|"") echo "stage-sources: illegal source name: $name" >&2; exit 2 ;;
  esac

  tmp="$WORK/$name"

  # Same retry behaviour the previous workflow had. `|| true` keeps `set -e`
  # from aborting the loop: a failing source must be REPORTED, not skipped
  # silently, and the remaining sources must still be attempted.
  rc=0
  curl -fL --retry 4 --retry-delay 5 -A "Mozilla/5.0" \
       --silent --show-error -o "$tmp" "$url" || rc=$?

  if [ "$rc" -ne 0 ]; then
    # curl 22 = HTTP error (404/403). curl 18 = transfer closed early, which is
    # the truncation case: the partial body is in $WORK and is discarded with it.
    fail "$name" "download failed (curl exit $rc)"
    continue
  fi
  if [ ! -f "$tmp" ]; then
    fail "$name" "download produced no file"
    continue
  fi

  got_bytes="$(stat -c%s "$tmp")"
  if [ "$got_bytes" != "$want_bytes" ]; then
    fail "$name" "size mismatch: expected $want_bytes bytes, got $got_bytes"
    continue
  fi

  got_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
  if [ "$got_sha" != "$want_sha" ]; then
    fail "$name" "sha256 mismatch: expected $want_sha, got $got_sha"
    continue
  fi

  echo "  VERIFIED $name  $got_bytes bytes  $got_sha"
  ok=$((ok + 1))
done

echo
echo "stage-sources: verified $ok/$TOTAL"

# ---- phase 2: commit, or refuse ------------------------------------------
if [ "$failed" -ne 0 ]; then
  echo
  echo "stage-sources: $failed of $TOTAL source(s) FAILED. NOTHING was written."
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  echo
  echo "stage-sources: $DEST_DIR and $MANIFEST_FILE are unchanged."
  exit 1
fi

for i in $(seq 0 $((TOTAL - 1))); do
  name="$(jq -r ".sources[$i].name" "$SOURCES_FILE")"
  mv -f "$WORK/$name" "$DEST_DIR/$name"
done

# The manifest is written only on a full pass, so it can never record a run
# that did not happen. Every line is a VERIFIED match against a pinned value,
# not a hash of whatever turned up.
{
  for i in $(seq 0 $((TOTAL - 1))); do
    name="$(jq -r ".sources[$i].name"   "$SOURCES_FILE")"
    sz="$(  jq -r ".sources[$i].bytes"  "$SOURCES_FILE")"
    sha="$( jq -r ".sources[$i].sha256" "$SOURCES_FILE")"
    echo "OK $name $sz $sha"
  done
  echo "TOTAL_OK $ok/$TOTAL"
} > "$MANIFEST_FILE"

echo "stage-sources: wrote $MANIFEST_FILE"
cat "$MANIFEST_FILE"
exit 0
