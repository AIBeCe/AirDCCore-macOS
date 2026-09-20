#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
# /var is a macOS system symlink; archive report guards require a physical parent.
WORK=$(TMPDIR=/private/tmp new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
FAKE_BIN=$WORK/bin
mkdir -p "$FAKE_BIN"

printf 'int air_dccore_fixture(void) { return 1; }\n' > "$WORK/tiny.c"
xcrun clang -c -arch arm64 "$WORK/tiny.c" -o "$WORK/tiny.o"
/usr/bin/libtool -static -o "$WORK/libfixture.a" "$WORK/tiny.o" >/dev/null
FAKE_ARCHIVE=$WORK/libfixture.a
FAKE_CMAKE_CALLS=$WORK/cmake-calls.txt
export FAKE_ARCHIVE FAKE_CMAKE_CALLS

write_fake() { tool=$1; shift; printf '%s\n' '#!/bin/sh' "$@" > "$FAKE_BIN/$tool"; chmod +x "$FAKE_BIN/$tool"; }
write_fake uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 64 ;; esac'
write_fake sw_vers 'printf "ProductName:\tmacOS\nProductVersion:\t26.5.1\nBuildVersion:\t25F80\n"'
write_fake xcodebuild 'printf "Xcode 26.6\nBuild version 17F113\n"'
write_fake xcrun 'case "$*" in' \
  '"clang --version") echo "Apple clang version 21.0.0" ;;' \
  '"--find clang") echo /Applications/Xcode.app/usr/bin/clang ;;' \
  '"--find clang++") echo /Applications/Xcode.app/usr/bin/clang++ ;;' \
  '"--sdk macosx --show-sdk-path") echo /Applications/Xcode.app/MacOSX.sdk ;;' \
  '"--sdk macosx --show-sdk-version") echo 26.5 ;;' \
  '"nm -g "*) exec /usr/bin/xcrun "$@" ;;' \
  '*) exit 64 ;; esac'
REAL_PYTHON=$(command -v python3)
export REAL_PYTHON
write_fake python3 'case "${1:-}" in --version) echo "Python 3.14.7" ;; *) exec "$REAL_PYTHON" "$@" ;; esac'
write_fake brew 'case "$1:${2:-}" in' \
  '"--prefix:") echo /opt/homebrew ;;' \
  '--prefix:*) echo "/opt/homebrew/opt/$2" ;;' \
  '"--version:") echo "Homebrew 7.0.4" ;;' \
  '"list:--versions") case "$3" in libnatpmp|tbb) exit 1 ;; esac; echo "$3 ${FAKE_FORMULA_VERSION:-1.0.0}" ;;' \
  '*) exit 64 ;; esac'
sh -n "$FAKE_BIN/brew"
assert_eq "$("$FAKE_BIN/brew" list --versions cmake)" 'cmake 1.0.0' 'fake formula inventory'
assert_eq "$("$FAKE_BIN/brew" --prefix cmake)" '/opt/homebrew/opt/cmake' 'fake formula prefix'
write_fake ninja '[ "$1" = --version ] && { echo "${FAKE_NINJA_VERSION:-1.13.2}"; exit 0; }; exit 97'
write_fake cmake 'set -eu' \
  'case "${1:-}" in' \
  '  --version) echo "cmake version ${FAKE_CMAKE_VERSION:-4.4.3}"; exit 0 ;;' \
  '  -N) cat "$3/CMakeCache.txt"; exit 0 ;;' \
  '  --build)' \
  '    printf "%s\n" "$*" >> "$FAKE_CMAKE_CALLS"' \
  '    [ "${FAKE_BUILD_FAIL:-0}" = 0 ] || { echo "deliberate compile failure" >&2; exit 29; }' \
  '    mkdir -p "$2/upstream"' \
  '    cp "$FAKE_ARCHIVE" "$2/upstream/libairdcpp.a"' \
  '    exit 0 ;;' \
  'esac' \
  'printf "%s\n" "$*" >> "$FAKE_CMAKE_CALLS"' \
  'build_dir=' \
  'while [ "$#" -gt 0 ]; do case "$1" in -B) build_dir=$2; shift 2 ;; *) shift ;; esac; done' \
  'mkdir -p "$build_dir"' \
  'printf "CMAKE_BUILD_TYPE:STRING=Release\n" > "$build_dir/CMakeCache.txt"' \
  'printf "architecture=arm64\nbuild_type=Release\n" > "$build_dir/airdcpp-configure-summary.txt"'

create_remote_fixture "$WORK/fixture"
printf 'project(fixture)\n' > "$WORK/fixture/seed/CMakeLists.txt"
git -C "$WORK/fixture/seed" add CMakeLists.txt
git -C "$WORK/fixture/seed" commit -q -m cmake
FIXTURE_PIN=$(git -C "$WORK/fixture/seed" rev-parse HEAD)
git -C "$WORK/fixture/seed" push -q "$FIXTURE_URL" HEAD:refs/heads/core

new_case() {
  CASE_ROOT=$WORK/case-$1
  mkdir -p "$CASE_ROOT"
  git -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$CASE_ROOT"
  cp "$ROOT/scripts/build" "$CASE_ROOT/scripts/build"
  [ ! -f "$ROOT/scripts/lib/core_build.sh" ] || cp "$ROOT/scripts/lib/core_build.sh" "$CASE_ROOT/scripts/lib/core_build.sh"
  [ ! -f "$ROOT/scripts/lib/inspect_core_archive.py" ] || cp "$ROOT/scripts/lib/inspect_core_archive.py" "$CASE_ROOT/scripts/lib/inspect_core_archive.py"
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
  : > "$FAKE_CMAKE_CALLS"
}
run_core() { PATH="$FAKE_BIN:$PATH" "$CASE_ROOT/scripts/build" --build-core; }
expect_failure() {
  wanted=$1; shift
  if output=$("$@" 2>&1); then fail "expected failure: $wanted"; fi
  assert_contains "$output" "$wanted" 'failure diagnostic'
}

new_case success
output=$(run_core)
assert_contains "$output" 'build: core archive candidate=' 'core mode result'
assert_contains "$(cat "$FAKE_CMAKE_CALLS")" '--target airdcpp --config Release --parallel 2' 'target-only build'
assert_file_present "$CASE_ROOT/Build/airdcpp-core/core-release/upstream/libairdcpp.a"
assert_file_absent "$CASE_ROOT/Build/airdcpp-core/release/upstream/libairdcpp.a"
assert_dir_absent "$CASE_ROOT/Dist"
assert_dir_absent "$CASE_ROOT/Dependencies"
assert_line "$CASE_ROOT/Build/airdcpp-core/core-release/build-exit-code.txt" 0 'build exit'
assert_file_present "$CASE_ROOT/Build/airdcpp-core/core-release/first-build-state.txt"
assert_file_present "$CASE_ROOT/Build/airdcpp-core/core-release/build-inputs.txt"
assert_contains "$(cat "$CASE_ROOT/Build/airdcpp-core/core-release/build-inputs.txt")" \
  'host.toolchain.inventory.sha256=' 'complete toolchain fingerprint'
MEMBERS=$CASE_ROOT/Build/airdcpp-core/core-release/archive-members.tsv
SYMBOLS=$CASE_ROOT/Build/airdcpp-core/core-release/archive-symbols.txt
assert_file_present "$MEMBERS"
assert_file_present "$SYMBOLS"
assert_eq "$(wc -l < "$MEMBERS" | tr -d ' ')" 1 'one fixture archive member inspected'
assert_contains "$(cat "$MEMBERS")" 'tiny.o' 'fixture member named in report'
assert_contains "$(cat "$SYMBOLS")" '_air_dccore_fixture' 'fixture symbol inventory'
output=$(run_core)
assert_contains "$output" 'build: core archive candidate=' 'safe rerun'
FAKE_NINJA_VERSION=1.13.3; export FAKE_NINJA_VERSION
expect_failure 'build inputs changed' run_core
unset FAKE_NINJA_VERSION
FAKE_CMAKE_VERSION=4.4.4; export FAKE_CMAKE_VERSION
expect_failure 'build inputs changed' run_core
unset FAKE_CMAKE_VERSION
FAKE_FORMULA_VERSION=2.0.0; export FAKE_FORMULA_VERSION
expect_failure 'build inputs changed' run_core
unset FAKE_FORMULA_VERSION

new_case failure
mkdir -p "$CASE_ROOT/Build/airdcpp-core/release"
printf 'Gate 2 evidence\n' > "$CASE_ROOT/Build/airdcpp-core/release/original.txt"
gate2_hash=$(shasum -a 256 "$CASE_ROOT/Build/airdcpp-core/release/original.txt" | cut -d ' ' -f 1)
FAKE_BUILD_FAIL=1; export FAKE_BUILD_FAIL
expect_failure 'Core build failed' run_core
unset FAKE_BUILD_FAIL
assert_line "$CASE_ROOT/Build/airdcpp-core/core-release/build-exit-code.txt" 29 'failed build exit'
assert_contains "$(cat "$CASE_ROOT/Build/airdcpp-core/core-release/build.log")" 'deliberate compile failure' 'preserved build log'
assert_file_absent "$CASE_ROOT/Build/airdcpp-core/core-release/upstream/libairdcpp.a"
assert_dir_absent "$CASE_ROOT/Dist"
FAILED_OUTPUT=$CASE_ROOT/Build/airdcpp-core/core-release
first_log_hash=$(shasum -a 256 "$FAILED_OUTPUT/build.log")
first_log_hash=${first_log_hash%% *}
first_config_hash=$(shasum -a 256 "$FAILED_OUTPUT/configure.log")
first_config_hash=${first_config_hash%% *}
first_inventory_hash=$(shasum -a 256 "$FAILED_OUTPUT/host-inventory.txt")
first_inventory_hash=${first_inventory_hash%% *}
output=$(run_core)
assert_contains "$output" 'build: core archive candidate=' 'successful retry'
ATTEMPT=$FAILED_OUTPUT/attempts/0001
assert_file_present "$ATTEMPT/build-command.txt"
assert_file_present "$ATTEMPT/command.txt"
assert_line "$ATTEMPT/build-exit-code.txt" 29 'preserved failed status'
assert_eq "$(shasum -a 256 "$ATTEMPT/build.log" | cut -d ' ' -f 1)" "$first_log_hash" 'first build log preserved'
assert_eq "$(shasum -a 256 "$ATTEMPT/configure.log" | cut -d ' ' -f 1)" "$first_config_hash" 'first configure log preserved'
assert_eq "$(shasum -a 256 "$ATTEMPT/host-inventory.txt" | cut -d ' ' -f 1)" "$first_inventory_hash" 'first host inventory preserved'
assert_line "$ATTEMPT/sha256.txt" "$first_log_hash  build.log" 'first build log hash recorded'
assert_line "$ATTEMPT/sha256.txt" "$first_config_hash  configure.log" 'first configure log hash recorded'
assert_line "$ATTEMPT/sha256.txt" "$first_inventory_hash  host-inventory.txt" 'first host inventory hash recorded'
assert_line "$FAILED_OUTPUT/build-exit-code.txt" 0 'retry status'
assert_eq "$(shasum -a 256 "$CASE_ROOT/Build/airdcpp-core/release/original.txt" | cut -d ' ' -f 1)" "$gate2_hash" 'Gate 2 sibling unchanged across retry'

new_case attempt-symlink
FAKE_BUILD_FAIL=1; export FAKE_BUILD_FAIL
expect_failure 'Core build failed' run_core
unset FAKE_BUILD_FAIL
output=$(run_core)
ATTEMPT=$CASE_ROOT/Build/airdcpp-core/core-release/attempts/0001
mv "$ATTEMPT/build.log" "$WORK/held-attempt-build.log"
ln -s "$WORK/held-attempt-build.log" "$ATTEMPT/build.log"
expect_failure 'symlinked core output path' run_core

new_case attempt-manifest-omission
FAKE_BUILD_FAIL=1; export FAKE_BUILD_FAIL
expect_failure 'Core build failed' run_core
unset FAKE_BUILD_FAIL
output=$(run_core)
ATTEMPT=$CASE_ROOT/Build/airdcpp-core/core-release/attempts/0001
mv "$ATTEMPT/build.log" "$WORK/held-omitted-build.log"
awk '$2 != "build.log"' "$ATTEMPT/sha256.txt" > "$ATTEMPT/sha256.new"
mv "$ATTEMPT/sha256.new" "$ATTEMPT/sha256.txt"
expect_failure 'previous attempt is incomplete' run_core

new_case attempt-incomplete
FAKE_BUILD_FAIL=1; export FAKE_BUILD_FAIL
expect_failure 'Core build failed' run_core
unset FAKE_BUILD_FAIL
mv "$CASE_ROOT/Build/airdcpp-core/core-release/build.log" "$WORK/held-current-build.log"
expect_failure 'previous attempt is incomplete' run_core
assert_eq "$(find "$CASE_ROOT/Build/airdcpp-core/core-release/attempts" -mindepth 1 -maxdepth 1 -print)" '' 'invalid current evidence leaves no staged attempt'

new_case attempts-conflict
FAKE_BUILD_FAIL=1; export FAKE_BUILD_FAIL
expect_failure 'Core build failed' run_core
unset FAKE_BUILD_FAIL
CONFLICT_OUTPUT=$CASE_ROOT/Build/airdcpp-core/core-release
mkdir -p "$CONFLICT_OUTPUT/attempts"
printf 'conflict\n' > "$CONFLICT_OUTPUT/attempts/0001"
expect_failure 'attempts' run_core
assert_contains "$(cat "$CONFLICT_OUTPUT/build.log")" 'deliberate compile failure' 'conflicting attempt did not rewrite log'

new_case symlink
mkdir -p "$CASE_ROOT/Build/airdcpp-core"
ln -s "$WORK" "$CASE_ROOT/Build/airdcpp-core/core-release"
expect_failure 'symlink' run_core

new_case symlink-source
mv "$CASE_ROOT/Source" "$WORK/held-source"
ln -s "$WORK/held-source" "$CASE_ROOT/Source"
expect_failure 'symlinked Source directory' run_core

new_case symlink-build
mkdir -p "$WORK/held-build"
mkdir -p "$CASE_ROOT/Build"
mv "$CASE_ROOT/Build" "$WORK/held-build/Build"
ln -s "$WORK/held-build/Build" "$CASE_ROOT/Build"
expect_failure 'symlinked Build directory' run_core

new_case symlink-build-root
mkdir -p "$CASE_ROOT/Build" "$WORK/held-build-root"
ln -s "$WORK/held-build-root" "$CASE_ROOT/Build/airdcpp-core"
expect_failure 'symlinked Build/airdcpp-core directory' run_core

new_case wrong-head
git -C "$CASE_ROOT/Source/airdcpp-core" checkout -q --detach "$FIXTURE_LATER"
expect_failure 'checkout HEAD does not match' run_core

new_case wrong-origin
git -C "$CASE_ROOT/Source/airdcpp-core" remote set-url origin file:///wrong
expect_failure 'origin URL does not match' run_core

new_case ignored-source
printf 'rogue\n' > "$CASE_ROOT/Source/airdcpp-core/EN_Example.xml"
expect_failure 'unsafe local changes' run_core

printf 'PASS: isolated ARM64 core build orchestration\n'
