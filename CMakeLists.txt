cmake_minimum_required(VERSION 3.25)
project(AirDCCoreMacOS LANGUAGES C CXX)

# Narrow miniupnpc/maxminddb adapters cover formulae without CMake configs.
list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")
include(AirDCCorePolicy)
option(AIRDCCORE_REPRODUCIBLE_INPUTS "Require declared reproducible dependency prefixes" OFF)
airdcpp_require_apple_clang()

if("${CMAKE_BUILD_TYPE}" STREQUAL "")
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Single-config discovery mode" FORCE)
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries")
set(CMAKE_CXX_STANDARD 20 CACHE STRING "Required C++ standard")
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(ENABLE_NATPMP OFF CACHE BOOL "Deterministic Phase 2 NAT-PMP policy")
set(ENABLE_TBB OFF CACHE BOOL "Deterministic Phase 2 TBB policy")

airdcpp_require_value(CMAKE_BUILD_TYPE "${CMAKE_BUILD_TYPE}" Release)
airdcpp_require_value(BUILD_SHARED_LIBS "${BUILD_SHARED_LIBS}" OFF)
airdcpp_require_value(CMAKE_OSX_ARCHITECTURES "${CMAKE_OSX_ARCHITECTURES}" arm64)
airdcpp_require_value(CMAKE_CXX_STANDARD "${CMAKE_CXX_STANDARD}" 20)

if(NOT CMAKE_OSX_DEPLOYMENT_TARGET MATCHES "^(13\\.0|14\\.0|15\\.0)$")
  message(FATAL_ERROR "deployment target must be one of 13.0, 14.0, or 15.0")
endif()

include(CheckFunctionExists)
include(CheckIncludeFiles)

set(VERSION 0.0.0 CACHE STRING "Configure-only upstream target version")
set(TAG_APPLICATION AirDCCore-macOS CACHE STRING "Configure-only application name")
set(APPLICATION_ID org.airdcpp.core.macos.configure CACHE STRING "Configure-only application identifier")
set(RESOURCE_DIRECTORY share/airdcpp CACHE STRING "Runtime resource contract")
set(GLOBAL_CONFIG_DIRECTORY "Library/Application Support/AirDC++" CACHE STRING "Runtime config contract")
set(PROJECT_NAME_GLOBAL AirDCCore CACHE STRING "Parent project name")
set(AIRDCPP_CORE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/Source/airdcpp-core" CACHE PATH "Pinned source checkout")

# The parent summary must see imports discovered by upstream find_package calls.
set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL TRUE)
set(AIRDCPP_EFFECTIVE_SOURCE_DIR "${AIRDCPP_CORE_SOURCE_DIR}")
if(AIRDCCORE_REPRODUCIBLE_INPUTS AND DEFINED AIRDCCORE_STAGED_SOURCE_DIR)
  file(REAL_PATH "${AIRDCCORE_STAGED_SOURCE_DIR}" staged_real)
  if(NOT staged_real STREQUAL "${CMAKE_BINARY_DIR}/source")
    message(FATAL_ERROR "private Core source must be the build-owned source directory")
  endif()
  set(AIRDCPP_EFFECTIVE_SOURCE_DIR "${staged_real}")
  airdcpp_define_core_version_command()
endif()
add_subdirectory("${AIRDCPP_EFFECTIVE_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/upstream")
set(AIRDCPP_SOURCE_PREFIX_MAP airdcpp-core)
airdcpp_apply_source_prefix_map(airdcpp
  "${AIRDCPP_EFFECTIVE_SOURCE_DIR}" "${AIRDCPP_SOURCE_PREFIX_MAP}")

# Homebrew LevelDB currently exports its own -Werror to every consumer.
# Keep its thread-safety diagnostic, but do not let a dependency set Core's
# warning-as-error policy. Inspect the measured interface before adapting it.
if(NOT TARGET leveldb::leveldb)
  message(FATAL_ERROR "LevelDB imported target was not discovered by upstream")
endif()
if(AIRDCCORE_REPRODUCIBLE_INPUTS)
  include(AirDCCoreLinkAdapters)
  airdcpp_adapt_reproducible_leveldb()
else()
get_target_property(_leveldb_compile_options leveldb::leveldb INTERFACE_COMPILE_OPTIONS)
if("${_leveldb_compile_options}" MATCHES "-NOTFOUND$")
  message(FATAL_ERROR "LevelDB interface compile options are unavailable")
endif()
list(FIND _leveldb_compile_options "-Werror" _leveldb_werror_index)
list(FIND _leveldb_compile_options "-Wthread-safety" _leveldb_thread_safety_index)
if(_leveldb_werror_index EQUAL -1 OR _leveldb_thread_safety_index EQUAL -1)
  message(FATAL_ERROR
    "LevelDB interface compile options differ from measured Homebrew input: ${_leveldb_compile_options}")
endif()
list(REMOVE_ITEM _leveldb_compile_options "-Werror")
set_property(TARGET leveldb::leveldb PROPERTY INTERFACE_COMPILE_OPTIONS
  "${_leveldb_compile_options}")
endif()

set(AIRDCPP_CONFIGURE_SUMMARY "${CMAKE_BINARY_DIR}/airdcpp-configure-summary.txt")
file(WRITE "${AIRDCPP_CONFIGURE_SUMMARY}"
  "compiler.id=${CMAKE_CXX_COMPILER_ID}\n"
  "compiler.c.id=${CMAKE_C_COMPILER_ID}\n"
  "compiler.c.path=${CMAKE_C_COMPILER}\n"
  "compiler.cxx.path=${CMAKE_CXX_COMPILER}\n"
  "compiler.cxx.implicit_link_libraries=${CMAKE_CXX_IMPLICIT_LINK_LIBRARIES}\n"
  "sdk=${CMAKE_OSX_SYSROOT}\n"
  "architecture=${CMAKE_OSX_ARCHITECTURES}\n"
  "deployment_target=${CMAKE_OSX_DEPLOYMENT_TARGET}\n"
  "build_type=${CMAKE_BUILD_TYPE}\n"
  "cxx_standard=${CMAKE_CXX_STANDARD}\n"
  "cxx_standard_required=${CMAKE_CXX_STANDARD_REQUIRED}\n"
  "cxx_extensions=${CMAKE_CXX_EXTENSIONS}\n"
  "build_shared_libs=${BUILD_SHARED_LIBS}\n"
  "enable_natpmp=${ENABLE_NATPMP}\n"
  "enable_tbb=${ENABLE_TBB}\n"
  "source.file_prefix_map=${AIRDCPP_SOURCE_PREFIX_MAP}\n"
  "upstream_source=${AIRDCPP_CORE_SOURCE_DIR}\n"
  "parent.version=${VERSION}\n"
  "parent.tag_application=${TAG_APPLICATION}\n"
  "parent.application_id=${APPLICATION_ID}\n"
  "parent.resource_directory=${RESOURCE_DIRECTORY}\n"
  "parent.global_config_directory=${GLOBAL_CONFIG_DIRECTORY}\n"
  "parent.project_name=${PROJECT_NAME_GLOBAL}\n")
if(AIRDCCORE_REPRODUCIBLE_INPUTS AND DEFINED AIRDCCORE_STAGED_SOURCE_DIR)
  file(APPEND "${AIRDCPP_CONFIGURE_SUMMARY}"
    "effective_upstream_source=${AIRDCPP_EFFECTIVE_SOURCE_DIR}\n")
endif()

set(AIRDCPP_REQUIRED_DEPENDENCY_TARGETS
    BZip2::BZip2
    ZLIB::ZLIB
    OpenSSL::SSL
    OpenSSL::Crypto
    miniupnpc::miniupnpc
    leveldb::leveldb
    maxminddb::maxminddb
    Boost::thread
    Boost::regex
    Snappy::snappy
    Threads::Threads
    Iconv::Iconv)
foreach(required_target IN LISTS AIRDCPP_REQUIRED_DEPENDENCY_TARGETS)
  airdcpp_record_target("${required_target}" "${AIRDCPP_CONFIGURE_SUMMARY}")
endforeach()
if(AIRDCCORE_REPRODUCIBLE_INPUTS)
  airdcpp_record_dependency_resolution("${CMAKE_BINARY_DIR}/dependency-resolution.tsv"
    ${AIRDCPP_REQUIRED_DEPENDENCY_TARGETS})
endif()
