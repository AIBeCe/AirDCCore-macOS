find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(PC_MAXMINDDB QUIET libmaxminddb)
endif()

find_path(maxminddb_INCLUDE_DIR
  NAMES maxminddb.h
  HINTS ${PC_MAXMINDDB_INCLUDE_DIRS})
find_library(maxminddb_LIBRARY
  NAMES maxminddb
  HINTS ${PC_MAXMINDDB_LIBRARY_DIRS})

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(maxminddb
  REQUIRED_VARS maxminddb_INCLUDE_DIR maxminddb_LIBRARY
  VERSION_VAR PC_MAXMINDDB_VERSION)

if(maxminddb_FOUND AND NOT TARGET maxminddb::maxminddb)
  add_library(maxminddb::maxminddb UNKNOWN IMPORTED)
  set_target_properties(maxminddb::maxminddb PROPERTIES
    IMPORTED_LOCATION "${maxminddb_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${maxminddb_INCLUDE_DIR}")
endif()

mark_as_advanced(maxminddb_INCLUDE_DIR maxminddb_LIBRARY)
