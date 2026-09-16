cmake_minimum_required(VERSION 3.25)
project(AirDCCoreMacOS LANGUAGES C CXX)

list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")
include(AirDCCorePolicy)
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
add_subdirectory("${AIRDCPP_CORE_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/upstream")

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
  "upstream_source=${AIRDCPP_CORE_SOURCE_DIR}\n"
  "parent.version=${VERSION}\n"
  "parent.tag_application=${TAG_APPLICATION}\n"
  "parent.application_id=${APPLICATION_ID}\n"
  "parent.resource_directory=${RESOURCE_DIRECTORY}\n"
  "parent.global_config_directory=${GLOBAL_CONFIG_DIRECTORY}\n"
  "parent.project_name=${PROJECT_NAME_GLOBAL}\n")

foreach(required_target IN ITEMS
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
  airdcpp_record_target("${required_target}" "${AIRDCPP_CONFIGURE_SUMMARY}")
endforeach()
