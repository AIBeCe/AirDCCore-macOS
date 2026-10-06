#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
WORK=$(TMPDIR=/private/tmp new_temp_dir)
trap 'rm -rf -- "$WORK"' 0 1 2 15

run_case() {
  name=$1
  leveldb=$2
  snappy_target=$3
  links=$4
  source=$WORK/$name/source
  build=$WORK/$name/build
  mkdir -p "$source"
  cat > "$source/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.25)
project(LinkAdapterContract LANGUAGES NONE)
if("$leveldb" STREQUAL "yes")
  add_library(leveldb::leveldb INTERFACE IMPORTED)
  set_property(TARGET leveldb::leveldb PROPERTY INTERFACE_LINK_LIBRARIES "$links")
endif()
if("$snappy_target" STREQUAL "yes")
  add_library(Snappy::snappy INTERFACE IMPORTED)
endif()
include("$ROOT/cmake/modules/AirDCCoreLinkAdapters.cmake")
airdcpp_adapt_leveldb_snappy()
get_target_property(repaired leveldb::leveldb INTERFACE_LINK_LIBRARIES)
message(STATUS "REPAIRED=\${repaired}")
EOF
  cmake -S "$source" -B "$build" -G Ninja 2>&1
}

if ! output=$(run_case positive yes yes 'snappy;Threads::Threads'); then
  fail "positive adapter case failed: $output"
fi
assert_contains "$output" 'REPAIRED=Snappy::snappy;Threads::Threads' 'exact LevelDB Snappy repair'

if output=$(run_case missing-leveldb no yes 'snappy;Threads::Threads'); then
  fail 'missing leveldb::leveldb target was accepted'
fi
assert_contains "$output" 'leveldb::leveldb target is required' 'missing LevelDB target diagnostic'

if output=$(run_case missing-snappy yes no 'snappy;Threads::Threads'); then
  fail 'missing Snappy::snappy target was accepted'
fi
assert_contains "$output" 'Snappy::snappy target is required' 'missing Snappy target diagnostic'

if output=$(run_case absent-item yes yes 'Threads::Threads'); then
  fail 'LevelDB metadata without plain snappy was accepted'
fi
assert_contains "$output" 'expected exactly one plain snappy item; found 0' 'absent plain Snappy diagnostic'

if output=$(run_case ambiguous yes yes 'snappy;Threads::Threads;snappy'); then
  fail 'ambiguous plain snappy metadata was accepted'
fi
assert_contains "$output" 'expected exactly one plain snappy item; found 2' 'ambiguous plain Snappy diagnostic'

run_iconv_case() {
  name=$1
  library=$2
  source=$WORK/iconv-$name/source
  build=$WORK/iconv-$name/build
  mkdir -p "$source"
  cat > "$source/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.25)
project(SystemIconvAdapterContract LANGUAGES NONE)
include("$ROOT/cmake/modules/AirDCCoreLinkAdapters.cmake")
airdcpp_define_system_iconv("$library")
get_target_property(link_items AirDCCore::SystemIconv INTERFACE_LINK_LIBRARIES)
message(STATUS "SYSTEM_ICONV=\${link_items}")
EOF
  cmake -S "$source" -B "$build" -G Ninja 2>&1
}

ICONV_STUB=$WORK/libiconv.tbd
: > "$ICONV_STUB"
if ! output=$(run_iconv_case positive "$ICONV_STUB"); then
  fail "positive system Iconv case failed: $output"
fi
assert_contains "$output" "SYSTEM_ICONV=$ICONV_STUB" 'exact system Iconv stub'

if output=$(run_iconv_case relative libiconv.tbd); then
  fail 'relative system Iconv stub was accepted'
fi
assert_contains "$output" 'system Iconv library must be absolute' 'relative system Iconv diagnostic'

if output=$(run_iconv_case missing "$WORK/missing-libiconv.tbd"); then
  fail 'missing system Iconv stub was accepted'
fi
assert_contains "$output" 'system Iconv library must be a regular file' 'missing system Iconv diagnostic'

ln -s "$ICONV_STUB" "$WORK/symlink-libiconv.tbd"
if output=$(run_iconv_case symlink "$WORK/symlink-libiconv.tbd"); then
  fail 'symlinked system Iconv stub was accepted'
fi
assert_contains "$output" 'system Iconv library must not be a symlink' 'symlinked system Iconv diagnostic'

printf 'PASS: LevelDB Snappy and system Iconv link adapters\n'
