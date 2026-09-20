#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
. "$ROOT/scripts/lib/upstream.sh"
. "$ROOT/scripts/lib/configure.sh"

WORK=$(new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
FAKE_BIN=$WORK/bin
mkdir -p "$FAKE_BIN"

write_fake() {
  tool=$1
  shift
  printf '%s\n' '#!/bin/sh' "$@" > "$FAKE_BIN/$tool"
  chmod +x "$FAKE_BIN/$tool"
}

write_fake uname \
  'case "$1" in -s) echo "${FAKE_UNAME_S:-Darwin}" ;; -m) echo "${FAKE_UNAME_M:-arm64}" ;; *) exit 64 ;; esac'
write_fake sw_vers \
  'printf "ProductName:\tmacOS\nProductVersion:\t26.5.1\nBuildVersion:\t25F80\n"'
write_fake xcodebuild \
  'printf "Xcode 26.6\nBuild version 17F113\n"'
write_fake xcrun \
  'case "$*" in' \
  '  "clang --version")' \
  '    printf "%s\n" "${FAKE_CLANG_VERSION:-Apple clang version 21.0.0 (clang-2100.1.1.101)}" \' \
  '      "Target: arm64-apple-darwin25.5.0" "Thread model: posix" \' \
  '      "InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" ;;' \
  '  "--find clang") echo "${FAKE_CLANG_PATH:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang}" ;;' \
  '  "--find clang++") echo "${FAKE_CLANGXX_PATH:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++}" ;;' \
  '  "--sdk macosx --show-sdk-path") echo "${FAKE_SDK_PATH:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk}" ;;' \
  '  "--sdk macosx --show-sdk-version") echo 26.5 ;;' \
  '  *) exit 64 ;;' \
  'esac'
write_fake cmake 'echo "cmake version 3.31.6"'
write_fake ninja 'echo 1.12.1'
write_fake python3 'echo "Python 3.14.3"'
write_fake brew \
  'case "$1:$2" in' \
  '  --prefix:) echo "${FAKE_HOMEBREW_PREFIX:-/opt/homebrew}" ;;' \
  '  --prefix:*)' \
  '    if [ "${FAKE_PREFIX_FAILURE:-}" = "$2" ]; then' \
  '      exit 72' \
  '    elif [ "$2" = boost ] && [ -n "${FAKE_BOOST_PREFIX:-}" ]; then' \
  '      echo "$FAKE_BOOST_PREFIX"' \
  '    elif [ "${FAKE_DUPLICATE_PREFIXES:-0}" = 1 ] && [ "$2" = zlib ]; then' \
  '      echo /opt/homebrew/opt/bzip2' \
  '    else' \
  '      echo "/opt/homebrew/opt/$2"' \
  '    fi ;;' \
  '  --version:) echo "Homebrew 6.0.14" ;;' \
  '  list:--versions)' \
  '    case "$3" in cmake|snappy) exit 1 ;; miniupnpc) echo "miniupnpc 2.3.3" ;; *) echo "$3 1.0.0" ;; esac ;;' \
  '  *) exit 64 ;;' \
  'esac'

required=$(required_formulae)
assert_eq "$required" "cmake
ninja
boost
bzip2
zlib
openssl@3
miniupnpc
leveldb
libmaxminddb
snappy
libiconv
pkgconf
python@3.14" "required formula order"

missing=$(PATH="$FAKE_BIN:$PATH" missing_required_formulae)
assert_eq "$missing" "cmake
snappy" "missing formula order"
if output=$(configure_die "missing required Homebrew formulae: $missing" 2>&1); then
  fail "configure_die unexpectedly succeeded"
fi
assert_contains "$output" 'build: error: configure discovery: missing required Homebrew formulae:' \
  "missing formula diagnostic"
assert_contains "$output" cmake "missing CMake diagnostic"
assert_contains "$output" snappy "missing Snappy diagnostic"

PATH="$FAKE_BIN:$PATH" assert_supported_host
if output=$(FAKE_UNAME_M=x86_64 PATH="$FAKE_BIN:$PATH" assert_supported_host 2>&1); then
  fail "non-arm64 host unexpectedly succeeded"
fi
assert_contains "$output" 'arm64 host is required' "non-arm64 diagnostic"
if output=$(FAKE_UNAME_S=Linux PATH="$FAKE_BIN:$PATH" assert_supported_host 2>&1); then
  fail "non-Darwin host unexpectedly succeeded"
fi
assert_contains "$output" 'macOS is required' "non-Darwin diagnostic"
if output=$(FAKE_CLANG_VERSION='clang version 21.0.0' PATH="$FAKE_BIN:$PATH" \
  assert_supported_host 2>&1); then
  fail "non-Apple compiler unexpectedly succeeded"
fi
assert_contains "$output" 'xcrun did not resolve Apple Clang' "non-Apple compiler diagnostic"

prefixes=$(PATH="$FAKE_BIN:$PATH" dependency_cmake_prefix_path)
assert_contains "$prefixes" /opt/homebrew/opt/boost "Boost prefix"
assert_contains "$prefixes" /opt/homebrew/opt/libiconv "Iconv prefix"
assert_not_contains "$prefixes" libnatpmp "NAT-PMP is not required"
assert_not_contains "$prefixes" tbb "TBB is not required"

deduplicated_prefixes=$(FAKE_DUPLICATE_PREFIXES=1 PATH="$FAKE_BIN:$PATH" \
  dependency_cmake_prefix_path)
assert_eq "$deduplicated_prefixes" \
  '/opt/homebrew/opt/cmake;/opt/homebrew/opt/ninja;/opt/homebrew/opt/boost;/opt/homebrew/opt/bzip2;/opt/homebrew/opt/openssl@3;/opt/homebrew/opt/miniupnpc;/opt/homebrew/opt/leveldb;/opt/homebrew/opt/libmaxminddb;/opt/homebrew/opt/snappy;/opt/homebrew/opt/libiconv;/opt/homebrew/opt/pkgconf;/opt/homebrew/opt/python@3.14' \
  "deduplicated CMake prefix order"

pkg_config_path=$(PATH="$FAKE_BIN:$PATH" dependency_pkg_config_path)
assert_contains "$pkg_config_path" /opt/homebrew/opt/boost/lib/pkgconfig "Boost pkg-config path"
assert_contains "$pkg_config_path" /opt/homebrew/opt/libiconv/share/pkgconfig "Iconv shared pkg-config path"
assert_not_contains "$pkg_config_path" libnatpmp "NAT-PMP pkg-config path omitted"
assert_not_contains "$pkg_config_path" tbb "TBB pkg-config path omitted"

create_remote_fixture "$WORK/fixture"

new_checkout_case() {
  case_name=$1
  CASE_PROJECT=$WORK/project-$case_name
  CASE_CHECKOUT=$CASE_PROJECT/Source/airdcpp-core
  mkdir -p "$CASE_PROJECT/config" "$CASE_PROJECT/Source"
  printf 'AIRDCPP_CORE_URL=%s\nAIRDCPP_CORE_COMMIT=%s\n' \
    "$FIXTURE_URL" "$FIXTURE_PIN" > "$CASE_PROJECT/config/upstream.env"
  git clone -q "$FIXTURE_URL" "$CASE_CHECKOUT"
  git -C "$CASE_CHECKOUT" checkout -q --detach "$FIXTURE_PIN"
}

expect_checkout_failure() {
  label=$1
  expected=$2
  shift 2
  if output=$(validate_configure_checkout "$@" 2>&1); then
    fail "$label unexpectedly succeeded"
  fi
  assert_contains "$output" "$expected" "$label diagnostic"
}

new_checkout_case clean
validate_configure_checkout "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN"

if output=$(
  checkout_changes() { return 73; }
  validate_configure_checkout "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN" 2>&1
); then
  fail "failed checkout inspection unexpectedly succeeded"
fi
assert_contains "$output" 'failed to inspect checkout changes' \
  "failed checkout inspection diagnostic"

new_checkout_case wrong-commit
expect_checkout_failure wrong_commit 'checkout HEAD does not match configured commit' \
  "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_LATER"

new_checkout_case attached-head
git -C "$CASE_CHECKOUT" switch -q -c local-at-pin
expect_checkout_failure attached_head 'checkout HEAD must be detached' \
  "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN"

new_checkout_case wrong-origin
git -C "$CASE_CHECKOUT" remote set-url origin file://$WORK/wrong.git
expect_checkout_failure wrong_origin 'origin URL does not match configured upstream' \
  "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN"

new_checkout_case tracked
printf 'tracked change\n' >> "$CASE_CHECKOUT/state.txt"
expect_checkout_failure tracked_changes 'checkout has unsafe local changes' \
  "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN"

new_checkout_case staged
printf 'staged change\n' >> "$CASE_CHECKOUT/state.txt"
git -C "$CASE_CHECKOUT" add state.txt
expect_checkout_failure staged_changes 'checkout has unsafe local changes' \
  "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN"

new_checkout_case untracked
printf 'untracked\n' > "$CASE_CHECKOUT/rogue.txt"
expect_checkout_failure untracked_changes 'rogue.txt' \
  "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN"

new_checkout_case generated
mkdir -p "$CASE_CHECKOUT/airdcpp/core/localization"
printf 'generated version\n' > "$CASE_CHECKOUT/airdcpp/core/version.inc"
printf 'generated strings\n' > "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp"
/usr/bin/touch -t 202001010101 "$CASE_CHECKOUT/airdcpp/core/version.inc" \
  "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp"
version_contents=$(cat "$CASE_CHECKOUT/airdcpp/core/version.inc")
strings_contents=$(cat "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp")
version_mtime=$(stat -f '%m' "$CASE_CHECKOUT/airdcpp/core/version.inc")
strings_mtime=$(stat -f '%m' "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp")
validate_configure_checkout "$CASE_PROJECT" "$CASE_CHECKOUT" "$FIXTURE_PIN"
assert_eq "$(cat "$CASE_CHECKOUT/airdcpp/core/version.inc")" "$version_contents" \
  "generated version contents preserved"
assert_eq "$(cat "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp")" "$strings_contents" \
  "generated strings contents preserved"
assert_eq "$(stat -f '%m' "$CASE_CHECKOUT/airdcpp/core/version.inc")" "$version_mtime" \
  "generated version mtime preserved"
assert_eq "$(stat -f '%m' "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp")" "$strings_mtime" \
  "generated strings mtime preserved"

SYMLINK_PROJECT=$WORK/project-symlink
mkdir -p "$SYMLINK_PROJECT/config" "$SYMLINK_PROJECT/Source"
cp "$CASE_PROJECT/config/upstream.env" "$SYMLINK_PROJECT/config/upstream.env"
ln -s "$CASE_CHECKOUT" "$SYMLINK_PROJECT/Source/airdcpp-core"
expect_checkout_failure symlinked_checkout 'refusing symlinked checkout' \
  "$SYMLINK_PROJECT" "$SYMLINK_PROJECT/Source/airdcpp-core" "$FIXTURE_PIN"

MISSING_GIT_PROJECT=$WORK/project-missing-git
mkdir -p "$MISSING_GIT_PROJECT/config" "$MISSING_GIT_PROJECT/Source/airdcpp-core"
cp "$CASE_PROJECT/config/upstream.env" "$MISSING_GIT_PROJECT/config/upstream.env"
expect_checkout_failure missing_git 'checkout is not a Git repository' \
  "$MISSING_GIT_PROJECT" "$MISSING_GIT_PROJECT/Source/airdcpp-core" "$FIXTURE_PIN"

PROJECT_ROOT=$CASE_PROJECT PATH="$FAKE_BIN:$PATH" \
  write_host_inventory "$CASE_PROJECT/Build/airdcpp-core/inventory.txt"
cp "$CASE_PROJECT/Build/airdcpp-core/inventory.txt" "$WORK/inventory.txt"
inventory=$(cat "$WORK/inventory.txt")
assert_line "$WORK/inventory.txt" 'host.arch=arm64' "host architecture"
assert_line "$WORK/inventory.txt" 'host.os=Darwin' "host operating system"
assert_line "$WORK/inventory.txt" 'host.os_version=26.5.1' "host operating system version"
assert_line "$WORK/inventory.txt" 'xcode.version=26.6' "Xcode version"
assert_line "$WORK/inventory.txt" 'xcode.build=17F113' "Xcode build"
assert_line "$WORK/inventory.txt" 'clang.version=Apple clang version 21.0.0 (clang-2100.1.1.101)' \
  "Apple Clang version"
assert_line "$WORK/inventory.txt" \
  'clang.path=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang' \
  "Apple Clang path"
assert_line "$WORK/inventory.txt" \
  'clangxx.path=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++' \
  "Apple Clang++ path"
assert_line "$WORK/inventory.txt" \
  'sdk.path=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk' \
  "SDK path"
assert_line "$WORK/inventory.txt" 'sdk.version=26.5' "SDK version"
assert_contains "$inventory" 'git.version=' "Git version"
assert_line "$WORK/inventory.txt" 'python.version=3.14.3' "Python version"
assert_line "$WORK/inventory.txt" 'homebrew.prefix=/opt/homebrew' "Homebrew prefix"
assert_line "$WORK/inventory.txt" 'homebrew.version=6.0.14' "Homebrew version"
assert_line "$WORK/inventory.txt" 'cmake.version=3.31.6' "CMake version"
assert_line "$WORK/inventory.txt" 'ninja.version=1.12.1' "Ninja version"
assert_line "$WORK/inventory.txt" 'formula.cmake=absent' "missing CMake formula"
assert_line "$WORK/inventory.txt" 'formula.miniupnpc=2.3.3' "formula version"
assert_line "$WORK/inventory.txt" 'formula.snappy=absent' "missing Snappy formula"
assert_line "$WORK/inventory.txt" 'formula.boost.prefix=/opt/homebrew/opt/boost' "formula prefix"
assert_line "$WORK/inventory.txt" 'optional.libnatpmp=1.0.0' "optional NAT-PMP version"
assert_line "$WORK/inventory.txt" 'optional.tbb=1.0.0' "optional TBB version"
assert_line "$WORK/inventory.txt" 'generated.airdcpp/core/version.inc=present' \
  "generated version inventory"
assert_line "$WORK/inventory.txt" 'generated.airdcpp/core/localization/StringDefs.cpp=present' \
  "generated strings inventory"
unkeyed_inventory_lines=$(sed -n '/^[^=][^=]*=/!p' "$WORK/inventory.txt")
assert_eq "$unkeyed_inventory_lines" '' "every inventory line is keyed"
assert_eq "$inventory" "$(printf '%s\n' "$inventory" | LC_ALL=C sort)" "sorted inventory"
assert_not_contains "$inventory" "$WORK" "inventory temp-path leakage"
assert_not_contains "$inventory" '/Users/' "home directory omitted"
assert_not_contains "$inventory" 'HOME=' "environment dump omitted"
assert_not_contains "$inventory" 'timestamp=' "timestamp omitted"
assert_not_contains "$inventory" 'username=' "username omitted"
assert_eq "$(cat "$CASE_CHECKOUT/airdcpp/core/version.inc")" "$version_contents" \
  "inventory preserved generated version contents"
assert_eq "$(stat -f '%m' "$CASE_CHECKOUT/airdcpp/core/version.inc")" "$version_mtime" \
  "inventory preserved generated version mtime"
assert_eq "$(cat "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp")" "$strings_contents" \
  "inventory preserved generated strings contents"
assert_eq "$(stat -f '%m' "$CASE_CHECKOUT/airdcpp/core/localization/StringDefs.cpp")" "$strings_mtime" \
  "inventory preserved generated strings mtime"

expect_inventory_path_rejection() {
  label=$1
  variable=$2
  sensitive_path=$3
  rejected_output=$CASE_PROJECT/Build/airdcpp-core/rejected-$label.txt
  if output=$(env "$variable=$sensitive_path" PROJECT_ROOT="$CASE_PROJECT" PATH="$FAKE_BIN:$PATH" \
    sh -c '. "$1"; write_host_inventory "$2"' sh \
    "$ROOT/scripts/lib/configure.sh" "$rejected_output" 2>&1); then
    fail "$label inventory path unexpectedly succeeded"
  fi
  assert_contains "$output" "inventory path is prohibited for" "$label prohibited-path diagnostic"
  assert_not_contains "$output" "$sensitive_path" "$label sensitive-path diagnostic"
  assert_file_absent "$rejected_output"
}

expect_inventory_path_rejection clang-home FAKE_CLANG_PATH /Users/review-private/clang
expect_inventory_path_rejection clangxx-temp FAKE_CLANGXX_PATH "$WORK/compiler/clang++"
expect_inventory_path_rejection sdk-home FAKE_SDK_PATH /Users/review-private/MacOSX.sdk
expect_inventory_path_rejection homebrew-temp FAKE_HOMEBREW_PREFIX "$WORK/homebrew"
expect_inventory_path_rejection formula-home FAKE_BOOST_PREFIX /Users/review-private/boost

prefix_failure_output=$CASE_PROJECT/Build/airdcpp-core/prefix-failure.txt
if output=$(FAKE_PREFIX_FAILURE=boost PROJECT_ROOT=$CASE_PROJECT PATH="$FAKE_BIN:$PATH" \
  write_host_inventory "$prefix_failure_output" 2>&1); then
  fail "failed formula-prefix inventory unexpectedly succeeded"
fi
assert_contains "$output" 'Homebrew prefix unavailable for boost' \
  "failed formula-prefix diagnostic"
assert_file_absent "$prefix_failure_output"
prefix_failure_temps=$(find "$CASE_PROJECT/Build/airdcpp-core" -maxdepth 1 \
  \( -name 'prefix-failure.txt.raw.*' -o -name 'prefix-failure.txt.sorted.*' \) -print)
assert_eq "$prefix_failure_temps" '' "failed formula-prefix inventory temporary cleanup"

OUTSIDE_DIR=$CASE_PROJECT/outside
if output=$(PROJECT_ROOT=$CASE_PROJECT PATH="$FAKE_BIN:$PATH" \
  write_host_inventory "$OUTSIDE_DIR/inventory.txt" 2>&1); then
  fail "outside inventory path unexpectedly succeeded"
fi
assert_contains "$output" 'inventory output must be inside' "outside inventory diagnostic"
assert_dir_absent "$OUTSIDE_DIR"

ESCAPED_OUTPUT=$CASE_PROJECT/Build/airdcpp-core/../escaped.txt
if output=$(PROJECT_ROOT=$CASE_PROJECT PATH="$FAKE_BIN:$PATH" \
  write_host_inventory "$ESCAPED_OUTPUT" 2>&1); then
  fail "parent-traversal inventory path unexpectedly succeeded"
fi
assert_contains "$output" 'unsafe path component' "parent-traversal inventory diagnostic"
assert_file_absent "$CASE_PROJECT/Build/escaped.txt"

# Gate 2 must check the final file, not just its physical containing directory.
formula_fixture=$WORK/formula-prefix
mkdir -p "$formula_fixture/lib" "$WORK/outside-prefix"
printf 'library\n' > "$formula_fixture/lib/real.dylib"
printf 'outside library\n' > "$WORK/outside-prefix/real.dylib"
ln -s real.dylib "$formula_fixture/lib/internal.dylib"
ln -s ../../outside-prefix/real.dylib "$formula_fixture/lib/escape.dylib"
ln -s escape.dylib "$formula_fixture/lib/chain.dylib"
INVENTORY=$WORK/path-inventory.txt
printf 'formula.boost.prefix=%s\n' "$formula_fixture" > "$INVENTORY"
for library in real internal; do
  FAKE_BOOST_PREFIX=$formula_fixture PATH="$FAKE_BIN:$PATH" \
    assert_formula_path "$formula_fixture/lib/$library.dylib" boost
done
for library in escape chain; do
  if output=$(FAKE_BOOST_PREFIX=$formula_fixture PATH="$FAKE_BIN:$PATH" \
    assert_formula_path "$formula_fixture/lib/$library.dylib" boost 2>&1); then
    fail "Gate 2 accepted library symlink $library outside formula prefix"
  fi
  assert_contains "$output" 'path outside recorded Homebrew prefix' 'escaping library diagnostic'
done

# Failed provenance reads must not become successful printf output or publish
# immutable evidence, even when a tool emits plausible output before failing.
metadata_failures=0
mkdir -p "$CASE_CHECKOUT/airdcpp/core"
printf 'project(metadata_fixture)\n' > "$CASE_CHECKOUT/CMakeLists.txt"
for probe in git source-hash generated-hash cmake-read formula-read inventory-hash; do
  for operation in original reuse capture sidecar existing; do
    case "$operation:$probe" in original:cmake-read|original:formula-read|original:inventory-hash) continue ;; esac
    metadata_root=$WORK/metadata-$probe-$operation
    mkdir -p "$metadata_root/Source" "$metadata_root/Build/airdcpp-core/evidence"
    cp -R "$CASE_CHECKOUT" "$metadata_root/Source/airdcpp-core"
    cp "$WORK/inventory.txt" "$metadata_root/Build/airdcpp-core/evidence/host-inventory.txt"
    metadata_capture=$metadata_root/Build/airdcpp-core/unmodified
    if [ "$operation" = sidecar ] || [ "$operation" = existing ]; then
      mkdir -p "$metadata_capture"
      printf 'original command\n' > "$metadata_capture/command.txt"
      printf 'original log\n' > "$metadata_capture/configure.log"
      printf '1\n' > "$metadata_capture/exit-code.txt"
      configure_original_inputs "$metadata_root/Source/airdcpp-core" > "$metadata_capture/inputs.txt"
      printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3\nCMAKE_CACHE_MINOR_VERSION:INTERNAL=31\nCMAKE_CACHE_PATCH_VERSION:INTERNAL=6\nCMAKE_OSX_ARCHITECTURES:STRING=arm64\nCMAKE_OSX_DEPLOYMENT_TARGET:STRING=14.0\n' > "$metadata_capture/CMakeCache.txt"
      if [ "$operation" = existing ]; then
        configure_reuse_inputs "$metadata_root/Source/airdcpp-core" "$metadata_root/Build/airdcpp-core/evidence/host-inventory.txt" > "$metadata_capture/inputs.txt"
      fi
    fi
    metadata_before=$(find "$metadata_root" -type f -exec shasum -a 256 {} \;)
    if output=$(PROBE=$probe OPERATION=$operation sh -eu -c '
      . "$1"
      PROJECT_ROOT=$2
      checkout=$2/Source/airdcpp-core
      inventory=$2/Build/airdcpp-core/evidence/host-inventory.txt
      case "$PROBE" in
        git) git() { printf "0123456789012345678901234567890123456789\n"; return 71; } ;;
        source-hash|generated-hash|inventory-hash)
          shasum() {
            case "$PROBE:${3:-}" in
              source-hash:*/CMakeLists.txt|generated-hash:*/version.inc|inventory-hash:)
                printf "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  file\n"; return 72 ;;
            esac
            command shasum "$@"
          } ;;
        cmake-read|formula-read)
          sed() {
            case "$PROBE:$*" in
              cmake-read:*cmake.version*|formula-read:*formula*) command sed "$@"; return 73 ;;
            esac
            command sed "$@"
          } ;;
      esac
      case "$OPERATION" in
        original) configure_original_inputs "$checkout" ;;
        reuse) configure_reuse_inputs "$checkout" "$inventory" ;;
        capture|existing) capture_unmodified_configure "$2" "$checkout" "$2/Build/airdcpp-core/unmodified" "" "" ;;
        sidecar) prepare_unmodified_reuse_metadata "$2" ;;
      esac
    ' sh "$ROOT/scripts/lib/configure.sh" "$metadata_root" 2>&1); then
      printf 'FAIL: %s accepted failed %s provenance read\n' "$operation" "$probe" >&2
      metadata_failures=$((metadata_failures + 1))
    fi
    if [ "$operation" = capture ]; then
      [ ! -e "$metadata_capture/inputs.txt" ] || {
        printf 'FAIL: capture published inputs after failed %s read\n' "$probe" >&2
        metadata_failures=$((metadata_failures + 1))
      }
    fi
    if [ "$operation" = sidecar ]; then
      [ ! -e "$metadata_root/Build/airdcpp-core/evidence/unmodified-reuse-inputs.txt" ] || {
        printf 'FAIL: sidecar published after failed %s read\n' "$probe" >&2
        metadata_failures=$((metadata_failures + 1))
      }
    fi
    if [ "$operation" = existing ]; then
      assert_eq "$(find "$metadata_root" -type f -exec shasum -a 256 {} \;)" "$metadata_before" 'existing evidence survives failed read'
    fi
  done
done
[ "$metadata_failures" -eq 0 ] || fail "$metadata_failures failed provenance checks accepted/published"

printf 'PASS: configure discovery helpers\n'
