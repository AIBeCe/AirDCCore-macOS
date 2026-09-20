cmake_minimum_required(VERSION 3.25)
project(AirDCCoreConfigureFixture LANGUAGES C CXX)

CHECK_FUNCTION_EXISTS(malloc FIXTURE_HAVE_MALLOC)
CHECK_INCLUDE_FILES("stddef.h" FIXTURE_HAVE_STDDEF_H)

foreach(parent_variable IN ITEMS
    VERSION
    TAG_APPLICATION
    APPLICATION_ID
    RESOURCE_DIRECTORY
    GLOBAL_CONFIG_DIRECTORY
    PROJECT_NAME_GLOBAL)
  if("${${parent_variable}}" STREQUAL "")
    message(FATAL_ERROR "${parent_variable} must be supplied by the parent wrapper")
  endif()
endforeach()

set(FIXTURE_EXPECTED_DEPLOYMENT_TARGET 14.0 CACHE STRING "Fixture deployment expectation")
set(FIXTURE_EXPECTED_NATPMP OFF CACHE BOOL "Fixture NAT-PMP expectation")
set(FIXTURE_EXPECTED_TBB OFF CACHE BOOL "Fixture TBB expectation")

function(fixture_require_value name actual expected)
  if(NOT "${actual}" STREQUAL "${expected}")
    message(FATAL_ERROR "fixture expected ${name}=${expected}; got ${actual}")
  endif()
endfunction()

fixture_require_value(CMAKE_BUILD_TYPE "${CMAKE_BUILD_TYPE}" Release)
fixture_require_value(BUILD_SHARED_LIBS "${BUILD_SHARED_LIBS}" OFF)
fixture_require_value(CMAKE_CXX_STANDARD "${CMAKE_CXX_STANDARD}" 20)
fixture_require_value(CMAKE_CXX_EXTENSIONS "${CMAKE_CXX_EXTENSIONS}" OFF)
fixture_require_value(CMAKE_OSX_ARCHITECTURES "${CMAKE_OSX_ARCHITECTURES}" arm64)
fixture_require_value(
  CMAKE_OSX_DEPLOYMENT_TARGET
  "${CMAKE_OSX_DEPLOYMENT_TARGET}"
  "${FIXTURE_EXPECTED_DEPLOYMENT_TARGET}")
fixture_require_value(ENABLE_NATPMP "${ENABLE_NATPMP}" "${FIXTURE_EXPECTED_NATPMP}")
fixture_require_value(ENABLE_TBB "${ENABLE_TBB}" "${FIXTURE_EXPECTED_TBB}")

# Exercise child-directory package discovery without a manually GLOBAL import.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/packages/BZip2Config.cmake" [=[
add_library(BZip2::BZip2 STATIC IMPORTED)
set_target_properties(BZip2::BZip2 PROPERTIES
  IMPORTED_LOCATION_RELEASE /fixture/lib/libbz2-release.a
  IMPORTED_CONFIGURATIONS RELEASE
  INTERFACE_INCLUDE_DIRECTORIES /fixture/include
  INTERFACE_LINK_LIBRARIES fixture_dependency)
]=])
find_package(BZip2 REQUIRED CONFIG
  PATHS "${CMAKE_CURRENT_BINARY_DIR}/packages" NO_DEFAULT_PATH)

add_library(airdcpp INTERFACE)
