#!/bin/sh
set -eu

# Opt-in live negative tests use a copied fixture; never mutate real evidence.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
[ "${AIRDCCORE_RUN_BUILD_TESTS:-0}" = 1 ] ||
  fail 'set AIRDCCORE_RUN_BUILD_TESTS=1 for Gate 3 contract tests'

WORK=$(TMPDIR=/private/tmp new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
CASE=$WORK/case
mkdir -p "$CASE/tests" "$CASE/scripts/lib" "$CASE/config" "$CASE/docs/reports" \
  "$CASE/Source" "$CASE/Build/airdcpp-core/core-release/upstream" "$CASE/Build/airdcpp-core/core-release/attempts"
cp "$ROOT/tests/gate3_core_build_test.sh" "$CASE/tests/gate3_core_build_test.sh"
cp "$ROOT/tests/test_helper.sh" "$CASE/tests/test_helper.sh"
cp "$ROOT/scripts/lib/upstream.sh" "$CASE/scripts/lib/upstream.sh"
cp "$ROOT/scripts/lib/configure.sh" "$CASE/scripts/lib/configure.sh"
cp "$ROOT/scripts/lib/inspect_core_archive.py" "$CASE/scripts/lib/inspect_core_archive.py"
cp "$ROOT/config/upstream.env" "$CASE/config/upstream.env"
cp "$ROOT/docs/reports/2026-09-20-gate-3-arm64-core-build.md" "$CASE/docs/reports/2026-09-20-gate-3-arm64-core-build.md"
printf '/Source/airdcpp-core/\n/Build/\n' > "$CASE/.gitignore"
git -C "$CASE" init -q
git -C "$CASE" config user.name 'AirDCCore Tests'
git -C "$CASE" config user.email 'tests@example.invalid'
git -C "$CASE" config commit.gpgsign false
git -C "$CASE" add .
git -C "$CASE" commit -q -m fixture
cp -R "$ROOT/Source/airdcpp-core" "$CASE/Source/airdcpp-core"

REAL_BUILD=$ROOT/Build/airdcpp-core/core-release
BUILD=$CASE/Build/airdcpp-core/core-release
for evidence in first-build-state.txt build-inputs.txt host-inventory.txt command.txt \
    configure.log cache.txt CMakeCache.txt airdcpp-configure-summary.txt \
    build.log build-exit-code.txt archive-members.tsv archive-symbols.txt \
    archive-strings.txt archive-ar-table.txt archive-sha256.txt .ninja_log; do
  cp "$REAL_BUILD/$evidence" "$BUILD/$evidence"
done
sed "s|$ROOT|$CASE|g" "$REAL_BUILD/build-command.txt" > "$BUILD/build-command.txt"
cp "$REAL_BUILD/upstream/libairdcpp.a" "$BUILD/upstream/libairdcpp.a"
cp -R "$REAL_BUILD/attempts/0001" "$BUILD/attempts/0001"
assert_line "$REAL_BUILD/attempts/0001/build-exit-code.txt" 1 'historical first failed build status'
(cd "$REAL_BUILD/attempts/0001" && shasum -a 256 -c sha256.txt >/dev/null) ||
  fail 'historical first failed build evidence changed'

run_gate() { AIRDCCORE_RUN_BUILD_TESTS=1 sh "$CASE/tests/gate3_core_build_test.sh"; }
expect_gate_failure() {
  wanted=$1
  shift
  if output=$("$@" 2>&1); then fail "Gate 3 accepted $wanted"; fi
  assert_contains "$output" "$wanted" "Gate 3 $wanted diagnostic"
}

output=$(run_gate)
assert_contains "$output" 'PASS: Gate 3 verified 130 arm64 Core archive members' 'copied valid fixture'
mv "$BUILD/attempts/0001" "$WORK/held-first-attempt"
output=$(run_gate)
assert_contains "$output" 'PASS: Gate 3 verified 130 arm64 Core archive members' 'valid clean first build without a failed attempt'
mv "$WORK/held-first-attempt" "$BUILD/attempts/0001"
expect_gate_failure 'set AIRDCCORE_RUN_BUILD_TESTS=1' env AIRDCCORE_RUN_BUILD_TESTS=0 sh "$CASE/tests/gate3_core_build_test.sh"

sed 's/^AIRDCPP_CORE_COMMIT=.*/AIRDCPP_CORE_COMMIT=0000000000000000000000000000000000000000/' \
  "$ROOT/config/upstream.env" > "$CASE/config/upstream.env"
expect_gate_failure 'pinned upstream commit' run_gate
cp "$ROOT/config/upstream.env" "$CASE/config/upstream.env"

mv "$BUILD/upstream/libairdcpp.a" "$BUILD/upstream/archive-held.a"
expect_gate_failure 'missing or unsafe Core archive' run_gate
mv "$BUILD/upstream/archive-held.a" "$BUILD/upstream/libairdcpp.a"

awk -F '\t' 'BEGIN {OFS="\t"} NR==1 {$3="0000000000000000000000000000000000000000000000000000000000000000"} {print}' \
  "$REAL_BUILD/archive-members.tsv" > "$BUILD/archive-members.tsv"
expect_gate_failure 'archive member report differs' run_gate
cp "$REAL_BUILD/archive-members.tsv" "$BUILD/archive-members.tsv"

cp "$BUILD/upstream/libairdcpp.a" "$WORK/valid-libairdcpp.a"
cp "$BUILD/archive-members.tsv" "$WORK/valid-archive-members.tsv"
cp "$BUILD/archive-symbols.txt" "$WORK/valid-archive-symbols.txt"
cp "$BUILD/archive-strings.txt" "$WORK/valid-archive-strings.txt"
cp "$BUILD/archive-ar-table.txt" "$WORK/valid-archive-ar-table.txt"
cp "$BUILD/archive-sha256.txt" "$WORK/valid-archive-sha256.txt"
printf '%s\n' 'const char *leaked_path(void) { return "/Users/example/Source/airdcpp-core/file.cpp"; }' \
  > "$WORK/leak.c"
xcrun clang -arch arm64 -c "$WORK/leak.c" -o "$WORK/leak.o"
/usr/bin/ar rcs "$BUILD/upstream/libairdcpp.a" "$WORK/leak.o"
python3 "$ROOT/scripts/lib/inspect_core_archive.py" "$BUILD/upstream/libairdcpp.a" \
  "$BUILD/archive-members.tsv" "$BUILD/archive-symbols.txt"
/usr/bin/strings "$BUILD/upstream/libairdcpp.a" > "$BUILD/archive-strings.txt"
(cd "$BUILD" && shasum -a 256 upstream/libairdcpp.a) > "$BUILD/archive-sha256.txt"
/usr/bin/ar -t "$BUILD/upstream/libairdcpp.a" > "$BUILD/archive-ar-table.txt"
expect_gate_failure 'archive contains an absolute home, Source, or Build path' run_gate
cp "$WORK/valid-libairdcpp.a" "$BUILD/upstream/libairdcpp.a"
cp "$WORK/valid-archive-members.tsv" "$BUILD/archive-members.tsv"
cp "$WORK/valid-archive-symbols.txt" "$BUILD/archive-symbols.txt"
cp "$WORK/valid-archive-strings.txt" "$BUILD/archive-strings.txt"
cp "$WORK/valid-archive-ar-table.txt" "$BUILD/archive-ar-table.txt"
cp "$WORK/valid-archive-sha256.txt" "$BUILD/archive-sha256.txt"

REAL_PYTHON=$(command -v python3)
export REAL_PYTHON
MUTATION_FILE=$CASE/config/upstream.env
export MUTATION_FILE
mkdir -p "$WORK/bin"
printf '%s\n' '#!/bin/sh' '"$REAL_PYTHON" "$@" || exit $?' \
  'printf "# changed during gate\\n" >> "$MUTATION_FILE"' > "$WORK/bin/python3"
chmod +x "$WORK/bin/python3"
expect_gate_failure 'parent scope after gate' env AIRDCCORE_RUN_BUILD_TESTS=1 PATH="$WORK/bin:$PATH" \
  sh "$CASE/tests/gate3_core_build_test.sh"

printf 'PASS: Gate 3 copied-evidence safety contracts\n'
