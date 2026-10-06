#!/bin/sh
set -eu
die() { printf '%s\n' "snappy adapter: $*" >&2; exit 2; }
runner=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/command_runner.py
run() { purpose=$1; shift; set +e; python3 "$runner" "$purpose" "$@"; status=$?; set -e; return "$status"; }
[ "$#" -eq 5 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH'
source=$1; build=$2; stage=$3; jobs=$4; epoch=$5
for path in "$source" "$build" "$stage"; do [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"; case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac; done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'
case "$build/" in "$source/"*) die 'build must be outside source' ;; esac; case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac; case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac
[ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'; : "${CC:?CC is required}"; : "${CXX:?CXX is required}"
[ -f "$source/CMakeLists.txt" ] && [ -f "$source/COPYING" ] || die 'missing Snappy source input'
unset CMAKE_PREFIX_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH CMAKE_FRAMEWORK_PATH CMAKE_APPBUNDLE_PATH CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
ninja=$(command -v ninja) || die 'Ninja is required'
run configure cmake -S "$source" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_INSTALL_PREFIX=$stage" -DBUILD_SHARED_LIBS=OFF -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF -DSNAPPY_FUZZING_BUILD=OFF -DSNAPPY_INSTALL=ON
run build cmake --build "$build" --parallel "$jobs"; run install cmake --install "$build"
[ -f "$stage/include/snappy.h" ] && [ -f "$stage/lib/libsnappy.a" ] || die 'missing installed Snappy output'; [ -f "$stage/lib/cmake/Snappy/SnappyConfig.cmake" ] || die 'missing installed Snappy config'; cp "$source/COPYING" "$stage/COPYING"
cat > "$build/snappy-consumer.cc" <<'C'
#include <snappy.h>
#include <cstring>
#include <string>
int main() { const char input[] = "AirDCCore Snappy fixture"; std::string packed, restored; snappy::Compress(input, sizeof input, &packed); if (!snappy::Uncompress(packed.data(), packed.size(), &restored)) return 1; return restored.size() == sizeof input && std::memcmp(restored.data(), input, sizeof input) == 0 ? 0 : 2; }
C
mkdir -p "$build/snappy-consumer-src"; cp "$build/snappy-consumer.cc" "$build/snappy-consumer-src/snappy-consumer.cc"
cat > "$build/snappy-consumer-src/CMakeLists.txt" <<C
cmake_minimum_required(VERSION 3.20)
project(snappy-installed-consumer LANGUAGES CXX)
find_package(Snappy CONFIG REQUIRED PATHS [==[$stage/lib/cmake/Snappy]==] NO_DEFAULT_PATH)
add_executable(snappy-consumer snappy-consumer.cc)
target_link_libraries(snappy-consumer PRIVATE Snappy::snappy)
file(GENERATE OUTPUT resolved-targets.txt CONTENT "\$<TARGET_FILE:Snappy::snappy>\n")
C
run consumer-configure cmake -S "$build/snappy-consumer-src" -B "$build/snappy-consumer-build" -G Ninja "-DCMAKE_PREFIX_PATH=$stage" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF "-DCMAKE_MAKE_PROGRAM=$ninja"
grep -Fx "$stage/lib/libsnappy.a" "$build/snappy-consumer-build/resolved-targets.txt" >/dev/null || die 'installed target resolves outside stage'
run consumer-build cmake --build "$build/snappy-consumer-build" --parallel "$jobs"; run consumer-run "$build/snappy-consumer-build/snappy-consumer"
