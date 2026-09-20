#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/tests/test_helper.sh"
WORK=$(new_temp_dir)
WORK=$(CDPATH= cd -- "$WORK" && pwd -P)
trap 'rm -rf -- "$WORK"' 0 1 2 15
NINJA=$(command -v ninja)
failures=0

# These fixtures catch wrong header/library lookup, incorrect target properties,
# accidental host fallback, and duplicate target creation on repeated discovery.
mkdir -p "$WORK/fixture"
cat > "$WORK/fixture/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.25)
project(FindModulesFixture LANGUAGES NONE)
list(PREPEND CMAKE_MODULE_PATH "${MODULES}")
find_package(${PACKAGE} REQUIRED)
find_package(${PACKAGE} REQUIRED)
if(NOT TARGET "${PACKAGE}::${PACKAGE}")
  message(FATAL_ERROR "Missing namespaced imported target")
endif()
get_target_property(is_imported "${PACKAGE}::${PACKAGE}" IMPORTED)
get_target_property(location "${PACKAGE}::${PACKAGE}" IMPORTED_LOCATION)
get_target_property(includes "${PACKAGE}::${PACKAGE}" INTERFACE_INCLUDE_DIRECTORIES)
if(NOT is_imported OR NOT "${location}" STREQUAL "${EXPECTED_LIBRARY}"
    OR NOT "${includes}" STREQUAL "${EXPECTED_INCLUDE}")
  message(FATAL_ERROR "Incorrect imported target: imported=${is_imported}; location=${location}; includes=${includes}; expected_library=${EXPECTED_LIBRARY}; expected_include=${EXPECTED_INCLUDE}")
endif()
CMAKE

for package in miniupnpc maxminddb; do
  case "$package" in
    miniupnpc) header=miniupnpc/miniupnpc.h ;;
    maxminddb) header=maxminddb.h ;;
  esac
  for scenario in complete missing-header missing-library 'path with spaces'; do
    prefix=$WORK/$package/$scenario/prefix
    mkdir -p "$prefix/include/$(dirname "$header")" "$prefix/lib"
    if [ "$scenario" != missing-header ]; then
      printf '/* configure-only fixture */\n' > "$prefix/include/$header"
    fi
    if [ "$scenario" != missing-library ]; then
      # Apple ar requires a member at creation; its ranlib may discard non-Mach-O
      # members. Remove any retained text member, leaving no ordinary members.
      printf 'fixture\n' > "$prefix/member"
      ar -cr "$prefix/lib/lib$package.a" "$prefix/member" 2> "$prefix/ar.log"
      if ar -t "$prefix/lib/lib$package.a" | grep -qx member; then
        ar -d "$prefix/lib/lib$package.a" member
      fi
      ordinary_members=$(ar -t "$prefix/lib/lib$package.a" | sed '/^__.SYMDEF/d')
      [ -z "$ordinary_members" ] || fail "fixture archive is not empty"
    fi
    log=$WORK/$package/$scenario/configure.log
    if cmake -S "$WORK/fixture" -B "$WORK/$package/$scenario/build" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$NINJA" \
      -DMODULES="$ROOT/cmake/modules" -DPACKAGE="$package" \
      -DCMAKE_PREFIX_PATH="$prefix" \
      -DEXPECTED_LIBRARY="$prefix/lib/lib$package.a" \
      -DEXPECTED_INCLUDE="$prefix/include" \
      -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=TRUE \
      -DCMAKE_FIND_USE_PACKAGE_ROOT_PATH=FALSE \
      -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=FALSE \
      -DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=FALSE \
      -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=FALSE \
      -DCMAKE_FIND_USE_INSTALL_PREFIX=FALSE > "$log" 2>&1; then
      case "$scenario" in
        missing-*) printf 'FAIL: %s %s unexpectedly found host package\n' "$package" "$scenario" >&2; failures=$((failures + 1)) ;;
        *) printf 'PASS: %s %s and repeated discovery\n' "$package" "$scenario" ;;
      esac
    else
      case "$scenario" in
        missing-header) expected="${package}_INCLUDE_DIR" ;;
        missing-library) expected="${package}_LIBRARY" ;;
        *) expected= ;;
      esac
      if [ -n "$expected" ] && grep -Fq "Could NOT find $package (missing: $expected)" "$log"; then
        printf 'PASS: %s %s rejection\n' "$package" "$scenario"
      else
        cat "$log" >&2
        printf 'FAIL: %s %s configure contract\n' "$package" "$scenario" >&2
        failures=$((failures + 1))
      fi
    fi
  done
done
[ "$failures" -eq 0 ] || fail "$failures package adapter cases"
printf 'PASS: Homebrew package adapters\n'
