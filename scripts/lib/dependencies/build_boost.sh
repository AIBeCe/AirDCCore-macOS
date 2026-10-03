#!/bin/sh
set -eu
die() { printf '%s\n' "boost adapter: $*" >&2; exit 2; }
runner=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/command_runner.py
run() { purpose=$1; shift; set +e; python3 "$runner" "$purpose" "$@"; status=$?; set -e; return "$status"; }
[ "$#" -eq 5 ] || die 'expected SOURCE BUILD STAGE JOBS EPOCH'
source=$1; build=$2; stage=$3; jobs=$4; epoch=$5
for path in "$source" "$build" "$stage"; do
  [ -d "$path" ] && [ ! -L "$path" ] || die "missing or unsafe directory: $path"
  case "$path" in /*) ;; *) die "path must be absolute: $path" ;; esac
done
source=$(CDPATH= cd -- "$source" && pwd -P); build=$(CDPATH= cd -- "$build" && pwd -P); stage=$(CDPATH= cd -- "$stage" && pwd -P)
[ "$source" != "$build" ] && [ "$source" != "$stage" ] && [ "$build" != "$stage" ] || die 'directories must be distinct'
case "$build/" in "$source/"*) die 'build must be outside source' ;; esac
case "$stage/" in "$source/"*|"$build/"*) die 'stage must be outside source and build' ;; esac
case "$jobs" in ''|*[!0-9]*|0) die 'JOBS must be a positive integer' ;; esac
case "$epoch" in ''|*[!0-9]*) die 'EPOCH must be a nonnegative integer' ;; esac
[ "${SOURCE_DATE_EPOCH:-}" = "$epoch" ] || die 'epoch disagrees with build environment'
: "${CXX:?CXX is required}"
: "${PATCH:?PATCH is required}"
[ "$PATCH" = /usr/bin/patch ] || die 'PATCH must be the inventoried /usr/bin/patch'
[ -f "$source/LICENSE_1_0.txt" ] || die 'missing Boost license'
cp -R "$source/." "$build/"
project=$(CDPATH= cd -- "$(dirname -- "$runner")/../../.." && pwd -P)
# This is deliberately limited to the single reviewed Boost 1.90.0 generator
# patch. Keep the immutable Source tree intact and bind the tool's input to the
# bytes validated here, rather than reopening a mutable repository artifact.
python3 - "$project" "$build" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

project, build = map(Path, sys.argv[1:])
sys.path.insert(0, str(project/'scripts/lib'))
from dependency_lock import load_lock

record = next(r for r in load_lock(project/'config/dependencies.lock').dependencies if r.name == 'boost')
patch_path = 'config/patches/boost-1.90.0-relocatable-cmake.patch'
if record.version != '1.90.0' or len(record.patches) != 1 or record.patches[0].path != patch_path:
    raise SystemExit('boost adapter: expected the sole reviewed Boost relocation patch')
with os.fdopen(os.open(project/patch_path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
        raise SystemExit('boost adapter: unsafe Boost patch input')
    raw = stream.read()
digest = hashlib.sha256(raw).hexdigest()
if digest != record.patches[0].sha256:
    raise SystemExit('boost adapter: Boost patch sha256 mismatch')
lines = raw.splitlines(keepends=True)
headers = [b'--- a/tools/boost_install/boost-install.jam\n',
           b'+++ b/tools/boost_install/boost-install.jam\n', b'@@ -800,19 +799,0 @@\n']
if lines[:3] != headers or len(lines[3:]) != 19 or any(line[:1] != b'-' for line in lines[3:]):
    raise SystemExit('boost adapter: unexpected Boost patch structure')
target = build/'tools/boost_install/boost-install.jam'
if target.resolve(strict=True) != target or not target.is_file():
    raise SystemExit('boost adapter: unsafe private Boost patch target')
preimage = b''.join(line[1:] for line in lines[3:])
if b''.join(target.read_bytes().splitlines(keepends=True)[799:818]) != preimage:
    raise SystemExit('boost adapter: Boost patch preimage mismatch')
snapshot = build/'.boost-relocation.patch'
with os.fdopen(os.open(snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400), 'wb') as stream:
    stream.write(raw)
print(json.dumps({'type': 'patch-input', 'path': patch_path, 'snapshot': str(snapshot), 'sha256': digest}), flush=True)
PY
run patch /usr/bin/patch --batch --forward --fuzz=0 --no-backup-if-mismatch \
  "$build/tools/boost_install/boost-install.jam" "$build/.boost-relocation.patch"
(
  cd "$build"
  run bootstrap "$build/bootstrap.sh" --prefix="$stage" --with-libraries=regex,thread
  run build "$build/b2" variant=release link=static runtime-link=shared threading=multi address-model=64 architecture=arm \
    "--prefix=$stage" \
    'cxxflags=-arch arm64 -mmacosx-version-min=14.0 -O3 -DNDEBUG' \
    'linkflags=-arch arm64 -mmacosx-version-min=14.0' --layout=system -j"$jobs" install
)
[ -f "$stage/include/boost/regex.hpp" ] && [ -f "$stage/include/boost/thread.hpp" ] || die 'missing Boost headers'
[ -f "$stage/lib/libboost_regex.a" ] && [ -f "$stage/lib/libboost_thread.a" ] || die 'missing Boost archives'
[ -f "$stage/lib/cmake/Boost-1.90.0/BoostConfig.cmake" ] || die 'missing Boost config'
cp "$source/LICENSE_1_0.txt" "$stage/LICENSE_1_0.txt"
if find "$stage/lib" \( -name '*.dylib' -o -name '*.so' -o -name '*.so.*' -o -name '*.la' \) | grep -q .; then die 'shared Boost artifact installed'; fi
mkdir -p "$build/consumer-source"
cat > "$build/consumer-source/consumer.cc" <<'C'
#include <boost/regex.hpp>
#include <boost/thread.hpp>
int main() {
  bool matched = boost::regex_match("AirDCCore", boost::regex("Air.*"));
  bool rejected = !boost::regex_match("Other", boost::regex("Air.*"));
  int completed = 0;
  boost::thread t([&completed] { ++completed; });
  t.join();
  return matched && rejected && completed == 1 ? 0 : 1;
}
C
cat > "$build/consumer-source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(installed_boost_consumer LANGUAGES CXX)
find_package(Boost 1.90.0 CONFIG REQUIRED COMPONENTS regex thread
  PATHS "${EXPECTED_BOOST_PREFIX}/lib/cmake/Boost-1.90.0" NO_DEFAULT_PATH)
# Every Boost archive reached by the imported target closure must be installed
# under this prefix. Header-only targets and Apple system targets have no archive.
file(REAL_PATH "${EXPECTED_BOOST_PREFIX}/lib" installed_lib)
get_property(imported_targets DIRECTORY PROPERTY IMPORTED_TARGETS)
foreach(target IN LISTS imported_targets)
  if(NOT target MATCHES "^Boost::")
    continue()
  endif()
  get_target_property(configurations "${target}" IMPORTED_CONFIGURATIONS)
  set(location_properties IMPORTED_LOCATION)
  foreach(configuration IN LISTS configurations)
    string(TOUPPER "${configuration}" configuration)
    list(APPEND location_properties "IMPORTED_LOCATION_${configuration}")
  endforeach()
  foreach(property IN LISTS location_properties)
    get_target_property(location "${target}" "${property}")
    if(location)
      file(REAL_PATH "${location}" archive)
      string(FIND "${archive}" "${installed_lib}/" prefix_position)
      if(NOT prefix_position EQUAL 0 OR NOT archive MATCHES "\\.a$" OR NOT EXISTS "${archive}")
        message(FATAL_ERROR "Boost target ${target} uses an archive outside the installed prefix: ${location}")
      endif()
    endif()
  endforeach()
endforeach()
add_executable(boost-consumer consumer.cc)
target_compile_features(boost-consumer PRIVATE cxx_std_17)
target_link_libraries(boost-consumer PRIVATE Boost::regex Boost::thread)
CMAKE
run consumer-configure cmake -S "$build/consumer-source" -B "$build/consumer-build" \
  -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_COMPILER=$CXX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  "-DEXPECTED_BOOST_PREFIX=$stage" "-DCMAKE_PREFIX_PATH=$stage" \
  "-DBoost_DIR=$stage/lib/cmake/Boost-1.90.0" -DBoost_USE_STATIC_LIBS=ON \
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF
run consumer-build cmake --build "$build/consumer-build" --parallel "$jobs"
run consumer-run "$build/consumer-build/boost-consumer"
