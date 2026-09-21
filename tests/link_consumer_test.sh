#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
WORK=$(TMPDIR=/private/tmp new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15

mkdir -p "$WORK/upstream/seed/airdcpp/core" "$WORK/upstream/seed/airdcpp/util" "$WORK/bin"
git -C "$WORK/upstream/seed" init -q
git -C "$WORK/upstream/seed" config user.name 'AirDCCore Tests'
git -C "$WORK/upstream/seed" config user.email 'tests@example.invalid'
git -C "$WORK/upstream/seed" config commit.gpgsign false
printf '/airdcpp/core/version.inc\n/airdcpp/core/localization/StringDefs.cpp\n' > "$WORK/upstream/seed/.gitignore"
printf '%s\n' '#pragma once' '#include <string>' 'using std::string;' > "$WORK/upstream/seed/airdcpp/stdinc.h"
printf '%s\n' '#pragma once' 'namespace dcpp { string getVersionTag() noexcept; }' > "$WORK/upstream/seed/airdcpp/core/version.h"
printf '%s\n' '#pragma once' > "$WORK/upstream/seed/airdcpp/util/Other.h"
git -C "$WORK/upstream/seed" add .
git -C "$WORK/upstream/seed" commit -q -m pinned
FIXTURE_PIN=$(git -C "$WORK/upstream/seed" rev-parse HEAD)
printf '%s\n' '#pragma once' '// later' > "$WORK/upstream/seed/airdcpp/util/Other.h"
git -C "$WORK/upstream/seed" commit -q -am later
FIXTURE_LATER=$(git -C "$WORK/upstream/seed" rev-parse HEAD)
git clone -q --bare "$WORK/upstream/seed" "$WORK/upstream/remote.git"
FIXTURE_URL=file://$WORK/upstream/remote.git

printf '%s\n' 'int fixture_core(void) { return 1; }' > "$WORK/core.c"
xcrun clang -arch arm64 -c "$WORK/core.c" -o "$WORK/core.o"
/usr/bin/libtool -static -o "$WORK/libairdcpp.a" "$WORK/core.o" >/dev/null

cat > "$WORK/bin/cmake" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = --build ]; then
  if [ "${FAKE_MUTATE_SIBLING:-0}" = 1 ]; then
    printf 'changed\n' >> "$FAKE_SIBLING"
  fi
  printf 'Undefined symbols for architecture arm64: _fixture_dependency\n' >&2
  exit 29
fi
build_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -B) build_dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$build_dir" ] || exit 64
mkdir -p "$build_dir"
printf 'configured\n'
EOF
chmod +x "$WORK/bin/cmake"

new_case() {
  CASE_ROOT=$WORK/case-$1
  mkdir -p "$CASE_ROOT"
  git -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$CASE_ROOT"
  cp "$ROOT/scripts/build" "$CASE_ROOT/scripts/build"
  [ ! -f "$ROOT/scripts/lib/link_consumer.sh" ] || cp "$ROOT/scripts/lib/link_consumer.sh" "$CASE_ROOT/scripts/lib/link_consumer.sh"
  printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' "$FIXTURE_URL" "$FIXTURE_PIN" > "$CASE_ROOT/config/upstream.env"
  git -C "$CASE_ROOT" init -q
  git -C "$CASE_ROOT" config user.name 'AirDCCore Tests'
  git -C "$CASE_ROOT" config user.email 'tests@example.invalid'
  git -C "$CASE_ROOT" config commit.gpgsign false
  git -C "$CASE_ROOT" add .
  git -C "$CASE_ROOT" commit -q -m fixture
  mkdir -p "$CASE_ROOT/Source"
  git clone -q "$FIXTURE_URL" "$CASE_ROOT/Source/airdcpp-core"
  git -C "$CASE_ROOT/Source/airdcpp-core" checkout -q --detach "$FIXTURE_PIN"
  mkdir -p "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/localization"
  printf '#define GIT_TAG "fixture"\n' > "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/version.inc"
  printf '// generated\n' > "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/localization/StringDefs.cpp"

  CORE=$CASE_ROOT/Build/airdcpp-core/core-release
  mkdir -p "$CORE/upstream"
  cp "$WORK/libairdcpp.a" "$CORE/upstream/libairdcpp.a"
  printf 'core-release.preexisting=absent\n' > "$CORE/first-build-state.txt"
  printf 'upstream.commit=%s\narchitecture=arm64\n' "$FIXTURE_PIN" > "$CORE/build-inputs.txt"
  printf 'fixture inventory\n' > "$CORE/host-inventory.txt"
  printf 'fixture configure\n' > "$CORE/command.txt"
  printf 'configured\n' > "$CORE/configure.log"
  printf 'fixture cache\n' > "$CORE/cache.txt"
  printf 'architecture=arm64\ndeployment_target=14.0\nbuild_type=Release\ncxx_standard=20\ncxx_extensions=OFF\nenable_natpmp=OFF\nenable_tbb=OFF\n' > "$CORE/airdcpp-configure-summary.txt"
  printf 'fixture build\n' > "$CORE/build-command.txt"
  printf 'built\n' > "$CORE/build.log"
  printf '0\n' > "$CORE/build-exit-code.txt"
  printf 'upstream/libairdcpp.a\n' > "$CORE/.ninja_log"
  python3 "$CASE_ROOT/scripts/lib/inspect_core_archive.py" "$CORE/upstream/libairdcpp.a" \
    "$CORE/archive-members.tsv" "$CORE/archive-symbols.txt"
  mkdir -p "$CASE_ROOT/Build/airdcpp-core/release"
  printf 'Gate 2 evidence\n' > "$CASE_ROOT/Build/airdcpp-core/release/original.txt"
  : > "$CASE_ROOT/Build/airdcpp-core/release/held-hash.txt"
  shasum -a 256 "$CASE_ROOT/Build/airdcpp-core/release/original.txt" | cut -d ' ' -f 1 \
    > "$CASE_ROOT/Build/airdcpp-core/release/held-hash.txt"
}

run_link() { PATH="$WORK/bin:$PATH" "$CASE_ROOT/scripts/build" --link-consumer; }
expect_failure() {
  wanted=$1
  if output=$(run_link 2>&1); then fail "expected link-consumer failure: $wanted"; fi
  assert_contains "$output" "$wanted" 'link-consumer diagnostic'
}

new_case success
output=$(run_link)
assert_contains "$output" 'build: mode=link-consumer' 'mode banner'
LINK_ROOT=$CASE_ROOT/Build/airdcpp-core/link-interface
assert_file_present "$LINK_ROOT/stage/include/airdcpp/core/version.h"
assert_file_present "$LINK_ROOT/stage/include/airdcpp/stdinc.h"
assert_file_present "$LINK_ROOT/stage/lib/libairdcpp.a"
assert_file_present "$LINK_ROOT/header-manifest.sha256"
assert_file_present "$LINK_ROOT/input-manifest.txt"
assert_line "$LINK_ROOT/input-manifest.txt" "upstream.commit=$FIXTURE_PIN" 'staged source pin'
assert_line "$LINK_ROOT/core-only/configure-exit-code.txt" 0 'core-only configure status'
assert_line "$LINK_ROOT/core-only/build-exit-code.txt" 29 'expected unresolved link status'
assert_contains "$(cat "$LINK_ROOT/core-only/build.log")" 'Undefined symbols' 'core-only failure evidence'
assert_dir_absent "$CASE_ROOT/Dist"
assert_dir_absent "$CASE_ROOT/Dependencies"
assert_file_absent "$LINK_ROOT/stage/include/airdcpp/core/localization/StringDefs.cpp"

output=$(run_link)
assert_contains "$output" 'build: mode=link-consumer' 'safe rerun'
ATTEMPT=$LINK_ROOT/core-only/attempts/0001
assert_file_present "$ATTEMPT/sha256.txt"
(cd "$ATTEMPT" && shasum -a 256 -c sha256.txt >/dev/null) || fail 'preserved core-only attempt changed'

new_case wrong-head
git -C "$CASE_ROOT/Source/airdcpp-core" checkout -q --detach "$FIXTURE_LATER"
expect_failure 'checkout HEAD does not match'

new_case wrong-origin
git -C "$CASE_ROOT/Source/airdcpp-core" remote set-url origin file:///wrong
expect_failure 'origin URL does not match'

new_case changed-archive
printf 'changed\n' >> "$CORE/upstream/libairdcpp.a"
expect_failure 'archive member report differs'

new_case missing-gate3
mv "$CORE/build-exit-code.txt" "$WORK/held-build-exit.txt"
expect_failure 'missing Gate 3 evidence'

new_case symlink-source
mv "$CASE_ROOT/Source" "$WORK/held-source"
ln -s "$WORK/held-source" "$CASE_ROOT/Source"
expect_failure 'symlinked Source directory'

new_case symlink-build
mv "$CASE_ROOT/Build" "$WORK/held-build"
ln -s "$WORK/held-build" "$CASE_ROOT/Build"
expect_failure 'symlinked Build directory'

new_case symlink-build-root
mv "$CASE_ROOT/Build/airdcpp-core" "$WORK/held-airdcpp-build"
ln -s "$WORK/held-airdcpp-build" "$CASE_ROOT/Build/airdcpp-core"
expect_failure 'symlinked Build/airdcpp-core directory'

new_case symlink-link-root
ln -s "$WORK" "$CASE_ROOT/Build/airdcpp-core/link-interface"
expect_failure 'symlinked link-interface directory'

new_case symlink-stage
mkdir -p "$CASE_ROOT/Build/airdcpp-core/link-interface"
ln -s "$WORK" "$CASE_ROOT/Build/airdcpp-core/link-interface/stage"
expect_failure 'symlinked link-interface path'

new_case symlink-staged-archive
mkdir -p "$CASE_ROOT/Build/airdcpp-core/link-interface/stage/lib"
ln -s "$WORK/libairdcpp.a" "$CASE_ROOT/Build/airdcpp-core/link-interface/stage/lib/libairdcpp.a"
expect_failure 'symlinked link-interface path'

new_case sibling-mutation
FAKE_MUTATE_SIBLING=1
FAKE_SIBLING=$CASE_ROOT/Build/airdcpp-core/release/original.txt
export FAKE_MUTATE_SIBLING FAKE_SIBLING
expect_failure 'preserved Gate 2/Core evidence changed'
unset FAKE_MUTATE_SIBLING FAKE_SIBLING

printf 'PASS: isolated consumer-link staging and evidence preservation\n'
