#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"

WORK=$(new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15
TOOLCHAIN=$ROOT/cmake/toolchains/macos-arm64.cmake
FIXTURE=$ROOT/tests/fixtures/configure-upstream

configure_success() {
  case_name=$1
  shift
  build_dir=$WORK/$case_name
  if ! cmake -S "$ROOT" -B "$build_dir" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DAIRDCPP_CORE_SOURCE_DIR="$FIXTURE" "$@" >"$WORK/$case_name.log" 2>&1; then
    cat "$WORK/$case_name.log" >&2
    fail "$case_name configure failed"
  fi
}

configure_failure() {
  case_name=$1
  expected=$2
  shift 2
  build_dir=$WORK/$case_name
  if cmake -S "$ROOT" -B "$build_dir" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DAIRDCPP_CORE_SOURCE_DIR="$FIXTURE" "$@" >"$WORK/$case_name.log" 2>&1; then
    fail "$case_name configure unexpectedly succeeded"
  fi
  assert_contains "$(cat "$WORK/$case_name.log")" "$expected" "$case_name diagnostic"
}

configure_success good
SUMMARY=$WORK/good/airdcpp-configure-summary.txt
assert_line "$SUMMARY" "compiler.id=AppleClang" "compiler"
assert_line "$SUMMARY" "architecture=arm64" "architecture"
assert_line "$SUMMARY" "deployment_target=14.0" "deployment target"
assert_line "$SUMMARY" "cxx_standard=20" "language standard"
assert_line "$SUMMARY" "enable_natpmp=OFF" "NAT-PMP policy"
assert_line "$SUMMARY" "enable_tbb=OFF" "TBB policy"

expected_targets='BZip2::BZip2
ZLIB::ZLIB
OpenSSL::SSL
OpenSSL::Crypto
miniupnpc::miniupnpc
leveldb::leveldb
maxminddb::maxminddb
Boost::thread
Boost::regex
Snappy::snappy
Threads::Threads
Iconv::Iconv'
recorded_targets=$(sed -n 's/^target.name=//p' "$SUMMARY")
assert_eq "$recorded_targets" "$expected_targets" "imported target record order"

package_record=$(awk '
  $0 == "target.name=BZip2::BZip2" { recording=1; print; next }
  recording && /^target.name=/ { exit }
  recording { print }
' "$SUMMARY")
expected_package_record='target.name=BZip2::BZip2
target.exists=TRUE
target.type=STATIC_LIBRARY
target.imported_location=/fixture/lib/libbz2.a
target.imported_configurations=RELEASE
target.include_directories=/fixture/include
target.interface_libraries=fixture_dependency'
assert_eq "$package_record" "$expected_package_record" \
  "child package imported target properties"

configure_failure wrong-mode "CMAKE_BUILD_TYPE must be Release; got Debug" \
  -DCMAKE_BUILD_TYPE=Debug
configure_failure wrong-architecture \
  "CMAKE_OSX_ARCHITECTURES must be arm64; got x86_64" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64
configure_failure shared-libraries "BUILD_SHARED_LIBS must be OFF; got ON" \
  -DBUILD_SHARED_LIBS=ON
configure_failure old-standard "CMAKE_CXX_STANDARD must be 20; got 17" \
  -DCMAKE_CXX_STANDARD=17

configure_success target-13 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DFIXTURE_EXPECTED_DEPLOYMENT_TARGET=13.0
assert_line "$WORK/target-13/airdcpp-configure-summary.txt" \
  "deployment_target=13.0" "13.0 diagnostic"
configure_success target-15 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DFIXTURE_EXPECTED_DEPLOYMENT_TARGET=15.0
assert_line "$WORK/target-15/airdcpp-configure-summary.txt" \
  "deployment_target=15.0" "15.0 diagnostic"
configure_failure target-12 \
  "deployment target must be one of 13.0, 14.0, or 15.0" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DFIXTURE_EXPECTED_DEPLOYMENT_TARGET=12.0

configure_success optional-enabled \
  -DENABLE_NATPMP=ON \
  -DENABLE_TBB=ON \
  -DFIXTURE_EXPECTED_NATPMP=ON \
  -DFIXTURE_EXPECTED_TBB=ON
assert_line "$WORK/optional-enabled/airdcpp-configure-summary.txt" \
  "enable_natpmp=ON" "enabled NAT-PMP diagnostic"
assert_line "$WORK/optional-enabled/airdcpp-configure-summary.txt" \
  "enable_tbb=ON" "enabled TBB diagnostic"

printf '%s\n' \
  'include("${POLICY}")' \
  'airdcpp_require_apple_clang()' > "$WORK/compiler-policy.cmake"
for compiler_id in GNU Clang; do
  compiler_log=$WORK/compiler-$compiler_id.log
  if cmake \
    -DPOLICY="$ROOT/cmake/modules/AirDCCorePolicy.cmake" \
    -DCMAKE_C_COMPILER_ID="$compiler_id" \
    -DCMAKE_CXX_COMPILER_ID="$compiler_id" \
    -P "$WORK/compiler-policy.cmake" >"$compiler_log" 2>&1; then
    fail "$compiler_id compiler policy unexpectedly succeeded"
  fi
  assert_contains "$(cat "$compiler_log")" "Apple Clang is required" \
    "$compiler_id compiler diagnostic"
done

if grep -Ein \
  'add_(compile|link)_options|target_(compile|link)_options|CMAKE_(C|CXX|EXE_LINKER|SHARED_LINKER|MODULE_LINKER)_FLAGS|-stdlib=|-mmacosx-version-min|-arch([ =]|$)' \
  "$ROOT/CMakeLists.txt" "$TOOLCHAIN" > "$WORK/forbidden-flags.txt"; then
  cat "$WORK/forbidden-flags.txt" >&2
  fail "wrapper contains compiler or linker flags outside the declared policy"
fi

printf 'PASS: ARM64 CMake wrapper policy\n'
