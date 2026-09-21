#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
WORK=$(new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
FAKE_BIN=$WORK/bin
mkdir -p "$FAKE_BIN"
REAL_FIND=$(command -v find)
export REAL_FIND
write_fake() { tool=$1; shift; printf '%s\n' '#!/bin/sh' "$@" > "$FAKE_BIN/$tool"; chmod +x "$FAKE_BIN/$tool"; }
write_fake uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac'
write_fake sw_vers 'printf "ProductName:\tmacOS\nProductVersion:\t26.5.1\nBuildVersion:\t25F80\n"'
write_fake xcodebuild 'printf "Xcode 26.6\nBuild version 17F113\n"'
write_fake xcrun 'case "$*" in' \
 '"clang --version") echo "${FAKE_CLANG_VERSION:-Apple clang version 21.0.0}" ;;' \
 '"--find clang") echo /Applications/Xcode.app/usr/bin/clang ;;' \
 '"--find clang++") echo /Applications/Xcode.app/usr/bin/clang++ ;;' \
 '"--sdk macosx --show-sdk-path") echo /Applications/Xcode.app/MacOSX.sdk ;;' \
 '"--sdk macosx --show-sdk-version") echo 26.5 ;; *) exit 64 ;; esac'
write_fake python3 'echo "Python 3.14.3"'
write_fake find 'if [ "${1:-}" = . ]; then' \
 ' case "${FAIL_SNAPSHOT_SCAN:-}" in' \
 ' initial) printf "./CMakeLists.txt\n"; exit 71 ;;' \
 ' final) if grep -q -- --fresh "$FAKE_CMAKE_CALLS" 2>/dev/null; then printf "./CMakeLists.txt\n"; exit 71; fi ;;' \
 ' esac; fi' 'exec "$REAL_FIND" "$@"'
write_fake brew 'case "$1:${2:-}" in' \
 '--prefix:) echo /opt/homebrew ;; --prefix:*) echo /opt/homebrew/opt/$2 ;;' \
 '--version:) echo "Homebrew 6.0.14" ;;' \
 'list:--versions) [ "${FAKE_MISSING:-}" != "$3" ] || exit 1; case "$3" in libnatpmp|tbb) exit 1 ;; esac; echo "$3 ${FAKE_FORMULA_VERSION:-1.0.0}" ;;' \
 '*) exit 64 ;; esac'
write_fake cmake 'set -eu' \
 'case "${1:-}" in --version) echo "cmake version ${FAKE_CMAKE_VERSION:-3.31.6}"; exit 0 ;; -N) cat "$3/CMakeCache.txt"; exit 0 ;; esac' \
 'printf "%s\n" "$*" >> "$FAKE_CMAKE_CALLS"' \
 'case " $* " in *" --build "*) echo "forbidden build invocation" >&2; exit 97 ;; esac' \
 'source_dir=' 'build_dir=' \
 'while [ "$#" -gt 0 ]; do' \
 '  case "$1" in -S) source_dir=$2; shift 2 ;; -B) build_dir=$2; shift 2 ;; *) shift ;; esac' 'done' \
 'mkdir -p "$build_dir"' \
 'case "$source_dir" in' \
 ' */Source/airdcpp-core) echo "unknown CMake command CHECK_FUNCTION_EXISTS"; exit 1 ;;' \
 ' *) [ "${FAKE_FINAL_FAILURE:-0}" = 0 ] || { echo "final failure"; exit 2; }' \
 ' printf "CMAKE_BUILD_TYPE:STRING=Release\n" > "$build_dir/CMakeCache.txt"' \
 ' printf "architecture=arm64\ndeployment_target=14.0\nbuild_shared_libs=OFF\n" > "$build_dir/airdcpp-configure-summary.txt"' \
 ' case "${FAKE_MUTATION:-}" in' \
 ' ignored) echo rogue > "$source_dir/Dist/rogue" ;;' \
 ' origin) git -C "$source_dir/Source/airdcpp-core" remote set-url origin file:///wrong ;;' \
 ' generated) mkdir -p "$source_dir/Source/airdcpp-core/airdcpp/core"; echo changed > "$source_dir/Source/airdcpp-core/airdcpp/core/version.inc" ;;' \
 ' unknown) echo rogue > "$source_dir/Source/airdcpp-core/EN_Example.xml" ;;' \
 ' staged) git -C "$source_dir" reset -q -- CMakeLists.txt ;;' \
 ' head) git -C "$source_dir/Source/airdcpp-core" checkout -q --detach "$FAKE_OTHER_HEAD" ;;' \
 ' dependencies) mkdir -p "$source_dir/Dependencies" ;;' \
 ' esac ;; esac'
write_fake ninja '[ "${1:-}" != --version ] || { echo 1.12.1; exit 0; }' 'echo "forbidden Phase 3 tool invocation" >&2' 'exit 97'
for forbidden_tool in clang clang++ ar libtool; do
 write_fake "$forbidden_tool" 'echo "forbidden Phase 3 tool invocation" >&2' 'exit 97'
done
create_remote_fixture "$WORK/fixture"
# The fixture needs the source hash that immutable capture records.
printf 'project(fixture)\n' > "$WORK/fixture/seed/CMakeLists.txt"
git -C "$WORK/fixture/seed" add CMakeLists.txt
git -C "$WORK/fixture/seed" commit -q -m cmake
FIXTURE_PIN=$(git -C "$WORK/fixture/seed" rev-parse HEAD)
git -C "$WORK/fixture/seed" push -q "$FIXTURE_URL" HEAD:refs/heads/configure
new_case() {
 CASE_ROOT=$WORK/case-$1
 mkdir -p "$CASE_ROOT"
 git -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$CASE_ROOT"
 # Include the new entry point/test-era helper edits before their commit.
 [ ! -f "$ROOT/scripts/build" ] || cp "$ROOT/scripts/build" "$CASE_ROOT/scripts/build"
 cp "$ROOT/scripts/lib/configure.sh" "$CASE_ROOT/scripts/lib/configure.sh"
 printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' "$FIXTURE_URL" "$FIXTURE_PIN" > "$CASE_ROOT/config/upstream.env"
 git -C "$CASE_ROOT" init -q
 git -C "$CASE_ROOT" add .
 mkdir -p "$CASE_ROOT/Source"
 git clone -q "$FIXTURE_URL" "$CASE_ROOT/Source/airdcpp-core"
 git -C "$CASE_ROOT/Source/airdcpp-core" checkout -q --detach "$FIXTURE_PIN"
 FAKE_CMAKE_CALLS=$CASE_ROOT/Build/calls.txt
 mkdir -p "$CASE_ROOT/Build"
 # The trace itself is deliberately outside the project scope snapshot.
 FAKE_CMAKE_CALLS=$WORK/calls-$1.txt
 export FAKE_CMAKE_CALLS
}
run_case() { PATH="$FAKE_BIN:$PATH" "$CASE_ROOT/scripts/build" --configure-only; }
expect_failure() {
 expected=$1; shift
 if output=$("$@" 2>&1); then fail "$expected unexpectedly succeeded"; fi
 assert_contains "$output" "$expected" "$expected diagnostic"
}
gate_capture_preconditions() (
 . "$ROOT/scripts/lib/configure.sh"
 BUILD=$CASE_ROOT/Build/airdcpp-core
 CHECKOUT=$CASE_ROOT/Source/airdcpp-core
 INVENTORY=$BUILD/evidence/host-inventory.txt
 assert_unmodified_capture
)
new_case success
# Failed external probes must fail the real snapshot even when they emit
# plausible partial output, including when called under an if/|| context.
snapshot_failures=0
for probe in find sort stat shasum readlink; do
 ln -sf config/upstream.env "$CASE_ROOT/snapshot-link"
 if output=$(PROBE=$probe sh -c '
   . "$1"
   case "$PROBE" in
     find) find() { printf "./CMakeLists.txt\n"; return 71; } ;;
     sort) sort() { printf "./CMakeLists.txt\n"; return 72; } ;;
     stat) stat() { printf "1:1:1\n"; return 73; } ;;
     shasum) shasum() { printf "bad  file\n"; return 74; } ;;
     readlink) readlink() { printf "partial\n"; return 75; } ;;
   esac
   configure_tree_snapshot "$2"
 ' sh "$ROOT/scripts/lib/configure.sh" "$CASE_ROOT" 2>&1); then
   printf 'FAIL: snapshot accepted failed %s probe\n' "$probe" >&2
   snapshot_failures=$((snapshot_failures + 1))
 fi
done
rm "$CASE_ROOT/snapshot-link"
mkdir -p "$CASE_ROOT/Source/airdcpp-core/airdcpp/core"
printf generated > "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/version.inc"
for probe in stat shasum; do
 if output=$(PROBE=$probe sh -c '
   . "$1"
   case "$PROBE" in
     stat) stat() { printf "1:1:1\n"; return 73; } ;;
     shasum) shasum() { printf "bad  file\n"; return 74; } ;;
   esac
   configure_upstream_snapshot "$2"
 ' sh "$ROOT/scripts/lib/configure.sh" "$CASE_ROOT/Source/airdcpp-core" 2>&1); then
   printf 'FAIL: upstream snapshot accepted failed %s probe\n' "$probe" >&2
   snapshot_failures=$((snapshot_failures + 1))
 fi
done
rm "$CASE_ROOT/Source/airdcpp-core/airdcpp/core/version.inc"
for phase in parent upstream; do
 if output=$(PHASE=$phase sh -c '
   . "$1"
   configure_tree_snapshot() { printf parent; [ "$PHASE" != parent ]; }
   configure_upstream_snapshot() { printf upstream; [ "$PHASE" != upstream ]; }
   assert_configure_scope "$2" parent upstream
 ' sh "$ROOT/scripts/lib/configure.sh" "$CASE_ROOT" 2>&1); then
   printf 'FAIL: scope accepted failed %s snapshot\n' "$phase" >&2
   snapshot_failures=$((snapshot_failures + 1))
 fi
done
[ "$snapshot_failures" -eq 0 ] || fail "$snapshot_failures unverifiable snapshot checks succeeded"
expect_failure 'usage: scripts/build (--configure-only|--build-core|--link-consumer)' "$CASE_ROOT/scripts/build"
expect_failure 'unsupported build mode' "$CASE_ROOT/scripts/build" --compile
output=$(run_case)
assert_contains "$output" 'preserved unmodified configure status 1' 'first capture'
assert_contains "$output" 'configure-only Gate 2 candidate succeeded; no compilation was invoked' 'success'
assert_file_present "$CASE_ROOT/Build/airdcpp-core/unmodified/configure.log"
assert_file_present "$CASE_ROOT/Build/airdcpp-core/release/CMakeCache.txt"
assert_file_absent "$CASE_ROOT/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt"
gate_capture_preconditions
cp "$CASE_ROOT/Build/airdcpp-core/unmodified/inputs.txt" "$WORK/full-inputs.txt"
printf 'cmake.version=wrong\n' >> "$CASE_ROOT/Build/airdcpp-core/unmodified/inputs.txt"
expect_failure 'unmodified capture inputs do not match' gate_capture_preconditions
cp "$WORK/full-inputs.txt" "$CASE_ROOT/Build/airdcpp-core/unmodified/inputs.txt"
before=$(find "$CASE_ROOT/Build/airdcpp-core/unmodified" -type f -exec shasum -a 256 {} \;)
inventory=$(cat "$CASE_ROOT/Build/airdcpp-core/evidence/host-inventory.txt")
output=$(run_case)
assert_contains "$output" 'reusing preserved unmodified configure' 'reuse'
assert_file_absent "$CASE_ROOT/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt"
gate_capture_preconditions
assert_eq "$(find "$CASE_ROOT/Build/airdcpp-core/unmodified" -type f -exec shasum -a 256 {} \;)" "$before" 'immutable capture'
assert_eq "$(grep -c -- '-S .*Source/airdcpp-core' "$FAKE_CMAKE_CALLS")" 1 'single raw invocation'
assert_eq "$(wc -l < "$FAKE_CMAKE_CALLS" | tr -d ' ')" 3 'two wrapper invocations'
assert_contains "$(tail -1 "$FAKE_CMAKE_CALLS")" '--fresh' 'fresh wrapper'
assert_contains "$(tail -1 "$FAKE_CMAKE_CALLS")" '-DENABLE_NATPMP=OFF -DENABLE_TBB=OFF' 'optional policy'
assert_eq "$(cat "$CASE_ROOT/Build/airdcpp-core/evidence/host-inventory.txt")" "$inventory" 'stable inventory'
assert_dir_absent "$CASE_ROOT/Dist"
assert_file_absent "$CASE_ROOT/Build/airdcpp-core/release/libairdcpp.a"
FAKE_FORMULA_VERSION=2.0.0; export FAKE_FORMULA_VERSION
expect_failure 'archive or remove Build/airdcpp-core/unmodified before recapturing changed inputs' run_case
unset FAKE_FORMULA_VERSION
assert_eq "$(find "$CASE_ROOT/Build/airdcpp-core/unmodified" -type f -exec shasum -a 256 {} \;)" "$before" 'changed-input immutable capture'
new_case missing
FAKE_MISSING=boost; export FAKE_MISSING
expect_failure 'missing required Homebrew formulae' run_case
unset FAKE_MISSING
new_case wrong
git -C "$CASE_ROOT/Source/airdcpp-core" checkout -q --detach "$FIXTURE_LATER"
expect_failure 'checkout HEAD does not match' run_case
new_case dirty
printf dirty >> "$CASE_ROOT/Source/airdcpp-core/state.txt"
expect_failure 'unsafe local changes' run_case
new_case compiler
FAKE_CLANG_VERSION='clang version 21'; export FAKE_CLANG_VERSION
expect_failure 'did not resolve Apple Clang' run_case
unset FAKE_CLANG_VERSION
new_case final
FAKE_FINAL_FAILURE=1; export FAKE_FINAL_FAILURE
expect_failure 'wrapper configure failed' run_case
assert_contains "$output" '/release/configure.log' 'failure log'
unset FAKE_FINAL_FAILURE
new_case symlink
mkdir "$WORK/outside"
ln -s "$WORK/outside" "$CASE_ROOT/Build/airdcpp-core"
expect_failure 'refusing symlinked Build/airdcpp-core' run_case
new_case dist
mkdir -p "$CASE_ROOT/Dist"
printf existing > "$CASE_ROOT/Dist/existing"
dist_before=$(stat -f '%m:%z' "$CASE_ROOT/Dist/existing")
run_case >/dev/null
assert_eq "$(cat "$CASE_ROOT/Dist/existing")" existing 'preserved Dist content'
assert_eq "$(stat -f '%m:%z' "$CASE_ROOT/Dist/existing")" "$dist_before" 'preserved Dist metadata'
FAKE_OTHER_HEAD=$FIXTURE_LATER; export FAKE_OTHER_HEAD
for mutation in ignored origin generated unknown staged head dependencies; do
 new_case "$mutation"
 [ "$mutation" != ignored ] || mkdir -p "$CASE_ROOT/Dist"
 FAKE_MUTATION=$mutation; export FAKE_MUTATION
 expect_failure 'configure scope changed' run_case
 unset FAKE_MUTATION
done
# Original Task2 schema must be usable without rewriting its eight input lines.
new_case legacy
mkdir -p "$CASE_ROOT/Build/airdcpp-core/unmodified" "$CASE_ROOT/Build/airdcpp-core/evidence"
# Copy the already verified inventory; its generated fields are both absent.
printf '%s\n' "$inventory" > "$CASE_ROOT/Build/airdcpp-core/evidence/host-inventory.txt"
legacy=$CASE_ROOT/Build/airdcpp-core/unmodified
printf 'original command\n' > "$legacy/command.txt"
printf 'original log\n' > "$legacy/configure.log"
printf '1\n' > "$legacy/exit-code.txt"
printf 'upstream.commit=%s\nupstream.cmakelists.sha256=%s\nupstream.pre_status=clean\nupstream.post_status=clean\ngenerated.airdcpp/core/version.inc.pre=absent\ngenerated.airdcpp/core/version.inc.post=absent\ngenerated.airdcpp/core/localization/StringDefs.cpp.pre=absent\ngenerated.airdcpp/core/localization/StringDefs.cpp.post=absent\n' \
 "$FIXTURE_PIN" "$(shasum -a 256 "$CASE_ROOT/Source/airdcpp-core/CMakeLists.txt" | cut -d ' ' -f1)" > "$legacy/inputs.txt"
printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3\nCMAKE_CACHE_MINOR_VERSION:INTERNAL=31\nCMAKE_CACHE_PATCH_VERSION:INTERNAL=6\nCMAKE_OSX_ARCHITECTURES:STRING=arm64\nCMAKE_OSX_DEPLOYMENT_TARGET:STRING=14.0\n' > "$legacy/CMakeCache.txt"
legacy_before=$(find "$legacy" -type f -exec shasum -a 256 {} \;)
expect_failure 'expected existing path:' gate_capture_preconditions
run_case >/dev/null
assert_file_present "$CASE_ROOT/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt"
gate_capture_preconditions
cp "$CASE_ROOT/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt" "$WORK/valid-sidecar.txt"
printf 'cmake.version=wrong\n' >> "$CASE_ROOT/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt"
expect_failure 'unmodified capture inputs do not match' gate_capture_preconditions
cp "$WORK/valid-sidecar.txt" "$CASE_ROOT/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt"
assert_eq "$(find "$legacy" -type f -exec shasum -a 256 {} \;)" "$legacy_before" 'legacy immutable files'
FAKE_CMAKE_VERSION=3.32.0; export FAKE_CMAKE_VERSION
expect_failure 'archive or remove Build/airdcpp-core/unmodified before recapturing changed inputs' run_case
unset FAKE_CMAKE_VERSION
sidecar=$CASE_ROOT/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt
sidecar_before=$(shasum -a 256 "$sidecar")
run_case >/dev/null
assert_eq "$(shasum -a 256 "$sidecar")" "$sidecar_before" 'one-time sidecar'
cp "$legacy/inputs.txt" "$WORK/legacy-inputs.txt"
printf 'upstream.commit=wrong\n' > "$legacy/inputs.txt"
expect_failure 'archive or remove Build/airdcpp-core/unmodified before recapturing changed inputs' run_case
cp "$WORK/legacy-inputs.txt" "$legacy/inputs.txt"
rm "$sidecar" "$legacy/CMakeCache.txt"
expect_failure 'archive or remove Build/airdcpp-core/unmodified before recapturing changed inputs' run_case
new_case partial
mkdir -p "$CASE_ROOT/Build/airdcpp-core/unmodified"
printf partial > "$CASE_ROOT/Build/airdcpp-core/unmodified/configure.log"
expect_failure 'archive or remove Build/airdcpp-core/unmodified before recapturing changed inputs' run_case
new_case output-symlink
mkdir -p "$CASE_ROOT/Build/airdcpp-core/release"
printf external > "$WORK/external-cache"
ln -s "$WORK/external-cache" "$CASE_ROOT/Build/airdcpp-core/release/CMakeCache.txt"
expect_failure 'refusing symlinked wrapper output' run_case
assert_eq "$(cat "$WORK/external-cache")" external 'external symlink target preserved'
for phase in initial final; do
 new_case snapshot-$phase
 FAIL_SNAPSHOT_SCAN=$phase; export FAIL_SNAPSHOT_SCAN
 expect_failure "failed to capture $phase parent scope snapshot" run_case
 unset FAIL_SNAPSHOT_SCAN
done
printf 'PASS: configure-only build orchestration\n'
