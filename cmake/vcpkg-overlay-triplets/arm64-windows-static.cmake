set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_PROVIDED_FORTRAN ON)
# Unlike the x64 triplets, this one must NOT inherit the shell's PATH,
# INCLUDE and LIB. A cross build needs two toolchain environments at once:
# host-triplet ports such as pkgconf compile with the x64 compiler and the
# x64 libraries, while these arm64 ports need the arm64 ones. Only one set
# can be passed through, and forcing the arm64 set on the host ports made
# meson report that the x64 cl.exe "cannot compile programs". Leave these
# to vcpkg, which derives the right environment per triplet; bootstrap
# still exports the host set for the host triplet to pass through.
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED WindowsSdkDir WindowsSDKVersion)
get_filename_component(_snow_repo_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE
    "${_snow_repo_root}/cmake/vcpkg-msvc-145-14.51-toolchain.cmake")
unset(_snow_repo_root)
