set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_PROVIDED_FORTRAN ON)
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED PATH INCLUDE LIB WindowsSdkDir WindowsSDKVersion)
get_filename_component(_snow_repo_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE
    "${_snow_repo_root}/cmake/vcpkg-msvc-145-14.51-toolchain.cmake")
unset(_snow_repo_root)
