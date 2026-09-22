cmake_minimum_required(VERSION 3.25)
project(AirDCCoreSmoke LANGUAGES CXX)

function(require_absolute_path variable kind)
  if(NOT DEFINED ${variable} OR "${${variable}}" STREQUAL "")
    message(FATAL_ERROR "${variable} is required")
  endif()
  if(NOT IS_ABSOLUTE "${${variable}}")
    message(FATAL_ERROR "${variable} must be absolute")
  endif()
  if(IS_SYMLINK "${${variable}}")
    message(FATAL_ERROR "${variable} must not be a symlink")
  endif()
  if(kind STREQUAL "FILE")
    if(NOT EXISTS "${${variable}}" OR IS_DIRECTORY "${${variable}}")
      message(FATAL_ERROR "${variable} must be a regular file")
    endif()
  elseif(kind STREQUAL "DIRECTORY")
    if(NOT IS_DIRECTORY "${${variable}}")
      message(FATAL_ERROR "${variable} must be a directory")
    endif()
  else()
    message(FATAL_ERROR "internal path kind is unsupported: ${kind}")
  endif()
endfunction()

require_absolute_path(AIRDCCORE_INCLUDE_DIR DIRECTORY)
require_absolute_path(AIRDCCORE_LIBRARY FILE)
foreach(required_header IN ITEMS airdcpp/stdinc.h airdcpp/core/version.h)
  set(header_path "${AIRDCCORE_INCLUDE_DIR}/${required_header}")
  if(NOT EXISTS "${header_path}" OR IS_DIRECTORY "${header_path}" OR IS_SYMLINK "${header_path}")
    message(FATAL_ERROR "staged ${required_header} is required as a regular non-symlinked file")
  endif()
endforeach()

if(NOT "${CMAKE_OSX_ARCHITECTURES}" STREQUAL "arm64")
  message(FATAL_ERROR "CMAKE_OSX_ARCHITECTURES must be exactly arm64; got ${CMAKE_OSX_ARCHITECTURES}")
endif()
if(NOT "${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "14.0")
  message(FATAL_ERROR "CMAKE_OSX_DEPLOYMENT_TARGET must be 14.0; got ${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif()
if(NOT "${CMAKE_BUILD_TYPE}" STREQUAL "Release")
  message(FATAL_ERROR "CMAKE_BUILD_TYPE must be Release; got ${CMAKE_BUILD_TYPE}")
endif()
if(NOT "${CMAKE_CXX_STANDARD}" STREQUAL "20")
  message(FATAL_ERROR "CMAKE_CXX_STANDARD must be 20; got ${CMAKE_CXX_STANDARD}")
endif()
if(NOT "${CMAKE_CXX_EXTENSIONS}" STREQUAL "OFF")
  message(FATAL_ERROR "CMAKE_CXX_EXTENSIONS must be OFF; got ${CMAKE_CXX_EXTENSIONS}")
endif()

add_library(AirDCCore::Core STATIC IMPORTED GLOBAL)
set_target_properties(AirDCCore::Core PROPERTIES
  IMPORTED_LOCATION "${AIRDCCORE_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${AIRDCCORE_INCLUDE_DIR}")

add_executable(airdcpp-smoke main.cpp)
target_compile_features(airdcpp-smoke PRIVATE cxx_std_20)
set_target_properties(airdcpp-smoke PROPERTIES CXX_EXTENSIONS OFF)
target_link_libraries(airdcpp-smoke PRIVATE AirDCCore::Core)
target_link_options(airdcpp-smoke PRIVATE
  "LINKER:-force_load,$<TARGET_FILE:AirDCCore::Core>")

if(NOT "${AIRDCCORE_TEST_LINK_ITEMS}" STREQUAL "fixture")
  require_absolute_path(AIRDCCORE_MODULE_DIR DIRECTORY)
  list(PREPEND CMAKE_MODULE_PATH "${AIRDCCORE_MODULE_DIR}")

  find_package(BZip2 REQUIRED)
  find_package(ZLIB REQUIRED)
  find_package(OpenSSL REQUIRED)
  find_package(miniupnpc REQUIRED)
  find_package(leveldb REQUIRED)
  find_package(maxminddb REQUIRED)
  find_package(Boost 1.70.0 CONFIG COMPONENTS regex thread REQUIRED)
  find_package(Snappy REQUIRED)
  find_package(Threads REQUIRED)

  include(AirDCCoreLinkAdapters)
  airdcpp_adapt_leveldb_snappy()
  airdcpp_define_system_iconv("${AIRDCCORE_SYSTEM_ICONV_LIBRARY}")

  set(candidate_link_items
    "BZip2|BZip2::BZip2"
    "ZLIB|ZLIB::ZLIB"
    "OpenSSLSSL|OpenSSL::SSL"
    "OpenSSLCrypto|OpenSSL::Crypto"
    "miniupnpc|miniupnpc::miniupnpc"
    "leveldb|leveldb::leveldb"
    "maxminddb|maxminddb::maxminddb"
    "BoostThread|Boost::thread"
    "BoostRegex|Boost::regex"
    "Snappy|Snappy::snappy"
    "Threads|Threads::Threads"
    "Iconv|AirDCCore::SystemIconv")

  set(all_logical_items)
  foreach(candidate IN LISTS candidate_link_items)
    string(REPLACE "|" ";" candidate_parts "${candidate}")
    list(GET candidate_parts 0 logical_name)
    list(GET candidate_parts 1 target_name)
    list(APPEND all_logical_items "${logical_name}")
    target_include_directories(airdcpp-smoke PRIVATE
      "$<TARGET_PROPERTY:${target_name},INTERFACE_INCLUDE_DIRECTORIES>")
  endforeach()

  if(NOT DEFINED AIRDCCORE_TEST_LINK_ITEMS OR "${AIRDCCORE_TEST_LINK_ITEMS}" STREQUAL "" OR "${AIRDCCORE_TEST_LINK_ITEMS}" STREQUAL "all")
    set(requested_logical_items ${all_logical_items})
  elseif("${AIRDCCORE_TEST_LINK_ITEMS}" STREQUAL "none")
    set(requested_logical_items)
  else()
    string(REPLACE "," ";" requested_logical_items "${AIRDCCORE_TEST_LINK_ITEMS}")
    foreach(requested IN LISTS requested_logical_items)
      if(NOT requested IN_LIST all_logical_items)
        message(FATAL_ERROR "unknown AIRDCCORE_TEST_LINK_ITEMS entry: ${requested}")
      endif()
    endforeach()
  endif()

  foreach(candidate IN LISTS candidate_link_items)
    string(REPLACE "|" ";" candidate_parts "${candidate}")
    list(GET candidate_parts 0 logical_name)
    list(GET candidate_parts 1 target_name)
    if(logical_name IN_LIST requested_logical_items AND NOT "${AIRDCCORE_OMIT_LINK_ITEM}" STREQUAL "${logical_name}")
      target_link_libraries(airdcpp-smoke PRIVATE "${target_name}")
    endif()
  endforeach()
endif()
