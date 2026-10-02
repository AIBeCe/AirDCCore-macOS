#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 missing: $2"; }
for script in build_openssl.sh build_miniupnpc.sh build_libmaxminddb.sh; do
  file=$ROOT/scripts/lib/dependencies/$script
  [ -f "$file" ] || fail "$file is missing"
  contains "$file" "expected SOURCE BUILD STAGE JOBS EPOCH"
  contains "$file" 'consumer-compile'
  ! grep -E '/opt/homebrew|brew --prefix' "$file" >/dev/null || fail "$file reads Homebrew paths"
done
contains "$ROOT/scripts/lib/dependencies/build_miniupnpc.sh" 'CMAKE_OSX_ARCHITECTURES=arm64'
contains "$ROOT/scripts/lib/dependencies/build_miniupnpc.sh" 'CMAKE_OSX_DEPLOYMENT_TARGET=14.0'
contains "$ROOT/scripts/lib/dependencies/build_libmaxminddb.sh" 'CMAKE_OSX_ARCHITECTURES=arm64'
contains "$ROOT/scripts/lib/dependencies/build_libmaxminddb.sh" 'CMAKE_OSX_DEPLOYMENT_TARGET=14.0'
openssl=$ROOT/scripts/lib/dependencies/build_openssl.sh
contains "$openssl" 'darwin64-arm64-cc'
contains "$openssl" 'no-shared'
contains "$openssl" 'no-pinshared'
contains "$openssl" 'make -C "$build" -j "$jobs" test'
contains "$openssl" 'make -C "$build" install_dev'
contains "$openssl" '"$stage/lib/libssl.a" "$stage/lib/libcrypto.a"'
mini=$ROOT/scripts/lib/dependencies/build_miniupnpc.sh
contains "$mini" '-DUPNPC_BUILD_STATIC=ON'
contains "$mini" '-DUPNPC_BUILD_SHARED=OFF'
contains "$mini" '-DUPNPC_BUILD_TESTS=ON'
contains "$mini" '-DUPNPC_BUILD_SAMPLE=OFF'
contains "$mini" 'miniupnpc_lib_version'
maxmind=$ROOT/scripts/lib/dependencies/build_libmaxminddb.sh
contains "$maxmind" '-DBUILD_SHARED_LIBS=OFF'
contains "$maxmind" '-DBUILD_TESTING=ON'
contains "$maxmind" '-DMAXMINDDB_BUILD_BINARIES=OFF'
contains "$maxmind" '-DMAXMINDDB_INSTALL=ON'
contains "$maxmind" 'MMDB_lib_version'
printf '%s\n' 'dependency leaf network adapters: PASS'
