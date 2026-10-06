#!/bin/sh
set -eu

# Copied-evidence rejection tests; the real Gate 3/4 outputs are read only.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
[ "${AIRDCCORE_RUN_LINK_TESTS:-0}" = 1 ] ||
  fail 'set AIRDCCORE_RUN_LINK_TESTS=1 for Gate 4 contract tests'

WORK=$(TMPDIR=/private/tmp new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15

REAL_CORE=$ROOT/Build/airdcpp-core/core-release
REAL_LINK=$ROOT/Build/airdcpp-core/link-interface

new_case() {
  name=$1
  CASE=$WORK/case-$name
  mkdir -p "$CASE"
  git -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$CASE"
  cp "$ROOT/tests/gate4_consumer_link_test.sh" "$CASE/tests/gate4_consumer_link_test.sh"
  cp "$ROOT/docs/reports/2026-09-21-gate-4-consumer-link.md" \
    "$CASE/docs/reports/2026-09-21-gate-4-consumer-link.md"
  git -C "$CASE" init -q
  git -C "$CASE" config user.name 'AirDCCore Tests'
  git -C "$CASE" config user.email 'tests@example.invalid'
  git -C "$CASE" config commit.gpgsign false
  git -C "$CASE" add .
  git -C "$CASE" commit -q -m fixture

  mkdir -p "$CASE/Source"
  cp -R "$ROOT/Source/airdcpp-core" "$CASE/Source/airdcpp-core"

  CORE=$CASE/Build/airdcpp-core/core-release
  LINK=$CASE/Build/airdcpp-core/link-interface
  mkdir -p "$CORE/upstream" "$LINK/core-only" "$LINK/full/build" "$LINK/run"
  for evidence in build-inputs.txt build-exit-code.txt archive-members.tsv \
      archive-symbols.txt archive-strings.txt archive-ar-table.txt archive-sha256.txt; do
    cp "$REAL_CORE/$evidence" "$CORE/$evidence"
  done
  cp "$REAL_CORE/upstream/libairdcpp.a" "$CORE/upstream/libairdcpp.a"

  cp -R "$REAL_LINK/stage" "$LINK/stage"
  for evidence in header-manifest.sha256 input-manifest.txt omission-results.tsv \
      link-interface.tsv binary-file.txt binary-arch.txt; do
    cp "$REAL_LINK/$evidence" "$LINK/$evidence"
  done
  sed "1s|$ROOT|$CASE|" "$REAL_LINK/otool-load-commands.txt" > "$LINK/otool-load-commands.txt"
  for evidence in configure-command.txt configure.log configure-exit-code.txt \
      build-command.txt build.log build-exit-code.txt; do
    cp "$REAL_LINK/core-only/$evidence" "$LINK/core-only/$evidence"
    sed "s|$ROOT|$CASE|g" "$REAL_LINK/full/$evidence" > "$LINK/full/$evidence"
  done
  cp "$REAL_LINK/full/airdcpp-smoke" "$LINK/full/airdcpp-smoke"
  cp "$REAL_LINK/full/build/airdcpp-smoke" "$LINK/full/build/airdcpp-smoke"
  sed "s|$ROOT|$CASE|g" "$REAL_LINK/link-command.raw.txt" > "$LINK/link-command.raw.txt"
  cp "$REAL_LINK/run/stdout.txt" "$LINK/run/stdout.txt"
  cp "$REAL_LINK/run/stderr.txt" "$LINK/run/stderr.txt"
  cp "$REAL_LINK/run/exit-code.txt" "$LINK/run/exit-code.txt"
}

run_gate() { AIRDCCORE_RUN_LINK_TESTS=1 sh "$CASE/tests/gate4_consumer_link_test.sh"; }
expect_gate_failure() {
  wanted=$1
  shift
  if output=$("$@" 2>&1); then fail "Gate 4 accepted $wanted"; fi
  assert_contains "$output" "$wanted" "Gate 4 $wanted diagnostic"
}

new_case valid
output=$(run_gate)
assert_contains "$output" 'PASS: Gate 4 verified external ARM64 consumer with 247 staged headers and 7 required link items' \
  'copied valid Gate 4 evidence'
expect_gate_failure 'set AIRDCCORE_RUN_LINK_TESTS=1' env AIRDCCORE_RUN_LINK_TESTS=0 \
  sh "$CASE/tests/gate4_consumer_link_test.sh"

new_case wrong-pin
sed 's/^AIRDCPP_CORE_COMMIT=.*/AIRDCPP_CORE_COMMIT=0000000000000000000000000000000000000000/' \
  "$ROOT/config/upstream.env" > "$CASE/config/upstream.env"
expect_gate_failure 'pinned upstream commit' run_gate

new_case changed-archive
printf 'changed archive\n' >> "$CORE/upstream/libairdcpp.a"
expect_gate_failure 'archive' run_gate

new_case missing-staged-header
first_header=$(find "$LINK/stage/include" -type f -print | LC_ALL=C sort | sed -n '1p')
rm -f -- "$first_header"
expect_gate_failure 'staged header manifest differs' run_gate

new_case substituted-staged-header
substituted_header=$(find "$LINK/stage/include" -type f -name '*.h' -print | LC_ALL=C sort | sed -n '1p')
printf '\n// substituted\n' >> "$substituted_header"
(cd "$LINK/stage/include" && find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done) \
  > "$LINK/header-manifest.sha256"
substituted_manifest_hash=$(shasum -a 256 "$LINK/header-manifest.sha256")
sed "s/^headers.manifest.sha256=.*/headers.manifest.sha256=${substituted_manifest_hash%% *}/" \
  "$LINK/input-manifest.txt" > "$LINK/input-manifest.changed"
mv "$LINK/input-manifest.changed" "$LINK/input-manifest.txt"
expect_gate_failure 'staged headers differ from pinned checkout' run_gate

new_case malformed-omission
sed 's/^1	1	BZip2	required	1$/1	1	BZip2	unknown	1/' \
  "$LINK/omission-results.tsv" > "$LINK/omission-results.changed"
mv "$LINK/omission-results.changed" "$LINK/omission-results.tsv"
expect_gate_failure 'failed to regenerate normalized link interface' run_gate

new_case reordered-interface
awk 'NR == 1 { first=$0; next } NR == 2 { print; print first; next } { print }' \
  "$LINK/link-interface.tsv" > "$LINK/link-interface.changed"
mv "$LINK/link-interface.changed" "$LINK/link-interface.tsv"
expect_gate_failure 'normalized ordered link interface differs' run_gate

new_case x86-executable
printf '%s\n' 'int main(void) { return 0; }' > "$WORK/x86.c"
xcrun clang -arch x86_64 -mmacosx-version-min=14.0 "$WORK/x86.c" -o "$LINK/full/airdcpp-smoke"
cp "$LINK/full/airdcpp-smoke" "$LINK/full/build/airdcpp-smoke"
/usr/bin/file -b "$LINK/full/airdcpp-smoke" > "$LINK/binary-file.txt"
/usr/bin/lipo -archs "$LINK/full/airdcpp-smoke" > "$LINK/binary-arch.txt"
/usr/bin/otool -L "$LINK/full/airdcpp-smoke" > "$LINK/otool-load-commands.txt"
expect_gate_failure 'consumer architecture' run_gate

new_case wrong-runtime
printf 'AirDC++ Core wrong\n' > "$LINK/run/stdout.txt"
expect_gate_failure 'stored consumer identity' run_gate

new_case artifact-path-leak
cat > "$WORK/leak-consumer.cpp" <<'EOF'
#include <iostream>
#include <string>
namespace dcpp {
std::string getVersionTag() noexcept { return {}; }
std::string getGitCommit() noexcept { return "55d51ceb817ec006d4ec844d9e3788e1b0ccc352"; }
}
__attribute__((used)) static const char leaked_path[] =
  "/Users/example/Source/airdcpp-core/file.cpp";
int main() {
  auto identity = dcpp::getVersionTag();
  if (identity.empty()) identity = dcpp::getGitCommit();
  std::cout << "AirDC++ Core " << identity << '\n';
}
EOF
xcrun clang++ -std=c++20 -arch arm64 -mmacosx-version-min=14.0 \
  "$WORK/leak-consumer.cpp" -o "$LINK/full/airdcpp-smoke"
cp "$LINK/full/airdcpp-smoke" "$LINK/full/build/airdcpp-smoke"
/usr/bin/file -b "$LINK/full/airdcpp-smoke" > "$LINK/binary-file.txt"
/usr/bin/lipo -archs "$LINK/full/airdcpp-smoke" > "$LINK/binary-arch.txt"
/usr/bin/otool -L "$LINK/full/airdcpp-smoke" > "$LINK/otool-load-commands.txt"
"$LINK/full/airdcpp-smoke" > "$LINK/run/stdout.txt" 2> "$LINK/run/stderr.txt"
printf '0\n' > "$LINK/run/exit-code.txt"
expect_gate_failure 'consumer artifact or normalized evidence leaks' run_gate

new_case replacement-executable
sed '/leaked_path/d; /Users\/example\/Source/d' "$WORK/leak-consumer.cpp" > "$WORK/replacement-consumer.cpp"
xcrun clang++ -std=c++20 -arch arm64 -mmacosx-version-min=14.0 \
  "$WORK/replacement-consumer.cpp" -o "$LINK/full/airdcpp-smoke"
cp "$LINK/full/airdcpp-smoke" "$LINK/full/build/airdcpp-smoke"
/usr/bin/file -b "$LINK/full/airdcpp-smoke" > "$LINK/binary-file.txt"
/usr/bin/lipo -archs "$LINK/full/airdcpp-smoke" > "$LINK/binary-arch.txt"
/usr/bin/otool -L "$LINK/full/airdcpp-smoke" > "$LINK/otool-load-commands.txt"
"$LINK/full/airdcpp-smoke" > "$LINK/run/stdout.txt" 2> "$LINK/run/stderr.txt"
printf '0\n' > "$LINK/run/exit-code.txt"
expect_gate_failure 'consumer executable SHA-256 differs' run_gate

new_case mutation-during-gate
REAL_PYTHON=$(command -v python3)
export REAL_PYTHON
MUTATION_FILE=$CASE/config/upstream.env
export MUTATION_FILE
mkdir -p "$WORK/bin"
printf '%s\n' '#!/bin/sh' '"$REAL_PYTHON" "$@" || exit $?' \
  'printf "# changed during gate\n" >> "$MUTATION_FILE"' > "$WORK/bin/python3"
chmod +x "$WORK/bin/python3"
expect_gate_failure 'parent scope after Gate 4' env AIRDCCORE_RUN_LINK_TESTS=1 \
  PATH="$WORK/bin:$PATH" sh "$CASE/tests/gate4_consumer_link_test.sh"

printf 'PASS: Gate 4 copied-evidence safety contracts\n'
