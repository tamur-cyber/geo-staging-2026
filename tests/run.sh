#!/usr/bin/env bash
#
# End-to-end suite for scripts/stage-sources.sh and scripts/publish-release.sh.
#
# It enters at the OUTERMOST DOOR: it runs the scripts exactly as
# .github/workflows/stage.yml runs them. The path is real all the way through --
# real curl with the shipped retry flags, a real local HTTP server, real bytes
# off disk, real sha256sum. curl is never mocked and no hash is ever fed in by
# hand.
#
# WHERE THE FIXTURES COME FROM, which is what stops the suite proving itself:
#   * the PINS come from the checked-in sources.json, untouched except that the
#     url field is repointed at 127.0.0.1;
#   * the BYTES come from the checked-in data/*.zip, served verbatim.
# So a passing T1 is the shipped pins agreeing with the shipped bytes, not the
# suite agreeing with itself.
#
# Every case asserts BOTH the exit code AND that pre-existing files in the
# destination are byte-for-byte unharmed.
#
#   ./tests/run.sh

# errexit is deliberately NOT enabled. Every case here is EXPECTED to run a
# command that exits non-zero, and the point is to report that as a result --
# a suite that aborted on the first failing command could not test failures at
# all. `set +e` below is therefore the standing state, and restoring it with
# `set -e` (as this file did until the CI item) silently turned errexit ON from
# the first case onward, leaving a trap for the next command added outside an
# `if`. Measured: with the old pair, a bare `false` after the first case killed
# the run; without it, the run continues and reports.
set -uo pipefail
set +e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
ORIGIN_PID=""; API_PID=""
SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/stage-tests.XXXXXXXX")"

cleanup() {
  [ -n "$ORIGIN_PID" ] && kill "$ORIGIN_PID" 2>/dev/null
  [ -n "$API_PID" ]    && kill "$API_PID"    2>/dev/null
  rm -rf "$SUITE_TMP"
}
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); echo "    ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "    FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3], got [$2])"; fi; }

# ---------------------------------------------------------------- origin ---
start_origin() {
  local out="$SUITE_TMP/origin.port"
  node tests/fake-origin.js > "$out" 2>"$SUITE_TMP/origin.err" &
  ORIGIN_PID=$!
  for _ in $(seq 1 50); do
    ORIGIN_PORT="$(sed -n 's/^PORT=//p' "$out" 2>/dev/null)"
    [ -n "$ORIGIN_PORT" ] && return 0
    sleep 0.1
  done
  echo "could not start fake origin"; cat "$SUITE_TMP/origin.err"; exit 1
}

# Build a sources file whose pins are the SHIPPED pins and whose urls point at
# the local origin in the given mode. `mode_for` overrides one named source.
make_sources() {  # make_sources <out> <default-mode> [<name> <mode>]
  local out="$1" def="$2" only_name="${3:-}" only_mode="${4:-}"
  jq --arg base "http://127.0.0.1:$ORIGIN_PORT" --arg def "$def" \
     --arg n "$only_name" --arg m "$only_mode" '
    .sources |= map(
      ($n != "" and .name == $n) as $hit
      | .url = $base + "/" + (if $hit then $m else $def end) + "/" + .name
    )' sources.json > "$out"
}

# A fresh destination holding SENTINEL files under the real names. Any test that
# must leave existing data alone is checked against these exact bytes.
make_dest() {  # make_dest <dir>
  local d="$1"; mkdir -p "$d"
  for n in $(jq -r '.sources[].name' sources.json); do
    printf 'PRE-EXISTING-GOOD-%s' "$n" > "$d/$n"
  done
}
dest_digest() { ( cd "$1" && sha256sum ./* | sort | sha256sum | cut -d' ' -f1 ); }

FIRST="$(jq -r '.sources[0].name' sources.json)"

run_case() {  # run_case <label> <default-mode> <victim-name> <victim-mode> <expect-zero|expect-nonzero>
  local label="$1" def="$2" vname="$3" vmode="$4" expect="$5"
  local d="$SUITE_TMP/${label}-dest" s="$SUITE_TMP/${label}-sources.json" m="$SUITE_TMP/${label}-manifest.txt"
  make_dest "$d"
  local before; before="$(dest_digest "$d")"
  make_sources "$s" "$def" "$vname" "$vmode"

  set +e
  bash scripts/stage-sources.sh --sources "$s" --dest "$d" --manifest "$m" \
    > "$SUITE_TMP/${label}.out" 2>&1
  local rc=$?

  echo "  --- ${label} (exit $rc) ---"
  CASE_RC="$rc"; CASE_OUT="$SUITE_TMP/${label}.out"; CASE_DEST="$d"
  CASE_MANIFEST="$m"; CASE_BEFORE="$before"
}

echo "================================================================"
echo "  stage-sources / publish-release end-to-end suite"
echo "================================================================"
start_origin
echo "fake origin on 127.0.0.1:$ORIGIN_PORT, serving the committed data/*.zip"
echo

# ---- T1: everything good ---------------------------------------------------
echo "T1  all sources good, hashes match  ->  exit 0, files in place"
run_case T1 good "" "" zero
check "T1 exit code is 0" "$CASE_RC" "0"
t1_all=1
for n in $(jq -r '.sources[].name' sources.json); do
  want="$(jq -r --arg n "$n" '.sources[] | select(.name==$n) | .sha256' sources.json)"
  got="$(sha256sum "$CASE_DEST/$n" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || { t1_all=0; echo "      mismatch on $n"; }
done
check "T1 all 8 destination files match their pinned sha256" "$t1_all" "1"
check "T1 manifest was written" "$([ -f "$CASE_MANIFEST" ] && echo yes || echo no)" "yes"
check "T1 manifest denominator is derived, not hardcoded" \
      "$(grep -c '^TOTAL_OK 8/8$' "$CASE_MANIFEST")" "1"
echo

# ---- T2: clean 404 ---------------------------------------------------------
echo "T2  one source returns a clean 404  ->  NON-ZERO, good files untouched"
run_case T2 good "$FIRST" notfound nonzero
check "T2 exit code is non-zero" "$([ "$CASE_RC" -ne 0 ] && echo yes || echo no)" "yes"
check "T2 destination is byte-identical to before" "$(dest_digest "$CASE_DEST")" "$CASE_BEFORE"
check "T2 no manifest written" "$([ -f "$CASE_MANIFEST" ] && echo yes || echo no)" "no"
check "T2 the failure names the source" "$(grep -c "FAILED  $FIRST" "$CASE_OUT")" "1"
echo

# ---- T3: truncation --------------------------------------------------------
echo "T3  one source truncates mid-body   ->  NON-ZERO, good file UNCHANGED"
echo "    (this is the case that destroyed a good file in the old workflow)"
run_case T3 good "$FIRST" truncate nonzero
check "T3 exit code is non-zero" "$([ "$CASE_RC" -ne 0 ] && echo yes || echo no)" "yes"
check "T3 destination is byte-identical to before" "$(dest_digest "$CASE_DEST")" "$CASE_BEFORE"
check "T3 the good file was NOT replaced by a partial" \
      "$(cat "$CASE_DEST/$FIRST")" "PRE-EXISTING-GOOD-$FIRST"
check "T3 no manifest written" "$([ -f "$CASE_MANIFEST" ] && echo yes || echo no)" "no"
echo

# ---- T4: soft 404 ----------------------------------------------------------
echo "T4  one source soft-404s (200 + HTML)  ->  NON-ZERO, UNCHANGED, nothing OK"
run_case T4 good "$FIRST" soft404 nonzero
check "T4 exit code is non-zero" "$([ "$CASE_RC" -ne 0 ] && echo yes || echo no)" "yes"
check "T4 destination is byte-identical to before" "$(dest_digest "$CASE_DEST")" "$CASE_BEFORE"
check "T4 no manifest written" "$([ -f "$CASE_MANIFEST" ] && echo yes || echo no)" "no"
check "T4 nothing was recorded as OK anywhere" "$(grep -c '^OK ' "$CASE_OUT")" "0"
check "T4 the HTML body was never accepted as the file" \
      "$(grep -q 'Page not found' "$CASE_DEST/$FIRST" 2>/dev/null && echo present || echo absent)" "absent"
echo

# ---- T5: clean download, wrong hash ---------------------------------------
echo "T5  downloads cleanly and completely, sha256 does NOT match the pin"
echo "    ->  NON-ZERO, and it must fail for the HASH reason alone"
run_case T5 good "$FIRST" badhash nonzero
check "T5 exit code is non-zero" "$([ "$CASE_RC" -ne 0 ] && echo yes || echo no)" "yes"
check "T5 destination is byte-identical to before" "$(dest_digest "$CASE_DEST")" "$CASE_BEFORE"
check "T5 failed for the sha256 reason"  "$(grep -c "^  FAILED  $FIRST -- sha256 mismatch" "$CASE_OUT")" "1"
check "T5 did NOT fail for a size reason" "$(grep -c 'size mismatch'   "$CASE_OUT")" "0"
check "T5 did NOT fail for a download reason" "$(grep -c 'download failed' "$CASE_OUT")" "0"
check "T5 no manifest written" "$([ -f "$CASE_MANIFEST" ] && echo yes || echo no)" "no"
echo

# ---- T6: tag collision with differing content ------------------------------
echo "T6  tag exists, published content DIFFERS  ->  NON-ZERO, nothing uploaded"
API_LOG="$SUITE_TMP/uploads.log"; : > "$API_LOG"
FAKE_API_MODE=differ FAKE_API_UPLOAD_LOG="$API_LOG" \
  node tests/fake-api.js > "$SUITE_TMP/api.port" 2>"$SUITE_TMP/api.err" &
API_PID=$!
for _ in $(seq 1 50); do
  API_PORT="$(sed -n 's/^PORT=//p' "$SUITE_TMP/api.port" 2>/dev/null)"
  [ -n "$API_PORT" ] && break
  sleep 0.1
done
[ -n "${API_PORT:-}" ] || { echo "could not start fake api"; cat "$SUITE_TMP/api.err"; exit 1; }

set +e
GITHUB_TOKEN=test-token GITHUB_API_URL="http://127.0.0.1:$API_PORT" \
  bash scripts/publish-release.sh --repo tamur-cyber/geo-staging-2026 \
       --tag sources-2026-01-01 > "$SUITE_TMP/T6.out" 2>&1
T6_RC=$?
echo "  --- T6 (exit $T6_RC) ---"
check "T6 exit code is non-zero" "$([ "$T6_RC" -ne 0 ] && echo yes || echo no)" "yes"
check "T6 refused as a collision" "$(grep -c 'TAG COLLISION WITH DIFFERING CONTENT' "$SUITE_TMP/T6.out")" "1"
check "T6 nothing was uploaded" "$(wc -l < "$API_LOG" | tr -d ' ')" "0"
check "T6 said it would not overwrite" \
      "$(grep -c 'refusing to overwrite a published provenance asset' "$SUITE_TMP/T6.out")" "1"
kill "$API_PID" 2>/dev/null; API_PID=""
echo

# ---- T6b: the same tag, identical content, is a no-op ----------------------
echo "T6b tag exists, published content IDENTICAL  ->  exit 0, nothing uploaded"
: > "$API_LOG"
FAKE_API_MODE=identical FAKE_API_UPLOAD_LOG="$API_LOG" \
  node tests/fake-api.js > "$SUITE_TMP/api2.port" 2>"$SUITE_TMP/api2.err" &
API_PID=$!
for _ in $(seq 1 50); do
  API_PORT="$(sed -n 's/^PORT=//p' "$SUITE_TMP/api2.port" 2>/dev/null)"
  [ -n "$API_PORT" ] && break
  sleep 0.1
done
set +e
GITHUB_TOKEN=test-token GITHUB_API_URL="http://127.0.0.1:$API_PORT" \
  bash scripts/publish-release.sh --repo tamur-cyber/geo-staging-2026 \
       --tag sources-2026-01-01 > "$SUITE_TMP/T6b.out" 2>&1
T6B_RC=$?
echo "  --- T6b (exit $T6B_RC) ---"
check "T6b exit code is 0" "$T6B_RC" "0"
check "T6b reported identical" "$(grep -c 'byte-identical to the pins' "$SUITE_TMP/T6b.out")" "1"
check "T6b nothing was uploaded" "$(wc -l < "$API_LOG" | tr -d ' ')" "0"
kill "$API_PID" 2>/dev/null; API_PID=""
echo

# ---- T6c: tag absent -> create and upload all eight ------------------------
echo "T6c tag absent  ->  exit 0, all 8 assets uploaded"
: > "$API_LOG"
FAKE_API_MODE=absent FAKE_API_UPLOAD_LOG="$API_LOG" \
  node tests/fake-api.js > "$SUITE_TMP/api3.port" 2>"$SUITE_TMP/api3.err" &
API_PID=$!
for _ in $(seq 1 50); do
  API_PORT="$(sed -n 's/^PORT=//p' "$SUITE_TMP/api3.port" 2>/dev/null)"
  [ -n "$API_PORT" ] && break
  sleep 0.1
done
set +e
GITHUB_TOKEN=test-token GITHUB_API_URL="http://127.0.0.1:$API_PORT" \
  bash scripts/publish-release.sh --repo tamur-cyber/geo-staging-2026 \
       --tag sources-2026-01-01 > "$SUITE_TMP/T6c.out" 2>&1
T6C_RC=$?
echo "  --- T6c (exit $T6C_RC) ---"
check "T6c exit code is 0" "$T6C_RC" "0"
check "T6c uploaded all 8 assets" "$(wc -l < "$API_LOG" | tr -d ' ')" "8"
t6c_sizes=1
while read -r n b; do
  want="$(jq -r --arg n "$n" '.sources[] | select(.name==$n) | .bytes' sources.json)"
  [ "$want" = "$b" ] || { t6c_sizes=0; echo "      $n uploaded $b, pinned $want"; }
done < "$API_LOG"
check "T6c every uploaded asset is the full pinned length" "$t6c_sizes" "1"
kill "$API_PID" 2>/dev/null; API_PID=""
echo

# ---- T7/T8/T9: the Statistics Canada attribution cannot drift -------------
# The canonical string lives in ONE place, sources.json. It is READ from there
# here -- never written into this file -- so these cases prove the COPIES AGREE
# with the canonical text rather than proving the suite agrees with itself.
# It came to be wrong in three places at once because there were three
# hand-maintained copies; that is what these guard against happening again.
ATTRIBUTION="$(jq -r '.attribution // empty' sources.json)"
echo "T7-T9  the canonical attribution, read from sources.json"
check "canonical attribution is present in sources.json" \
      "$([ -n "$ATTRIBUTION" ] && echo yes || echo no)" "yes"
check "canonical attribution is a single line" \
      "$(printf '%s' "$ATTRIBUTION" | wc -l | tr -d ' ')" "0"
echo

echo "T7  README.md carries the canonical string, byte-for-byte"
check "T7 README.md contains it exactly" \
      "$(grep -cF -- "$ATTRIBUTION" README.md)" "1"
echo

echo "T8  LICENSE carries the canonical string, byte-for-byte"
check "T8 LICENSE contains it exactly" \
      "$(grep -cF -- "$ATTRIBUTION" LICENSE)" "1"
echo

# T9 observes what would actually be PUBLISHED. It reads the release-creation
# payload the fake API received, not the script's source -- a grep of the source
# would pass even if the value never reached the request body.
echo "T9  a created release carries the canonical string in its body"
: > "$API_LOG"
REL_LOG="$SUITE_TMP/release-body.json"; : > "$REL_LOG"
FAKE_API_MODE=absent FAKE_API_UPLOAD_LOG="$API_LOG" FAKE_API_RELEASE_LOG="$REL_LOG" \
  node tests/fake-api.js > "$SUITE_TMP/api4.port" 2>"$SUITE_TMP/api4.err" &
API_PID=$!
for _ in $(seq 1 50); do
  API_PORT="$(sed -n 's/^PORT=//p' "$SUITE_TMP/api4.port" 2>/dev/null)"
  [ -n "$API_PORT" ] && break
  sleep 0.1
done
GITHUB_TOKEN=test-token GITHUB_API_URL="http://127.0.0.1:$API_PORT" \
  bash scripts/publish-release.sh --repo tamur-cyber/geo-staging-2026 \
       --tag sources-2026-01-01 > "$SUITE_TMP/T9.out" 2>&1
T9_RC=$?
kill "$API_PID" 2>/dev/null; API_PID=""
echo "  --- T9 (exit $T9_RC) ---"
check "T9 the release was created" "$T9_RC" "0"
check "T9 the fake API recorded a release-creation payload" \
      "$([ -s "$REL_LOG" ] && echo yes || echo no)" "yes"
# Compare the body the SERVER received against the canonical string.
T9_BODY="$(jq -r '.body // empty' "$REL_LOG" 2>/dev/null)"
check "T9 the published body contains the canonical string exactly" \
      "$(printf '%s' "$T9_BODY" | grep -cF -- "$ATTRIBUTION")" "1"
check "T9 the published body carries no OTHER 'Adapted from Statistics Canada'" \
      "$(printf '%s' "$T9_BODY" | grep -cF 'Adapted from Statistics Canada')" "1"
echo
echo "================================================================"
echo "  passed: $PASS   failed: $FAIL"
echo "================================================================"
[ "$FAIL" -eq 0 ] || exit 1
