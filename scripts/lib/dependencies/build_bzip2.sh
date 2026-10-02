#!/bin/sh
set -eu

die() { printf '%s\n' "bzip2 adapter: $*" >&2; exit 2; }
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
[ -f "$source/bzlib.h" ] && [ -f "$source/LICENSE" ] || die 'missing source input'
cp -R "$source/." "$build/"

run build make -C "$build" -j "$jobs" \
  'CC=/usr/bin/clang' 'AR=/usr/bin/ar' 'RANLIB=/usr/bin/ranlib' \
  'CFLAGS=-O3 -DNDEBUG -D_FILE_OFFSET_BITS=64 -arch arm64 -mmacosx-version-min=14.0' libbz2.a
run test make -C "$build" -j "$jobs" \
  'CC=/usr/bin/clang' 'AR=/usr/bin/ar' 'RANLIB=/usr/bin/ranlib' \
  'CFLAGS=-O3 -DNDEBUG -D_FILE_OFFSET_BITS=64 -arch arm64 -mmacosx-version-min=14.0' check
[ -f "$build/libbz2.a" ] || die 'missing built archive'
mkdir -p "$stage/include" "$stage/lib"
cp "$build/bzlib.h" "$stage/include/bzlib.h"
cp "$build/libbz2.a" "$stage/lib/libbz2.a"
cp "$source/LICENSE" "$stage/LICENSE"

cat > "$build/bzip2-consumer.c" <<'C'
#include <bzlib.h>
#include <string.h>

int main(void) {
    const char input[] = "AirDCCore";
    char compressed[128];
    char restored[sizeof input];
    unsigned int compressed_size = sizeof compressed;
    unsigned int restored_size = sizeof restored;
    if (BZ2_bzBuffToBuffCompress(compressed, &compressed_size,
            (char *)input, sizeof input, 9, 0, 30) != BZ_OK) return 1;
    if (BZ2_bzBuffToBuffDecompress(restored, &restored_size,
            compressed, compressed_size, 0, 0) != BZ_OK) return 2;
    return restored_size == sizeof input && memcmp(restored, input, sizeof input) == 0 ? 0 : 3;
}
C
run consumer-compile "$CC" -arch arm64 -mmacosx-version-min=14.0 \
  "-I$stage/include" "$build/bzip2-consumer.c" "$stage/lib/libbz2.a" \
  -o "$build/bzip2-consumer"
run consumer-run "$build/bzip2-consumer"
