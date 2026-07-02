# Android arm64-v8a triplet for react-native-duckdb spatial dependencies.
# System version matches the library's minSdkVersion (24) so configure-time
# libc feature detection (e.g. aligned_alloc, API 28+) stays consistent with
# what's actually available on the oldest supported devices.
# ANDROID_ABI must be passed explicitly — vcpkg's android toolchain includes
# the NDK toolchain without setting it, and the NDK defaults to armeabi-v7a.
# Requires ANDROID_NDK_HOME in the environment.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 24)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-linux-android")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=arm64-v8a)
set(VCPKG_BUILD_TYPE release)

include("${CMAKE_CURRENT_LIST_DIR}/../vcpkg-spatial-deps-options.cmake")
