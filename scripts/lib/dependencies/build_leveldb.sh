#!/bin/sh
set -eu
die() { printf '%s\n' "leveldb adapter: $*" >&2; exit 2; }
run() { purpose=$1; shift; printf 'adapter-command\t%s' "$purpose"; for arg in "$@"; do printf '\t%s' "$arg"; done; printf '\n'; set +e; "$@"; status=$?; set -e; printf 'adapter-status\t%s\t%s\n' "$purpose" "$status"; return "$status"; }
[ "$#" -eq 6 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH SNAPPY_PREFIX'
source=$1; build=$2; stage=$3; jobs=$4; epoch=$5; snappy=$6; [ -n "$snappy" ] || die 'SNAPPY_PREFIX must not be empty'
for path in "$source" "$build" "$stage" "$snappy"; do [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"; case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac; done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P); snappy=$(CDPATH= cd -- "$snappy" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'; case "$build/" in "$source/"*) die 'build must be outside source' ;; esac; case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac; case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac; [ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'; : "${CC:?CC is required}"; : "${CXX:?CXX is required}"
[ -f "$source/CMakeLists.txt" ] && [ -f "$source/LICENSE" ] || die 'missing LevelDB source input'; [ -f "$snappy/include/snappy.h" ] && [ -f "$snappy/lib/libsnappy.a" ] || die 'invalid Snappy prefix'; unset CMAKE_PREFIX_PATH PKG_CONFIG_PATH
run configure cmake -S "$source" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_INSTALL_PREFIX=$stage" -DBUILD_SHARED_LIBS=OFF -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_INSTALL=ON "-DCMAKE_PREFIX_PATH=$snappy" -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
run build cmake --build "$build" --parallel "$jobs"; run install cmake --install "$build"; [ -f "$build/CMakeCache.txt" ] || die 'missing CMake cache provenance'; grep -F "CMAKE_PREFIX_PATH:PATH=$snappy" "$build/CMakeCache.txt" >/dev/null || die 'Snappy prefix not recorded in cache'; grep -F "$snappy" "$build/compile_commands.json" >/dev/null || die 'Snappy prefix absent from compile provenance'
[ -f "$stage/include/leveldb/db.h" ] && [ -f "$stage/lib/libleveldb.a" ] || die 'missing installed LevelDB output'; [ -f "$stage/lib/cmake/leveldb/leveldbConfig.cmake" ] || die 'missing installed LevelDB config'; cp "$source/LICENSE" "$stage/LICENSE"
cat > "$build/leveldb-consumer.cc" <<'C'
#include <leveldb/db.h>
#include <leveldb/options.h>
#include <string>
int main() { leveldb::Options o; o.create_if_missing = true; o.compression = leveldb::kSnappyCompression; leveldb::DB* db = nullptr; leveldb::Status s = leveldb::DB::Open(o, "leveldb-consumer-db", &db); if (!s.ok()) return 1; s = db->Put(leveldb::WriteOptions(), "key", "AirDCCore LevelDB fixture"); if (!s.ok()) { delete db; return 2; } std::string value; s = db->Get(leveldb::ReadOptions(), "key", &value); delete db; return s.ok() && value == "AirDCCore LevelDB fixture" ? 0 : 3; }
C
run consumer-compile "$CXX" -arch arm64 -mmacosx-version-min=14.0 "-I$stage/include" "$build/leveldb-consumer.cc" "$stage/lib/libleveldb.a" "$snappy/lib/libsnappy.a" -lpthread -o "$build/leveldb-consumer"; run consumer-run "$build/leveldb-consumer"
