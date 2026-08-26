set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_PROVIDED_FORTRAN ON)
# A cross build needs two toolchain environments at once, but a variable
# passed through carries one value to every triplet. LIB is the one that
# genuinely differs between host and target, and it is also the one this
# triplet can do without: the chainloaded toolchain puts the arm64 library
# directories straight into the linker flags. So leave LIB to the host
# ports -- forcing the arm64 value on them made meson report that the x64
# cl.exe "cannot compile programs" -- and pass INCLUDE through, which the
# MSVC and Windows SDK headers share across architectures. Ports reach for
# it directly: libpng preprocesses pnglibconf.c with a bare cl.exe -E from
# a CMake script, and without INCLUDE that failed on stdint.h.
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED INCLUDE WindowsSdkDir WindowsSDKVersion)
get_filename_component(_snow_repo_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE
    "${_snow_repo_root}/cmake/vcpkg-msvc-145-14.51-toolchain.cmake")
unset(_snow_repo_root)
