#!/bin/bash
set -euo pipefail

# Build DuckDB static libraries for iOS (device + simulator)
# and create a combined xcframework.
# Called from RNDuckDB.podspec prepare_command.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DUCKDB_DIR="${REPO_DIR}/duckdb"
BUILD_DIR="${DUCKDB_DIR}/build-ios"
JOBS="$(sysctl -n hw.ncpu)"
MIN_IOS="${1:-15.1}"

echo "=== react-native-duckdb: Building DuckDB for iOS (min=${MIN_IOS}, jobs=${JOBS}) ==="

# Step 1: Configure extensions
echo "--- Configuring extensions ---"

# Try to read extensions from Podfile.properties.json (Expo managed workflow).
# RNDUCKDB_APP_IOS_DIR (the app's Podfile directory, passed by the podspec) is
# checked first: the REPO_DIR-relative probes assume the package sits inside
# the app tree, which is false for a file:/sibling checkout — node_modules
# symlinks resolve to the physical package dir, so relative paths can't reach
# the app from here.
EXTENSIONS_FROM_PROPS=""
for CANDIDATE in "${RNDUCKDB_APP_IOS_DIR:+${RNDUCKDB_APP_IOS_DIR}/Podfile.properties.json}" "${REPO_DIR}/../ios/Podfile.properties.json" "${REPO_DIR}/../../ios/Podfile.properties.json"; do
  if [ -f "$CANDIDATE" ]; then
    EXTENSIONS_FROM_PROPS=$(node -e "
      const p = JSON.parse(require('fs').readFileSync('$CANDIDATE', 'utf8'));
      if (p['react-native-duckdb.extensions']) process.stdout.write(p['react-native-duckdb.extensions']);
    " 2>/dev/null || true)
    break
  fi
done

if [ -n "$EXTENSIONS_FROM_PROPS" ]; then
  node "${SCRIPT_DIR}/configure-extensions.js" --duckdb-path "${DUCKDB_DIR}" --extensions "${EXTENSIONS_FROM_PROPS}"
elif [ -n "${RNDUCKDB_APP_IOS_DIR:-}" ]; then
  # Bare workflow: anchor package.json discovery at the app, not at cwd
  # (during prepare_command, cwd is inside the package checkout)
  node "${SCRIPT_DIR}/configure-extensions.js" --duckdb-path "${DUCKDB_DIR}" --app-root "${RNDUCKDB_APP_IOS_DIR}/.."
else
  node "${SCRIPT_DIR}/configure-extensions.js" --duckdb-path "${DUCKDB_DIR}"
fi

# Check if httpfs is in the generated extension config (needs OpenSSL + libcurl)
NEEDS_HTTPFS=false
EXT_CONFIG="${DUCKDB_DIR}/extension/extension_config_local.cmake"
if [ -f "$EXT_CONFIG" ] && grep -q "httpfs" "$EXT_CONFIG"; then
  NEEDS_HTTPFS=true
  echo "--- httpfs detected: will build OpenSSL + libcurl for each target ---"
fi

# Check if spatial is in the extension config (needs GDAL/PROJ/GEOS via vcpkg)
NEEDS_SPATIAL=false
if [ -f "$EXT_CONFIG" ] && grep -q "duckdb_extension_load(spatial" "$EXT_CONFIG"; then
  NEEDS_SPATIAL=true
  echo "--- spatial detected: will build GDAL/PROJ/GEOS for each target ---"
fi

# Invalidate cached builds if extension config changed
EXT_CONFIG_HASH=$(md5 -q "${EXT_CONFIG}" 2>/dev/null || md5sum "${EXT_CONFIG}" 2>/dev/null | cut -d' ' -f1 || echo "none")
for BUILD_SUBDIR in "build-ios-iphoneos-arm64" "build-ios-iphonesimulator-arm64"; do
  CACHED_HASH_FILE="${DUCKDB_DIR}/${BUILD_SUBDIR}/.extension_config_hash"
  if [ -d "${DUCKDB_DIR}/${BUILD_SUBDIR}" ]; then
    if [ ! -f "$CACHED_HASH_FILE" ] || [ "$(cat "$CACHED_HASH_FILE")" != "$EXT_CONFIG_HASH" ]; then
      echo "--- Extension config changed, cleaning ${BUILD_SUBDIR} ---"
      rm -rf "${DUCKDB_DIR}/${BUILD_SUBDIR}"
    fi
  fi
done

# Shared cmake flags
CMAKE_COMMON=(
  -DBUILD_SHELL=OFF
  -DBUILD_UNITTESTS=OFF
  -DBUILD_BENCHMARKS=OFF
  -DENABLE_SANITIZER=OFF
  -DENABLE_UBSAN=OFF
  -DEXTENSION_STATIC_BUILD=OFF
  -DBUILD_EXTENSIONS_ONLY=OFF
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_CXX_STANDARD=20
  -DBUILD_SHARED_LIBS=OFF
)

build_arch() {
  local PLATFORM="$1"   # iphoneos | iphonesimulator
  local ARCH="$2"       # arm64 | x86_64
  local BUILD_SUBDIR="build-ios-${PLATFORM}-${ARCH}"
  local FULL_BUILD_DIR="${DUCKDB_DIR}/${BUILD_SUBDIR}"

  echo "--- Building DuckDB for ${PLATFORM} (${ARCH}) ---"

  # Map platform+arch to vendor directory name for OpenSSL/curl
  local MAPPED_ARCH=""
  if [ "$PLATFORM" = "iphoneos" ]; then
    MAPPED_ARCH="${ARCH}"
  elif [ "$PLATFORM" = "iphonesimulator" ]; then
    MAPPED_ARCH="simulator-${ARCH}"
  fi

  # Build OpenSSL + libcurl if httpfs is enabled
  local HTTPFS_CMAKE_FLAGS=()
  if [ "$NEEDS_HTTPFS" = true ]; then
    echo "   Building OpenSSL + libcurl for ios-${MAPPED_ARCH}..."
    "${SCRIPT_DIR}/build-openssl-curl.sh" ios "${MAPPED_ARCH}"
    HTTPFS_CMAKE_FLAGS=(
      -DOPENSSL_ROOT_DIR="${REPO_DIR}/vendor/openssl/ios-${MAPPED_ARCH}"
      -DOPENSSL_INCLUDE_DIR="${REPO_DIR}/vendor/openssl/ios-${MAPPED_ARCH}/include"
      -DOPENSSL_SSL_LIBRARY="${REPO_DIR}/vendor/openssl/ios-${MAPPED_ARCH}/lib/libssl.a"
      -DOPENSSL_CRYPTO_LIBRARY="${REPO_DIR}/vendor/openssl/ios-${MAPPED_ARCH}/lib/libcrypto.a"
      -DOPENSSL_USE_STATIC_LIBS=TRUE
      -DCURL_ROOT="${REPO_DIR}/vendor/curl/ios-${MAPPED_ARCH}"
      -DCURL_INCLUDE_DIR="${REPO_DIR}/vendor/curl/ios-${MAPPED_ARCH}/include"
      -DCURL_LIBRARY="${REPO_DIR}/vendor/curl/ios-${MAPPED_ARCH}/lib/libcurl.a"
    )
  fi

  # Build GDAL/PROJ/GEOS etc. if spatial is enabled
  local SPATIAL_CMAKE_FLAGS=()
  if [ "$NEEDS_SPATIAL" = true ]; then
    echo "   Building spatial deps (GDAL/PROJ/GEOS) for ios-${MAPPED_ARCH}..."
    "${SCRIPT_DIR}/build-spatial-deps.sh" ios "${MAPPED_ARCH}"
    local SPATIAL_PREFIX="${REPO_DIR}/vendor/spatial/ios-${MAPPED_ARCH}/prefix"
    # CMAKE_PREFIX_PATH lets duckdb-spatial's find_package(GDAL/PROJ/GEOS/...)
    # resolve to the vcpkg-built static libs. Network functionality is off on
    # mobile (matches upstream's vcpkg.json platform guards — no curl/openssl).
    # CMAKE_SYSTEM_PROCESSOR must match what vcpkg used (aarch64, not arm64):
    # PROJ's config-version check rejects the package on any mismatch.
    local VCPKG_PROCESSOR="${ARCH}"
    if [ "${ARCH}" = "arm64" ]; then
      VCPKG_PROCESSOR="aarch64"
    fi
    SPATIAL_CMAKE_FLAGS=(
      -DCMAKE_PREFIX_PATH="${SPATIAL_PREFIX}"
      -DCMAKE_FIND_ROOT_PATH="${SPATIAL_PREFIX}"
      -DCMAKE_SYSTEM_PROCESSOR="${VCPKG_PROCESSOR}"
      -DSPATIAL_USE_NETWORK=OFF
    )
  fi

  local SDK_PATH
  SDK_PATH="$(xcrun --sdk "${PLATFORM}" --show-sdk-path)"

  cmake -S "${DUCKDB_DIR}" -B "${FULL_BUILD_DIR}" -G "Unix Makefiles" \
    "${CMAKE_COMMON[@]}" \
    ${HTTPFS_CMAKE_FLAGS[@]+"${HTTPFS_CMAKE_FLAGS[@]}"} \
    ${SPATIAL_CMAKE_FLAGS[@]+"${SPATIAL_CMAKE_FLAGS[@]}"} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_IOS}" \
    -DDUCKDB_EXPLICIT_PLATFORM="ios_${ARCH}" \
    2>&1 | tail -5

  cmake --build "${FULL_BUILD_DIR}" --config Release --target duckdb_static -j"${JOBS}" 2>&1 | tail -3

  # Combine all .a files into one per architecture
  local COMBINED="${FULL_BUILD_DIR}/libduckdb_combined.a"
  local ALL_LIBS=()

  # Find all .a files produced by the build
  while IFS= read -r -d '' lib; do
    case "$lib" in
      *_nosqlite3.a) continue ;;         # stale stripped copy from a previous run
      *libduckdb_combined.a) continue ;; # our own output from a previous run
    esac
    if [ "$NEEDS_SPATIAL" = true ] && [ "$(basename "$lib")" = "libsqlite_scanner_extension.a" ]; then
      # sqlite_scanner vendors its own sqlite3, which collides with the
      # vcpkg-built sqlite3 that GDAL/PROJ link against. The vcpkg copy is
      # built as a feature superset (see build-spatial-deps.sh), so strip the
      # vendored copy and let everything resolve against the vcpkg one.
      local stripped="${lib%.a}_nosqlite3.a"
      cp -f "$lib" "$stripped"
      ar d "$stripped" sqlite3.c.o
      lib="$stripped"
    fi
    ALL_LIBS+=("${lib}")
  done < <(find "${FULL_BUILD_DIR}" -name "*.a" -print0)

  # Include vendor OpenSSL + libcurl static libs when httpfs is enabled
  if [ "$NEEDS_HTTPFS" = true ]; then
    local VENDOR_SSL="${REPO_DIR}/vendor/openssl/ios-${MAPPED_ARCH}/lib"
    local VENDOR_CURL="${REPO_DIR}/vendor/curl/ios-${MAPPED_ARCH}/lib"
    for vendor_lib in "${VENDOR_SSL}/libssl.a" "${VENDOR_SSL}/libcrypto.a" "${VENDOR_CURL}/libcurl.a"; do
      if [ -f "$vendor_lib" ]; then
        ALL_LIBS+=("${vendor_lib}")
      else
        echo "WARNING: Expected vendor lib not found: ${vendor_lib}"
      fi
    done
  fi

  # Include vcpkg-built GDAL/PROJ/GEOS etc. static libs when spatial is enabled
  if [ "$NEEDS_SPATIAL" = true ]; then
    local SPATIAL_LIB_DIR="${REPO_DIR}/vendor/spatial/ios-${MAPPED_ARCH}/prefix/lib"
    while IFS= read -r -d '' lib; do
      ALL_LIBS+=("${lib}")
    done < <(find "${SPATIAL_LIB_DIR}" -name "*.a" -print0)
  fi

  if [ ${#ALL_LIBS[@]} -eq 0 ]; then
    echo "ERROR: No .a files found in ${FULL_BUILD_DIR}"
    exit 1
  fi

  echo "   Combining ${#ALL_LIBS[@]} static libraries..."
  libtool -static -o "${COMBINED}" "${ALL_LIBS[@]}" 2>/dev/null
  echo "   Combined: ${COMBINED} ($(du -h "${COMBINED}" | cut -f1))"

  # Save extension config hash for cache invalidation
  echo "$EXT_CONFIG_HASH" > "${FULL_BUILD_DIR}/.extension_config_hash"
}

# Step 2: Build for device and simulator
build_arch "iphoneos" "arm64"
build_arch "iphonesimulator" "arm64"

# Step 3: Create xcframework
echo "--- Creating DuckDB.xcframework ---"
rm -rf "${BUILD_DIR}/DuckDB.xcframework"
mkdir -p "${BUILD_DIR}"

xcodebuild -create-xcframework \
  -library "${DUCKDB_DIR}/build-ios-iphoneos-arm64/libduckdb_combined.a" \
  -headers "${DUCKDB_DIR}/src/include" \
  -library "${DUCKDB_DIR}/build-ios-iphonesimulator-arm64/libduckdb_combined.a" \
  -headers "${DUCKDB_DIR}/src/include" \
  -output "${BUILD_DIR}/DuckDB.xcframework" \
  2>&1 | tail -3

# Step 4: Copy xcframework into package/ so CocoaPods can find it
# vendored_frameworks paths must be within the pod source tree
PACKAGE_DIR="${REPO_DIR}/package"
rm -rf "${PACKAGE_DIR}/DuckDB.xcframework"
cp -R "${BUILD_DIR}/DuckDB.xcframework" "${PACKAGE_DIR}/DuckDB.xcframework"

# Step 5: Write extension metadata for podspec to read
EXT_META="${PACKAGE_DIR}/.duckdb-extensions.json"
printf '{"httpfs":%s,"spatial":%s}\n' "$NEEDS_HTTPFS" "$NEEDS_SPATIAL" > "$EXT_META"

echo "=== DuckDB.xcframework created at ${PACKAGE_DIR}/DuckDB.xcframework ==="
