#!/bin/sh
set -eu

# Read-only acceptance of the already-built, unpackaged native arm64 archive.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"

# Refuse before inspecting or changing the checkout unless explicitly opted in.
[ "${AIRDCCORE_RUN_BUILD_TESTS:-0}" = 1 ] ||
  fail 'set AIRDCCORE_RUN_BUILD_TESTS=1 for live Gate 3'

. "$ROOT/scripts/lib/upstream.sh"
. "$ROOT/scripts/lib/configure.sh"
load_upstream_config "$ROOT/config/upstream.env" || fail 'invalid upstream pin'
CHECKOUT=$ROOT/Source/airdcpp-core
BUILD_ROOT=$ROOT/Build/airdcpp-core
BUILD=$BUILD_ROOT/core-release
ARCHIVE=$BUILD/upstream/libairdcpp.a
REPORT=$ROOT/docs/reports/2026-09-20-gate-3-arm64-core-build.md

assert_file_present "$REPORT"
[ -d "$CHECKOUT" ] && [ ! -L "$CHECKOUT" ] || fail 'pinned source checkout missing or symlinked'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AIRDCPP_CORE_COMMIT" 'pinned upstream commit'
assert_eq "$(git -C "$CHECKOUT" remote get-url --all origin)" "$AIRDCPP_CORE_URL" 'pinned upstream origin'
if git -C "$CHECKOUT" symbolic-ref -q HEAD >/dev/null 2>&1; then fail 'upstream HEAD must be detached'; fi
git -C "$CHECKOUT" diff --quiet HEAD -- || fail 'upstream tracked files changed'
git -C "$CHECKOUT" diff --cached --quiet -- || fail 'upstream staged files changed'
assert_eq "$(git -C "$CHECKOUT" ls-files --others --exclude-standard)" '' 'upstream untracked source'
ignored=$(git -C "$CHECKOUT" ls-files --others --ignored --exclude-standard)
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    airdcpp/core/version.inc|airdcpp/core/localization/StringDefs.cpp)
      [ -f "$CHECKOUT/$path" ] && [ ! -L "$CHECKOUT/$path" ] || fail "unsafe generated file: $path" ;;
    *) fail "unexpected ignored upstream path: $path" ;;
  esac
done <<EOF
$ignored
EOF
assert_file_present "$CHECKOUT/airdcpp/core/version.inc"
assert_file_present "$CHECKOUT/airdcpp/core/localization/StringDefs.cpp"

[ -d "$BUILD" ] && [ ! -L "$BUILD" ] || fail 'core-release missing or symlinked'
# Capture these boundaries before any evidence inspection or external tool call.
before_parent=$(configure_tree_snapshot "$ROOT") || fail 'failed to snapshot parent'
before_source=$(configure_upstream_snapshot "$CHECKOUT") || fail 'failed to snapshot source'
before_preserved=$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 ! -name core-release -print | LC_ALL=C sort) ||
  fail 'failed to inventory historical Gate 2 directories'
for evidence in first-build-state.txt build-inputs.txt host-inventory.txt command.txt \
    configure.log cache.txt CMakeCache.txt airdcpp-configure-summary.txt \
    build-command.txt build.log build-exit-code.txt archive-members.tsv \
    archive-symbols.txt archive-strings.txt archive-ar-table.txt \
    archive-sha256.txt .ninja_log; do
  [ -f "$BUILD/$evidence" ] && [ ! -L "$BUILD/$evidence" ] || fail "missing or unsafe Core evidence: $evidence"
done
assert_line "$BUILD/first-build-state.txt" 'core-release.preexisting=absent' 'first-build provenance'
assert_line "$BUILD/build-exit-code.txt" 0 'Core build status'
assert_line "$BUILD/build-inputs.txt" "upstream.commit=$AIRDCPP_CORE_COMMIT" 'build source pin'
assert_line "$BUILD/build-inputs.txt" 'source.file_prefix_map=airdcpp-core' 'source prefix-map build input'
assert_contains "$(cat "$BUILD/build-command.txt")" "'--target' 'airdcpp'" 'Core-only target'
assert_contains "$(cat "$BUILD/build-command.txt")" "'--config' 'Release'" 'Release build command'
assert_contains "$(cat "$BUILD/build-command.txt")" "'--parallel' '2'" 'bounded build parallelism'
assert_contains "$(cat "$BUILD/build-command.txt")" "$BUILD" 'current Core build tree'
assert_contains "$(cat "$BUILD/.ninja_log")" 'upstream/libairdcpp.a' 'executed Ninja archive target'

for expected in architecture=arm64 deployment_target=14.0 build_type=Release \
    cxx_standard=20 cxx_standard_required=ON cxx_extensions=OFF \
    build_shared_libs=OFF enable_natpmp=OFF enable_tbb=OFF; do
  assert_line "$BUILD/airdcpp-configure-summary.txt" "$expected" 'configured ARM64 policy'
done
assert_line "$BUILD/airdcpp-configure-summary.txt" \
  'source.file_prefix_map=airdcpp-core' 'configured source prefix-map policy'
for expected in BUILD_SHARED_LIBS:BOOL=OFF CMAKE_BUILD_TYPE:STRING=Release \
    CMAKE_CXX_EXTENSIONS:UNINITIALIZED=OFF CMAKE_CXX_STANDARD:STRING=20 \
    CMAKE_OSX_ARCHITECTURES:STRING=arm64 CMAKE_OSX_DEPLOYMENT_TARGET:STRING=14.0 \
    ENABLE_NATPMP:BOOL=OFF ENABLE_TBB:BOOL=OFF; do
  assert_line "$BUILD/CMakeCache.txt" "$expected" 'CMake cache policy'
done

formulae=$(sed -n '/^formula\./p' "$BUILD/host-inventory.txt")
[ -n "$formulae" ] || fail 'missing host formula inventory'
formula_hash=$(printf '%s\n' "$formulae" | shasum -a 256)
assert_line "$BUILD/build-inputs.txt" "formula.inventory.sha256=${formula_hash%% *}" 'formula input fingerprint'

if [ -e "$BUILD/attempts" ] || [ -L "$BUILD/attempts" ]; then
  [ -d "$BUILD/attempts" ] && [ ! -L "$BUILD/attempts" ] || fail 'unsafe attempts directory'
  attempts=$(find "$BUILD/attempts" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort) ||
    fail 'failed to list preserved attempts'
  while IFS= read -r attempt; do
    [ -n "$attempt" ] || continue
    [ -d "$attempt" ] && [ ! -L "$attempt" ] || fail "unsafe preserved attempt: $attempt"
    [ -f "$attempt/sha256.txt" ] && [ ! -L "$attempt/sha256.txt" ] ||
      fail "missing preserved attempt manifest: $attempt"
    (cd "$attempt" && shasum -a 256 -c sha256.txt >/dev/null) ||
      fail "preserved attempt evidence changed: $attempt"
  done <<EOF
$attempts
EOF
fi

[ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] && [ -s "$ARCHIVE" ] || fail 'missing or unsafe Core archive'
case "$(/usr/bin/file -b "$ARCHIVE")" in
  *'ar archive'*) ;;
  *) fail 'Core output is not an ar archive' ;;
esac
assert_eq "$(/usr/bin/lipo -archs "$ARCHIVE")" arm64 'archive architecture'
xcrun nm -g "$ARCHIVE" >/dev/null || fail 'archive symbol inventory failed'

[ -s "$BUILD/archive-members.tsv" ] || fail 'empty archive member report'
awk -F '\t' 'NF != 4 || $1 != NR || $3 !~ /^[0-9a-f]{64}$/ || $4 != "arm64" {exit 1}' \
  "$BUILD/archive-members.tsv" || fail 'malformed or non-arm64 member report'
TEMP=$(mktemp -d /private/tmp/airdc-gate3.XXXXXX) || fail 'failed to create verification scratch'
trap 'rm -rf -- "$TEMP"' 0 1 2 15
python3 "$ROOT/scripts/lib/inspect_core_archive.py" "$ARCHIVE" \
  "$TEMP/members.tsv" "$TEMP/symbols.txt" || fail 'independent archive inspection failed'
/usr/bin/strings "$ARCHIVE" > "$TEMP/strings.txt" || fail 'independent archive string inspection failed'
(cd "$BUILD" && shasum -a 256 upstream/libairdcpp.a) > "$TEMP/archive-sha256.txt" ||
  fail 'independent archive hash failed'
/usr/bin/ar -t "$ARCHIVE" > "$TEMP/archive-ar-table.txt" || fail 'independent archive table failed'
cmp -s "$BUILD/archive-members.tsv" "$TEMP/members.tsv" || fail 'archive member report differs from actual archive'
cmp -s "$BUILD/archive-symbols.txt" "$TEMP/symbols.txt" || fail 'archive symbol report differs from actual archive'
cmp -s "$BUILD/archive-strings.txt" "$TEMP/strings.txt" || fail 'archive string report differs from actual archive'
cmp -s "$BUILD/archive-sha256.txt" "$TEMP/archive-sha256.txt" || fail 'archive hash report differs from actual archive'
cmp -s "$BUILD/archive-ar-table.txt" "$TEMP/archive-ar-table.txt" || fail 'archive table report differs from actual archive'
if grep -F "$ROOT" "$TEMP/strings.txt" >/dev/null 2>&1 ||
    { [ -n "${HOME:-}" ] && grep -F "$HOME/" "$TEMP/strings.txt" >/dev/null 2>&1; } ||
    grep -Eq '/(Source|Build)/' "$TEMP/strings.txt"; then
  fail 'archive contains an absolute home, Source, or Build path'
fi

assert_eq "$(git -C "$ROOT" ls-files Source Dependencies Build Dist)" '' 'no generated paths tracked'
[ ! -e "$ROOT/Dependencies" ] && [ ! -L "$ROOT/Dependencies" ] || fail 'Dependencies unexpectedly exists'
[ ! -e "$ROOT/Dist" ] && [ ! -L "$ROOT/Dist" ] || fail 'Dist unexpectedly exists'

# Check that this acceptance test itself has not changed any parent, source, or
# historical Gate 2 evidence. The original build script also compared these
# boundaries before and after each compile attempt.
assert_eq "$(configure_tree_snapshot "$ROOT")" "$before_parent" 'parent scope after gate'
assert_eq "$(configure_upstream_snapshot "$CHECKOUT")" "$before_source" 'upstream scope after gate'
assert_eq "$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 ! -name core-release -print | LC_ALL=C sort)" \
  "$before_preserved" 'Gate 2 directories after gate'

printf 'PASS: Gate 3 verified %s arm64 Core archive members without packaging\n' \
  "$(wc -l < "$BUILD/archive-members.tsv" | tr -d ' ')"
