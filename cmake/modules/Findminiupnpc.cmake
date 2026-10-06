find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(PC_MINIUPNPC QUIET miniupnpc)
endif()

find_path(miniupnpc_INCLUDE_DIR
  NAMES miniupnpc/miniupnpc.h
  HINTS ${PC_MINIUPNPC_INCLUDE_DIRS})
find_library(miniupnpc_LIBRARY
  NAMES miniupnpc
  HINTS ${PC_MINIUPNPC_LIBRARY_DIRS})

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(miniupnpc
  REQUIRED_VARS miniupnpc_INCLUDE_DIR miniupnpc_LIBRARY
  VERSION_VAR PC_MINIUPNPC_VERSION)

if(miniupnpc_FOUND AND NOT TARGET miniupnpc::miniupnpc)
  add_library(miniupnpc::miniupnpc UNKNOWN IMPORTED)
  set_target_properties(miniupnpc::miniupnpc PROPERTIES
    IMPORTED_LOCATION "${miniupnpc_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${miniupnpc_INCLUDE_DIR}")
endif()

mark_as_advanced(miniupnpc_INCLUDE_DIR miniupnpc_LIBRARY)
