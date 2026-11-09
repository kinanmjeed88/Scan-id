# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(scan_id LANGUAGES CXX)

include(CTest)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "scan_id")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
# Pinned, reviewed PDFium and ONNX Runtime Windows x64 archives. Pre-fetching
# with bounded retries and SHA-256 verification avoids fragile single-shot
# downloads inside generated plugin CMake scripts.
set(PDFIUM_VERSION "8086" CACHE STRING "PDFium revision" FORCE)
set(ONNXRUNTIME_VERSION "1.28.3")

function(scan_id_fetch_verified_archive URL DESTINATION EXPECTED_SHA256)
  if(EXISTS "${DESTINATION}")
    file(SHA256 "${DESTINATION}" existing_sha256)
    if(existing_sha256 STREQUAL "${EXPECTED_SHA256}")
      message(STATUS "Verified cached archive: ${DESTINATION}")
      return()
    endif()
    file(REMOVE "${DESTINATION}")
  endif()

  get_filename_component(dest_dir "${DESTINATION}" DIRECTORY)
  file(MAKE_DIRECTORY "${dest_dir}")

  foreach(attempt 1 2 3 4 5)
    set(tmp_file "${DESTINATION}.part")
    file(REMOVE "${tmp_file}")
    message(STATUS "Fetching ${URL} (attempt ${attempt}/5)")
    file(
      DOWNLOAD "${URL}" "${tmp_file}"
      STATUS dl_status
      TLS_VERIFY ON
      INACTIVITY_TIMEOUT 60
      TIMEOUT 300
    )
    list(GET dl_status 0 dl_code)
    list(GET dl_status 1 dl_message)
    if(dl_code EQUAL 0 AND EXISTS "${tmp_file}")
      file(SHA256 "${tmp_file}" downloaded_sha256)
      if(downloaded_sha256 STREQUAL "${EXPECTED_SHA256}")
        file(RENAME "${tmp_file}" "${DESTINATION}")
        message(STATUS "Verified downloaded archive: ${DESTINATION} (${downloaded_sha256})")
        return()
      endif()
      message(WARNING "SHA256 mismatch for ${URL} on attempt ${attempt}: got ${downloaded_sha256}, expected ${EXPECTED_SHA256}")
    else()
      message(WARNING "Download failed for ${URL} on attempt ${attempt}: [${dl_code}] ${dl_message}")
    endif()
    file(REMOVE "${tmp_file}")
    if(attempt LESS 5)
      execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 5)
    endif()
  endforeach()

  message(FATAL_ERROR "Failed to fetch and verify ${URL} after 5 attempts")
endfunction()

set(SCAN_ID_WINDOWS_CACHE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../.dart_tool/windows-native-cache")
set(SCAN_ID_PDFIUM_SHA256 "1fd8af952832dbb0eb16d9249f68fe09e5f5ebf7c3dd9f6066ea2720cc28487d")
set(SCAN_ID_PDFIUM_CACHE_ARCHIVE "${SCAN_ID_WINDOWS_CACHE_DIR}/pdfium-win-x64-${PDFIUM_VERSION}.tgz")
set(SCAN_ID_ORT_SHA256 "1d6fab48e85f948436af7c8c971d2c145cf224e2c444755dec894f8b0de11a83")
set(SCAN_ID_ORT_CACHE_ARCHIVE "${SCAN_ID_WINDOWS_CACHE_DIR}/onnxruntime-win-x64-${ONNXRUNTIME_VERSION}.zip")
if(NOT EXISTS "${SCAN_ID_PDFIUM_CACHE_ARCHIVE}" OR NOT EXISTS "${SCAN_ID_ORT_CACHE_ARCHIVE}")
  find_package(Python3 COMPONENTS Interpreter QUIET)
  if(Python3_Interpreter_FOUND)
    execute_process(
      COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../tool/fetch_windows_native_deps.py"
      RESULT_VARIABLE scan_id_py_fetch_rc
    )
  endif()
endif()
scan_id_fetch_verified_archive(
  "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/${PDFIUM_VERSION}/pdfium-win-x64.tgz"
  "${SCAN_ID_PDFIUM_CACHE_ARCHIVE}"
  "${SCAN_ID_PDFIUM_SHA256}"
)
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/pdfium-download")
file(COPY_FILE "${SCAN_ID_PDFIUM_CACHE_ARCHIVE}" "${CMAKE_BINARY_DIR}/pdfium-download/pdfium-win-x64.tgz")
if(NOT EXISTS "${CMAKE_BINARY_DIR}/pdfium-src/PDFiumConfig.cmake")
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/pdfium-src")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "${CMAKE_BINARY_DIR}/pdfium-download/pdfium-win-x64.tgz"
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/pdfium-src"
    RESULT_VARIABLE pdfium_extract_rc
  )
  if(NOT pdfium_extract_rc EQUAL 0 OR NOT EXISTS "${CMAKE_BINARY_DIR}/pdfium-src/PDFiumConfig.cmake")
    message(FATAL_ERROR "Failed to extract verified PDFium archive (${pdfium_extract_rc})")
  endif()
endif()
set(SCAN_ID_PRINTING_DL_CMAKE "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/printing/windows/DownloadProject.cmake")
if(EXISTS "${SCAN_ID_PRINTING_DL_CMAKE}")
  file(READ "${SCAN_ID_PRINTING_DL_CMAKE}" printing_dl_contents)
  string(FIND "${printing_dl_contents}" "SCAN_ID_PREVERIFIED_PDFIUM" printing_dl_patched)
  if(printing_dl_patched EQUAL -1)
    string(
      REPLACE
      "set(\${DL_ARGS_PROJ}_BINARY_DIR \"\${DL_ARGS_BINARY_DIR}\" PARENT_SCOPE)"
      "set(\${DL_ARGS_PROJ}_BINARY_DIR \"\${DL_ARGS_BINARY_DIR}\" PARENT_SCOPE)\n    # SCAN_ID_PREVERIFIED_PDFIUM\n    if(EXISTS \"\${DL_ARGS_SOURCE_DIR}/PDFiumConfig.cmake\")\n        message(STATUS \"Using pre-verified \${DL_ARGS_PROJ} at \${DL_ARGS_SOURCE_DIR}\")\n        return()\n    endif()"
      printing_dl_contents
      "${printing_dl_contents}"
    )
    file(WRITE "${SCAN_ID_PRINTING_DL_CMAKE}" "${printing_dl_contents}")
  endif()
endif()

set(SCAN_ID_ORT_SHA256 "1d6fab48e85f948436af7c8c971d2c145cf224e2c444755dec894f8b0de11a83")
set(SCAN_ID_ORT_CACHE_ARCHIVE "${SCAN_ID_WINDOWS_CACHE_DIR}/onnxruntime-win-x64-${ONNXRUNTIME_VERSION}.zip")
set(SCAN_ID_ORT_PLUGIN_DIR "${CMAKE_BINARY_DIR}/plugins/flutter_onnxruntime/onnxruntime")
set(SCAN_ID_ORT_EXTRACT_DIR "${SCAN_ID_ORT_PLUGIN_DIR}/onnxruntime-win-x64-${ONNXRUNTIME_VERSION}")
if(NOT EXISTS "${SCAN_ID_ORT_EXTRACT_DIR}/include/onnxruntime_cxx_api.h")
  scan_id_fetch_verified_archive(
    "https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-win-x64-${ONNXRUNTIME_VERSION}.zip"
    "${SCAN_ID_ORT_CACHE_ARCHIVE}"
    "${SCAN_ID_ORT_SHA256}"
  )
  file(MAKE_DIRECTORY "${SCAN_ID_ORT_PLUGIN_DIR}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xf "${SCAN_ID_ORT_CACHE_ARCHIVE}"
    WORKING_DIRECTORY "${SCAN_ID_ORT_PLUGIN_DIR}"
    RESULT_VARIABLE ort_extract_rc
  )
  if(NOT ort_extract_rc EQUAL 0 OR NOT EXISTS "${SCAN_ID_ORT_EXTRACT_DIR}/include/onnxruntime_cxx_api.h")
    message(FATAL_ERROR "Failed to extract verified ONNX Runtime archive (${ort_extract_rc})")
  endif()
endif()

include(flutter/generated_plugins.cmake)
# Verify the retained download before compiling/linking any of its contents.
file(GLOB_RECURSE SCAN_ID_PDFIUM_ARCHIVES "${CMAKE_BINARY_DIR}/*pdfium-win-x64.tgz")
if(NOT SCAN_ID_PDFIUM_ARCHIVES)
  message(FATAL_ERROR "Cannot verify the pinned x64 PDFium archive")
endif()
foreach(archive ${SCAN_ID_PDFIUM_ARCHIVES})
  file(SHA256 "${archive}" archive_sha256)
  if(NOT archive_sha256 STREQUAL "1fd8af952832dbb0eb16d9249f68fe09e5f5ebf7c3dd9f6066ea2720cc28487d")
    message(FATAL_ERROR "PDFium archive SHA256 mismatch")
  endif()
endforeach()



# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Ship the PDFium distribution's licensing files with portable/install bundles.
install(DIRECTORY "${CMAKE_BINARY_DIR}/pdfium-src/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/pdfium-licenses" COMPONENT Runtime
  FILES_MATCHING PATTERN "*LICENSE*" PATTERN "*license*" PATTERN "*.txt"
  PATTERN "include" EXCLUDE PATTERN "lib" EXCLUDE PATTERN "bin" EXCLUDE)
