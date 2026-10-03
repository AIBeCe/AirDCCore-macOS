#!/bin/sh
set -eu
die() { printf '%s\n' "leveldb adapter: $*" >&2; exit 2; }
runner=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/command_runner.py
run() { purpose=$1; shift; set +e; python3 "$runner" "$purpose" "$@"; status=$?; set -e; return "$status"; }
verify_snappy_links() {
  python3 - "$snappy/lib/libsnappy.a" "$1" <<'PY'
import json
from pathlib import Path
import shlex
import sys
expected, evidence = sys.argv[1:]
seen = False
for line in Path(evidence).read_text().splitlines():
    if line.startswith('{'):
        json.loads(line)  # command-runner evidence is not a linker command
        continue
    if 'libsnappy.a' not in line and '-lsnappy' not in line:
        continue  # CMake probe logs also mention the inventoried build tools.
    for argument in shlex.split(line):
        if argument == '-lsnappy' or argument.endswith('libsnappy.a'):
            if argument != expected:
                raise SystemExit('leveldb adapter: unexpected Snappy link input: ' + argument)
            seen = True
if not seen:
    raise SystemExit('leveldb adapter: generated link commands lack locked Snappy archive')
PY
}
[ "$#" -eq 6 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH SNAPPY_PREFIX'
source=$1; build=$2; stage=$3; jobs=$4; epoch=$5; snappy=$6; [ -n "$snappy" ] || die 'SNAPPY_PREFIX must not be empty'
for path in "$source" "$build" "$stage" "$snappy"; do [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"; case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac; done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P); snappy=$(CDPATH= cd -- "$snappy" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'; case "$build/" in "$source/"*) die 'build must be outside source' ;; esac; case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac; case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac; [ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'; : "${CC:?CC is required}"; : "${CXX:?CXX is required}"
[ -f "$source/CMakeLists.txt" ] && [ -f "$source/LICENSE" ] || die 'missing LevelDB source input'
[ -f "$snappy/include/snappy.h" ] && [ -f "$snappy/lib/libsnappy.a" ] || die 'invalid Snappy prefix'
unset CMAKE_PREFIX_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH CMAKE_FRAMEWORK_PATH CMAKE_APPBUNDLE_PATH CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
ninja=$(command -v ninja) || die 'Ninja is required'
# The pinned upstream probes and links the bare target "snappy". Bind that
# target before its checks, without changing source or bypassing the probe.
cat > "$build/locked-snappy.cmake" <<CMAKE
add_library(snappy STATIC IMPORTED GLOBAL)
set_target_properties(snappy PROPERTIES
  IMPORTED_LOCATION [==[$snappy/lib/libsnappy.a]==]
  INTERFACE_INCLUDE_DIRECTORIES [==[$snappy/include]==])
CMAKE
run configure cmake -S "$source" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_INSTALL_PREFIX=$stage" -DBUILD_SHARED_LIBS=OFF -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_INSTALL=ON "-DCMAKE_PREFIX_PATH=$snappy" "-DCMAKE_PROJECT_INCLUDE=$build/locked-snappy.cmake" "-DCMAKE_REQUIRED_FLAGS=-L$snappy/lib" -DCMAKE_REQUIRED_LIBRARIES=c++ -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON "-DCMAKE_MAKE_PROGRAM=$ninja"
run build cmake --build "$build" --parallel "$jobs"
run link-provenance "$ninja" -C "$build" -t commands leveldbutil > "$build/leveldb-link-commands.txt"
cat "$build/leveldb-link-commands.txt"
run install cmake --install "$build"
grep -Fx "CMAKE_PREFIX_PATH:UNINITIALIZED=$snappy" "$build/CMakeCache.txt" >/dev/null || grep -Fx "CMAKE_PREFIX_PATH:PATH=$snappy" "$build/CMakeCache.txt" >/dev/null || die 'Snappy prefix not recorded exactly in cache'
grep -Fx 'HAVE_SNAPPY:INTERNAL=1' "$build/CMakeCache.txt" >/dev/null || die 'Snappy feature probe failed'
grep -F "$snappy/include" "$build/compile_commands.json" >/dev/null || die 'Snappy prefix absent from compile provenance'
verify_snappy_links "$build/leveldb-link-commands.txt"
probe_log="$build/CMakeFiles/CMakeConfigureLog.yaml"
[ -f "$probe_log" ] || probe_log="$build/CMakeFiles/CMakeOutput.log"
verify_snappy_links "$probe_log"
[ -f "$stage/include/leveldb/db.h" ] && [ -f "$stage/lib/libleveldb.a" ] || die 'missing installed LevelDB output'
config_dir="$stage/lib/cmake/leveldb"
[ -f "$config_dir/leveldbConfig.cmake" ] || die 'missing installed LevelDB config'
grep -Fx '  INTERFACE_LINK_LIBRARIES "snappy;Threads::Threads"' "$config_dir/leveldbTargets.cmake" >/dev/null || die 'installed target has unexpected dependency interface'
for poison in /opt/homebrew /usr/local; do
  ! grep -F "$poison" "$build/compile_commands.json" "$build/leveldb-link-commands.txt" >/dev/null || die 'host provenance leaked into LevelDB'
done
# Exported metadata remains relocatable; the build-owned hook supplies the
# upstream bare dependency to the isolated installed consumer below.
for poison in "$source" "$build" "$stage" "$snappy" /opt/homebrew /usr/local; do
  ! grep -R -F "$poison" "$config_dir" >/dev/null || die 'installed config contains absolute dependency provenance'
done
cp "$source/LICENSE" "$stage/LICENSE"
cat > "$build/leveldb-consumer.cc" <<'C'
#include <leveldb/db.h>
#include <leveldb/options.h>
#include <string>
int main(int argc, char** argv) {
    if (argc != 2) return 4;
    leveldb::Options options;
    options.create_if_missing = true;
    options.compression = leveldb::kSnappyCompression;
    options.write_buffer_size = 1024;
    const std::string expected(128 * 1024, 'x');
    leveldb::DB* db = nullptr;
    leveldb::Status status = leveldb::DB::Open(options, argv[1], &db);
    if (!status.ok()) return 1;
    status = db->Put(leveldb::WriteOptions(), "key", expected);
    if (!status.ok()) { delete db; return 2; }
    db->CompactRange(nullptr, nullptr);
    delete db;
    options.create_if_missing = false;
    status = leveldb::DB::Open(options, argv[1], &db);
    if (!status.ok()) return 3;
    std::string actual;
    status = db->Get(leveldb::ReadOptions(), "key", &actual);
    delete db;
    return status.ok() && actual == expected ? 0 : 5;
}
C
mkdir -p "$build/consumer-src"
cp "$build/leveldb-consumer.cc" "$build/consumer-src/leveldb-consumer.cc"
cat > "$build/consumer-src/CMakeLists.txt" <<C
cmake_minimum_required(VERSION 3.20)
project(leveldb-installed-consumer LANGUAGES CXX)
find_package(Snappy CONFIG REQUIRED PATHS [==[$snappy/lib/cmake/Snappy]==] NO_DEFAULT_PATH)
find_package(Threads REQUIRED)
find_package(leveldb CONFIG REQUIRED PATHS [==[$config_dir]==] NO_DEFAULT_PATH)
add_executable(leveldb-consumer leveldb-consumer.cc)
target_link_libraries(leveldb-consumer PRIVATE leveldb::leveldb)
file(GENERATE OUTPUT resolved-targets.txt CONTENT "\$<TARGET_FILE:Snappy::snappy>\n\$<TARGET_FILE:leveldb::leveldb>\n")
C
run consumer-configure cmake -S "$build/consumer-src" -B "$build/consumer" -G Ninja "-DCMAKE_PREFIX_PATH=$stage;$snappy" "-DCMAKE_PROJECT_INCLUDE=$build/locked-snappy.cmake" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF "-DCMAKE_MAKE_PROGRAM=$ninja"
grep -Fx "$snappy/lib/libsnappy.a" "$build/consumer/resolved-targets.txt" >/dev/null || die 'installed Snappy target resolves outside accepted prefix'
grep -Fx "$stage/lib/libleveldb.a" "$build/consumer/resolved-targets.txt" >/dev/null || die 'installed LevelDB target resolves outside stage'
run consumer-build cmake --build "$build/consumer" --parallel "$jobs"
run consumer-link-provenance "$ninja" -C "$build/consumer" -t commands leveldb-consumer > "$build/consumer-link-commands.txt"
cat "$build/consumer-link-commands.txt"
verify_snappy_links "$build/consumer-link-commands.txt"
grep -F "$stage/lib/libleveldb.a" "$build/consumer-link-commands.txt" >/dev/null || die 'installed consumer does not link staged LevelDB'
for poison in /opt/homebrew /usr/local; do ! grep -F "$poison" "$build/consumer-link-commands.txt" >/dev/null || die 'host consumer link provenance'; done
db_path=$(mktemp -d "$build/leveldb-consumer-db.XXXXXX")
trap 'rm -rf "$db_path"' EXIT HUP INT TERM
run consumer-run "$build/consumer/leveldb-consumer" "$db_path"
rm -rf "$db_path"
trap - EXIT HUP INT TERM
