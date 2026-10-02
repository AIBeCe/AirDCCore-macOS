#!/bin/sh
set -eu
die() { printf '%s\n' "miniupnpc adapter: $*" >&2; exit 2; }
run() { purpose=$1; shift; printf 'adapter-command\t%s' "$purpose"; for arg in "$@"; do printf '\t%s' "$arg"; done; printf '\n'; set +e; "$@"; status=$?; set -e; printf 'adapter-status\t%s\t%s\n' "$purpose" "$status"; return "$status"; }
[ "$#" -eq 5 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH'; source=$1; build=$2; stage=$3; jobs=$4; epoch=$5
for path in "$source" "$build" "$stage"; do [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"; case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac; done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'; case "$build/" in "$source/"*) die 'build must be outside source' ;; esac; case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac; case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac; [ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'; : "${CC:?CC is required}"
[ -f "$source/CMakeLists.txt" ] || die 'missing source CMakeLists.txt'
run configure cmake -S "$source" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_INSTALL_PREFIX=$stage" -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_SHARED=OFF -DUPNPC_BUILD_TESTS=ON -DUPNPC_BUILD_SAMPLE=OFF
run build cmake --build "$build" --parallel "$jobs"; run test ctest --test-dir "$build" --output-on-failure; run install cmake --install "$build"
[ -f "$stage/include/miniupnpc/miniupnpc.h" ] && [ -f "$stage/lib/libminiupnpc.a" ] || die 'missing installed miniupnpc output'
cat > "$build/miniupnpc-consumer.c" <<'C'
#include <miniupnpc/miniupnpc.h>
int main(void) { return miniupnpc_lib_version() == 0 ? 1 : 0; }
C
run consumer-compile "$CC" -arch arm64 -mmacosx-version-min=14.0 "-I$stage/include" "$build/miniupnpc-consumer.c" "$stage/lib/libminiupnpc.a" -o "$build/miniupnpc-consumer"; run consumer-run "$build/miniupnpc-consumer"
