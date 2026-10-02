#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P); fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for file in build_snappy.sh build_leveldb.sh; do path="$ROOT/scripts/lib/dependencies/$file"; [ -x "$path" ] || fail "$file not executable"; grep -F 'expected SOURCE BUILD STAGE JOBS' "$path" >/dev/null || fail "$file contract"; grep -F 'cmake -S "$source" -B "$build"' "$path" >/dev/null || fail "$file CMake/Ninja invocation"; done
snappy="$ROOT/scripts/lib/dependencies/build_snappy.sh"; leveldb="$ROOT/scripts/lib/dependencies/build_leveldb.sh"
grep -F -- '-DSNAPPY_BUILD_TESTS=OFF' "$snappy" >/dev/null || fail 'Snappy tests enabled'; grep -F -- '-DSNAPPY_BUILD_BENCHMARKS=OFF' "$snappy" >/dev/null || fail 'Snappy benchmarks enabled'; grep -F -- '-DLEVELDB_BUILD_TESTS=OFF' "$leveldb" >/dev/null || fail 'LevelDB tests enabled'; grep -F -- '-DLEVELDB_BUILD_BENCHMARKS=OFF' "$leveldb" >/dev/null || fail 'LevelDB benchmarks enabled'; grep -F 'unset CMAKE_PREFIX_PATH PKG_CONFIG_PATH' "$leveldb" >/dev/null || fail 'ambient package path not cleared'; grep -F -- '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF' "$leveldb" >/dev/null || fail 'package registry enabled'; grep -F 'kSnappyCompression' "$leveldb" >/dev/null || fail 'consumer lacks Snappy compression'; grep -F 'libsnappy.a' "$leveldb" >/dev/null || fail 'consumer lacks exact Snappy archive'
work=$(mktemp -d "${TMPDIR:-/tmp}/leveldb-chain.XXXXXX"); trap 'rm -rf "$work"' EXIT; mkdir -p "$work/src" "$work/build" "$work/stage" "$work/snappy"; export SOURCE_DATE_EPOCH=1 CC=/usr/bin/clang CXX=/usr/bin/clang++
if "$leveldb" "$work/src" "$work/build" "$work/stage" 1 1; then fail 'LevelDB accepted missing prefix'; fi
if "$leveldb" "$work/src" "$work/build" "$work/stage" 1 1 "$work/snappy" "$work/snappy"; then fail 'LevelDB accepted multiple prefixes'; fi
printf 'PASS: Snappy/LevelDB chain contract and provenance guards\n'
