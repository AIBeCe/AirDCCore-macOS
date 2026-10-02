#!/bin/sh
set -eu

die() { printf '%s\n' "zlib adapter: $*" >&2; exit 2; }
runner=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/command_runner.py
run() { purpose=$1; shift; set +e; python3 "$runner" "$purpose" "$@"; status=$?; set -e; return "$status"; }
[ "$#" -eq 5 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH'
source=$1
build=$2
stage=$3
jobs=$4
epoch=$5
for path in "$source" "$build" "$stage"; do
  [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"
  case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac
done
source=$(CDPATH= cd -- "$source" && pwd -P)
build=$(CDPATH= cd -- "$build" && pwd -P)
stage=$(CDPATH= cd -- "$stage" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'
case "$build/" in "$source/"*) die 'build must be outside source' ;; esac
case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac
case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac
[ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'
: "${CC:?CC is required}"
[ -f "$source/LICENSE" ] || die 'missing source license'

run configure cmake -S "$source" -B "$build" \
  -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_STATIC=ON -DZLIB_BUILD_TESTING=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  "-DCMAKE_INSTALL_PREFIX=$stage"
run build cmake --build "$build" --parallel "$jobs" --target zlibstatic zlib_static_example
run test ctest --test-dir "$build" --output-on-failure
run install cmake --install "$build"
rm -rf "$stage/share"
pc="$stage/lib/pkgconfig/zlib.pc"
[ -f "$pc" ] || die 'missing installed pkg-config metadata'
sed -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
    -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
    -e 's|^libdir=.*|libdir=${pcfiledir}/../../lib|' \
    -e 's|^sharedlibdir=.*|sharedlibdir=${pcfiledir}/../../lib|' \
    -e 's|^includedir=.*|includedir=${pcfiledir}/../../include|' "$pc" > "$pc.tmp"
mv "$pc.tmp" "$pc"
cp "$source/LICENSE" "$stage/LICENSE"
for path in "$stage/include/zlib.h" "$stage/include/zconf.h" "$stage/lib/libz.a" \
    "$stage/lib/cmake/zlib/ZLIBConfig.cmake" "$stage/lib/cmake/zlib/ZLIBConfigVersion.cmake" \
    "$stage/lib/cmake/zlib/ZLIB-static.cmake" "$stage/lib/cmake/zlib/ZLIB-static-release.cmake" "$stage/lib/pkgconfig/zlib.pc"; do
  [ -f "$path" ] && [ ! -L "$path" ] || die "missing installed output: $path"
done

cat > "$build/zlib-consumer.c" <<'C'
#include <zlib.h>
#include <string.h>

int main(void) {
    const Bytef input[] = "AirDCCore";
    Bytef compressed[128];
    Bytef restored[sizeof input];
    uLongf compressed_size = sizeof compressed;
    uLongf restored_size = sizeof restored;
    if (compress2(compressed, &compressed_size, input, sizeof input, Z_BEST_COMPRESSION) != Z_OK) return 1;
    if (uncompress(restored, &restored_size, compressed, compressed_size) != Z_OK) return 2;
    return restored_size == sizeof input && memcmp(restored, input, sizeof input) == 0 ? 0 : 3;
}
C
run consumer-compile "$CC" -arch arm64 -mmacosx-version-min=14.0 \
  "-I$stage/include" "$build/zlib-consumer.c" "$stage/lib/libz.a" \
  -o "$build/zlib-consumer"
run consumer-run "$build/zlib-consumer"
