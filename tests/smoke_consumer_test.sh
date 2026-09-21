#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"

# /var is a macOS symlink; production path guards intentionally reject it.
WORK=$(TMPDIR=/private/tmp new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
STAGE=$WORK/stage
mkdir -p "$STAGE/include/airdcpp/core" "$STAGE/lib"
printf '%s\n' '#pragma once' '#include <string>' 'using std::string;' \
  > "$STAGE/include/airdcpp/stdinc.h"
printf '%s\n' '#pragma once' \
  'namespace dcpp { string getVersionTag() noexcept; }' \
  > "$STAGE/include/airdcpp/core/version.h"
printf '%s\n' '#include <string>' \
  'namespace dcpp { std::string getVersionTag() noexcept { return "fixture"; } }' \
  > "$WORK/version.cpp"
printf '%s\n' 'int unrelated_fixture_symbol() { return 7; }' > "$WORK/unrelated.cpp"
xcrun clang++ -std=c++20 -arch arm64 -c "$WORK/version.cpp" -o "$WORK/version.o"
xcrun clang++ -std=c++20 -arch arm64 -c "$WORK/unrelated.cpp" -o "$WORK/unrelated.o"
/usr/bin/libtool -static -o "$STAGE/lib/libairdcpp.a" "$WORK/version.o" >/dev/null
/usr/bin/libtool -static -o "$STAGE/lib/libmissing.a" "$WORK/unrelated.o" >/dev/null

configure_case() {
  name=$1
  include_dir=$2
  library=$3
  architecture=$4
  cmake -S "$ROOT/smoke-test" -B "$WORK/$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_OSX_ARCHITECTURES=$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_EXTENSIONS=OFF \
    "-DAIRDCCORE_INCLUDE_DIR=$include_dir" \
    "-DAIRDCCORE_LIBRARY=$library" \
    -DAIRDCCORE_TEST_LINK_ITEMS=fixture
}

expect_configure_failure() {
  name=$1
  diagnostic=$2
  include_dir=$3
  library=$4
  architecture=$5
  if output=$(configure_case "$name" "$include_dir" "$library" "$architecture" 2>&1); then
    fail "$name configure unexpectedly succeeded"
  fi
  assert_contains "$output" "$diagnostic" "$name diagnostic"
}

if ! output=$(configure_case valid "$STAGE/include" "$STAGE/lib/libairdcpp.a" arm64 2>&1); then
  fail "valid standalone configure failed: $output"
fi
if ! output=$(cmake --build "$WORK/valid" --verbose 2>&1); then
  fail "valid standalone link failed: $output"
fi
assert_eq "$("$WORK/valid/airdcpp-smoke")" 'AirDC++ Core fixture' 'smoke output'
assert_eq "$(/usr/bin/lipo -archs "$WORK/valid/airdcpp-smoke")" arm64 'smoke architecture'

expect_configure_failure absent-archive 'AIRDCCORE_LIBRARY must be a regular file' \
  "$STAGE/include" "$STAGE/lib/absent.a" arm64

ln -s "$STAGE/lib/libairdcpp.a" "$STAGE/lib/libsymlink.a"
expect_configure_failure symlink-archive 'AIRDCCORE_LIBRARY must not be a symlink' \
  "$STAGE/include" "$STAGE/lib/libsymlink.a" arm64

expect_configure_failure wrong-architecture 'CMAKE_OSX_ARCHITECTURES must be exactly arm64' \
  "$STAGE/include" "$STAGE/lib/libairdcpp.a" x86_64

mv "$STAGE/include/airdcpp/stdinc.h" "$WORK/stdinc-held.h"
expect_configure_failure missing-stdinc 'staged airdcpp/stdinc.h is required' \
  "$STAGE/include" "$STAGE/lib/libairdcpp.a" arm64
mv "$WORK/stdinc-held.h" "$STAGE/include/airdcpp/stdinc.h"

if ! output=$(configure_case missing-symbol "$STAGE/include" "$STAGE/lib/libmissing.a" arm64 2>&1); then
  fail "missing-symbol configure failed before link: $output"
fi
if output=$(cmake --build "$WORK/missing-symbol" --verbose 2>&1); then
  fail 'archive without dcpp::getVersionTag unexpectedly linked'
fi
assert_contains "$output" 'getVersionTag' 'real Core symbol link failure'

printf 'PASS: standalone real-symbol Core consumer\n'
