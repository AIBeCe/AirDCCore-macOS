#!/bin/sh
set -eu
die() { printf '%s\n' "miniupnpc adapter: $*" >&2; exit 2; }
helper=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/network_adapter.py
run() { purpose=$1; shift; set +e; python3 "$helper" run "$purpose" "$@"; status=$?; set -e; return "$status"; }
[ "$#" -eq 5 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH'; source=$1; build=$2; stage=$3; jobs=$4; epoch=$5
for path in "$source" "$build" "$stage"; do [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"; case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac; done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'; case "$build/" in "$source/"*) die 'build must be outside source' ;; esac; case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac; case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac; [ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'; : "${CC:?CC is required}"
[ -f "$source/CMakeLists.txt" ] && [ -f "$source/LICENSE" ] || die 'missing source CMakeLists.txt or license'
run configure cmake -S "$source" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_INSTALL_PREFIX=$stage" -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_SHARED=OFF -DUPNPC_BUILD_TESTS=ON -DUPNPC_BUILD_SAMPLE=OFF
run build cmake --build "$build" --parallel "$jobs"; run test ctest --test-dir "$build" --output-on-failure; run install cmake --install "$build"
python3 "$helper" prune-docs "$source/man3" "$stage/share/man/man3"
rm "$stage/bin/external-ip.sh"
rmdir "$stage/bin"
cp "$source/LICENSE" "$stage/LICENSE"
python3 "$helper" relocate-pc "$stage/lib/pkgconfig/miniupnpc.pc"
for relative in include/miniupnpc/miniupnpc.h lib/libminiupnpc.a \
    lib/cmake/miniupnpc/miniupnpc-config.cmake lib/cmake/miniupnpc/miniupnpc-private.cmake \
    lib/cmake/miniupnpc/libminiupnpc-static.cmake lib/cmake/miniupnpc/libminiupnpc-static-release.cmake \
    lib/pkgconfig/miniupnpc.pc LICENSE; do
  [ -f "$stage/$relative" ] && [ ! -L "$stage/$relative" ] || die "missing installed output: $relative"
done
cat > "$build/miniupnpc-consumer.c" <<'C'
#include <miniupnpc/miniupnpc.h>
#include <stddef.h>
#include <string.h>
int main(void) {
    if (strcmp(MINIUPNPC_VERSION, "2.3.3") != 0) return 1;
    freeUPNPDevlist(NULL);
    return 0;
}
C
run consumer-compile "$CC" -arch arm64 -mmacosx-version-min=14.0 "-I$stage/include" "$build/miniupnpc-consumer.c" "$stage/lib/libminiupnpc.a" -o "$build/miniupnpc-consumer"; run consumer-run "$build/miniupnpc-consumer"
