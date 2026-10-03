#!/bin/sh
set -eu
die() { printf '%s\n' "libmaxminddb adapter: $*" >&2; exit 2; }
helper=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/network_adapter.py
run() { purpose=$1; shift; set +e; python3 "$helper" run "$purpose" "$@"; status=$?; set -e; return "$status"; }
[ "$#" -eq 5 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH'; source=$1; build=$2; stage=$3; jobs=$4; epoch=$5
for path in "$source" "$build" "$stage"; do [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"; case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac; done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'; case "$build/" in "$source/"*) die 'build must be outside source' ;; esac; case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac; case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac; [ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'; : "${CC:?CC is required}"
[ -f "$source/CMakeLists.txt" ] && [ -f "$source/LICENSE" ] || die 'missing source CMakeLists.txt or license'
# The pinned release includes man pages. Without them upstream configure would
# generate pages in SOURCE, violating the immutable-source contract.
[ -d "$source/man" ] || die 'missing pinned source man pages'
run configure cmake -S "$source" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_INSTALL_PREFIX=$stage" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=ON -DMAXMINDDB_BUILD_BINARIES=OFF -DMAXMINDDB_INSTALL=ON
run build cmake --build "$build" --parallel "$jobs"; run test ctest --test-dir "$build" --output-on-failure; run install cmake --install "$build"
python3 "$helper" prune-docs "$source/man" "$stage/share/man"
cp "$source/LICENSE" "$stage/LICENSE"
python3 "$helper" relocate-pc "$stage/lib/pkgconfig/libmaxminddb.pc"
for relative in include/maxminddb.h lib/libmaxminddb.a \
    lib/cmake/maxminddb/maxminddb-config.cmake lib/cmake/maxminddb/maxminddb-config-release.cmake \
    lib/pkgconfig/libmaxminddb.pc LICENSE; do
  [ -f "$stage/$relative" ] && [ ! -L "$stage/$relative" ] || die "missing installed output: $relative"
done
cat > "$build/libmaxminddb-consumer.c" <<'C'
#include <maxminddb.h>
#include <string.h>
int main(void) { const char *version = MMDB_lib_version(); return version && *version ? 0 : 1; }
C
run consumer-compile "$CC" -arch arm64 -mmacosx-version-min=14.0 "-I$stage/include" "$build/libmaxminddb-consumer.c" "$stage/lib/libmaxminddb.a" -o "$build/libmaxminddb-consumer"; run consumer-run "$build/libmaxminddb-consumer"
