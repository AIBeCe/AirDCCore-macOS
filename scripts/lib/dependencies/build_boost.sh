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
[ -f "$source/LICENSE_1_0.txt" ] || die 'missing Boost license'
cp -R "$source/." "$build/"
run bootstrap "$build/bootstrap.sh" --prefix="$stage" --with-libraries=regex,thread
run build "$build/b2" variant=release link=static runtime-link=shared threading=multi address-model=64 architecture=arm \
  "--prefix=$stage" \
  'cxxflags=-arch arm64 -mmacosx-version-min=14.0 -O3 -DNDEBUG' \
  'linkflags=-arch arm64 -mmacosx-version-min=14.0' --layout=system -j"$jobs" install
[ -f "$stage/include/boost/regex.hpp" ] && [ -f "$stage/include/boost/thread.hpp" ] || die 'missing Boost headers'
[ -f "$stage/lib/libboost_regex.a" ] && [ -f "$stage/lib/libboost_thread.a" ] || die 'missing Boost archives'
[ -f "$stage/lib/cmake/Boost-1.90.0/BoostConfig.cmake" ] || die 'missing Boost config'
cp "$source/LICENSE_1_0.txt" "$stage/LICENSE_1_0.txt"
if find "$stage/lib" \( -name '*.dylib' -o -name '*.so' -o -name '*.so.*' -o -name '*.la' \) | grep -q .; then die 'shared Boost artifact installed'; fi
cat > "$build/consumer.cc" <<'C'
#include <boost/regex.hpp>
#include <boost/thread.hpp>
int main() { bool matched = boost::regex_match("AirDCCore", boost::regex("Air.*")); boost::thread t([]{}); t.join(); return matched ? 0 : 1; }
C
run consumer-compile "$CXX" -std=c++17 -arch arm64 -mmacosx-version-min=14.0 -I"$stage/include" "$build/consumer.cc" "$stage/lib/libboost_regex.a" "$stage/lib/libboost_thread.a" -o "$build/consumer"
run consumer-run "$build/consumer"
