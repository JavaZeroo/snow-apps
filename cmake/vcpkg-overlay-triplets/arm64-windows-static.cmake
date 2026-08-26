set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE static)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_PROVIDED_FORTRAN ON)
# A cross build needs two toolchain environments at once, but a variable
# passed through carries one value to every triplet, so each one here is
# either shared between host and target or has to go.
#
# LIB is the only one that genuinely differs, and it is also the only one
# this triplet can do without: the chainloaded toolchain puts the arm64
# library directories straight into the linker flags. Forcing the arm64
# value on the host ports made meson report that the x64 cl.exe "cannot
# compile programs", so LIB stays unpassed and the host keeps its own.
#
# INCLUDE and PATH are shared. The MSVC and Windows SDK headers are the same
# for either architecture, and ports reach for INCLUDE directly: libpng
# preprocesses pnglibconf.c with a bare cl.exe -E from a CMake script, which
# without it failed on stdint.h. PATH matters because vcpkg discovers host
# tools along it -- with no PATH, onnxruntime's vcpkg_find_acquire_program
# fell back to vcpkg's embeddable Python, which has no venv module. Ports
# that invoke a bare compiler prepend the detected one's own directory
# first, so the host entries on PATH do not decide the target architecture.
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED PATH INCLUDE WindowsSdkDir WindowsSDKVersion)
get_filename_component(_snow_repo_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE
    "${_snow_repo_root}/cmake/vcpkg-msvc-145-14.51-toolchain.cmake")
unset(_snow_repo_root)
