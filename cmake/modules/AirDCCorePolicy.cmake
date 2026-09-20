function(airdcpp_require_apple_clang)
  if(NOT CMAKE_C_COMPILER_ID STREQUAL "AppleClang" OR
      NOT CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
    message(FATAL_ERROR
      "Apple Clang is required; got C=${CMAKE_C_COMPILER_ID}, CXX=${CMAKE_CXX_COMPILER_ID}")
  endif()
endfunction()

function(airdcpp_require_value name actual expected)
  if(NOT "${actual}" STREQUAL "${expected}")
    message(FATAL_ERROR "${name} must be ${expected}; got ${actual}")
  endif()
endfunction()

function(airdcpp_record_target target output)
  set(target_exists FALSE)
  set(target_type "")
  set(target_imported_location "")
  set(target_imported_configurations "")
  set(target_include_directories "")
  set(target_interface_libraries "")

  if(TARGET "${target}")
    set(target_exists TRUE)
    get_target_property(target_type "${target}" TYPE)
    get_target_property(target_imported_location "${target}" IMPORTED_LOCATION)
    get_target_property(target_imported_configurations "${target}" IMPORTED_CONFIGURATIONS)
    get_target_property(target_include_directories "${target}" INTERFACE_INCLUDE_DIRECTORIES)
    get_target_property(target_interface_libraries "${target}" INTERFACE_LINK_LIBRARIES)

    foreach(property_variable IN ITEMS
        target_type
        target_imported_location
        target_imported_configurations
        target_include_directories
        target_interface_libraries)
      if("${${property_variable}}" MATCHES "-NOTFOUND$")
        set(${property_variable} "")
      endif()
    endforeach()
  endif()

  file(APPEND "${output}"
    "target.name=${target}\n"
    "target.exists=${target_exists}\n"
    "target.type=${target_type}\n"
    "target.imported_location=${target_imported_location}\n"
    "target.imported_configurations=${target_imported_configurations}\n"
    "target.include_directories=${target_include_directories}\n"
    "target.interface_libraries=${target_interface_libraries}\n")

  # Many package configs specify only configuration-specific library locations.
  set(recorded_configurations "${target_imported_configurations}")
  list(REMOVE_DUPLICATES recorded_configurations)
  list(SORT recorded_configurations)
  foreach(configuration IN LISTS recorded_configurations)
    string(TOUPPER "${configuration}" configuration)
    get_target_property(configuration_location "${target}"
      "IMPORTED_LOCATION_${configuration}")
    if("${configuration_location}" MATCHES "-NOTFOUND$")
      set(configuration_location "")
    endif()
    file(APPEND "${output}"
      "target.imported_location.${configuration}=${configuration_location}\n")
  endforeach()
endfunction()
