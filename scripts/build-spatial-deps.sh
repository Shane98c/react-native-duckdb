#!/bin/bash
set -euo pipefail

# Build duckdb-spatial's native dependencies (GDAL, PROJ, GEOS, expat, sqlite3,
# tiff, libgeotiff, json-c, zlib) as static libraries for iOS/Android via vcpkg.
#
# Usage: build-spatial-deps.sh <platform> <arch>
#   ios     arm64 | simulator-arm64
#   android arm64-v8a | x86_64
#
# Android requires ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) in the environment.
#
# Output: vendor/spatial/<platform>-<arch>/prefix/{include,lib,share}
# The prefix dir is passed to the DuckDB build as CMAKE_PREFIX_PATH so
# duckdb-spatial's find_package(GDAL/PROJ/GEOS/...) calls resolve.

PLATFORM="${1:?usage: build-spatial-deps.sh <ios|android> <arch>}"
ARCH="${2:?usage: build-spatial-deps.sh <ios|android> <arch>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$REPO_DIR/vendor"

# Pinned duckdb-spatial commit — must match OUT_OF_TREE_EXTENSIONS.spatial in
# configure-extensions.js. The vcpkg overlay ports (gdal/proj/geos/sqlite3)
# come from this checkout so dependency versions match what duckdb-spatial
# itself tests.
SPATIAL_COMMIT="f129b24b4ddd4d98cfc18f88be5a344a79040e7b"
# vcpkg pinned to the builtin-baseline from duckdb-spatial's vcpkg.json at
# that commit, so non-overlay ports (tiff, json-c, libgeotiff, expat, zlib)
# resolve to the same versions duckdb-spatial builds with.
VCPKG_COMMIT="ce613c41372b23b1f51333815feb3edd87ef8a8b"

# Dependencies to install. Mirrors duckdb-spatial's vcpkg.json for mobile
# targets (no curl/openssl/network), EXCEPT sqlite3: its feature set must be
# a superset of the SQLite bundled by sqlite_scanner (FTS3/4/5 + JSON),
# because when both extensions are linked the build dedups the two copies
# down to this one — see build-duckdb-ios.sh (iOS) and
# package/android/CMakeLists.txt (Android).
SPATIAL_DEPS=(zlib expat "sqlite3[core,rtree,fts3,fts4,fts5,json1]" geos "proj[core]" "gdal[core,geos]")

case "$PLATFORM-$ARCH" in
  ios-arm64)           TRIPLET="arm64-ios-rn" ;;
  ios-simulator-arm64) TRIPLET="arm64-iossim-rn" ;;
  android-arm64-v8a)   TRIPLET="arm64-android-rn" ;;
  android-x86_64)      TRIPLET="x64-android-rn" ;;
  *)
    echo "ERROR: spatial is not supported on $PLATFORM/$ARCH (64-bit only)" >&2
    exit 1
    ;;
esac

OUT_DIR="$VENDOR_DIR/spatial/$PLATFORM-$ARCH"
TRIPLET_HASH="$(cat "$SCRIPT_DIR/vcpkg-triplets/$TRIPLET.cmake" "$SCRIPT_DIR/vcpkg-spatial-deps-options.cmake" | cksum | cut -d' ' -f1)"
DEPS_HASH="$(printf '%s' "${SPATIAL_DEPS[*]}" | cksum | cut -d' ' -f1)"
STAMP="$SPATIAL_COMMIT:$VCPKG_COMMIT:$TRIPLET:$TRIPLET_HASH:$DEPS_HASH"
if [ -f "$OUT_DIR/.complete" ] && [ "$(cat "$OUT_DIR/.complete")" = "$STAMP" ]; then
  echo "spatial deps up-to-date for $PLATFORM-$ARCH"
  exit 0
fi

if [ "$PLATFORM" = "android" ]; then
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [ -z "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: ANDROID_NDK_HOME or ANDROID_NDK_ROOT must be set to build spatial deps for Android" >&2
    exit 1
  fi
fi

mkdir -p "$VENDOR_DIR"

# --- vcpkg checkout (pinned) ---
VCPKG_DIR="$VENDOR_DIR/vcpkg"
if [ ! -d "$VCPKG_DIR/.git" ]; then
  echo "--- Cloning vcpkg ---"
  git clone --quiet https://github.com/microsoft/vcpkg "$VCPKG_DIR"
fi
if [ "$(git -C "$VCPKG_DIR" rev-parse HEAD)" != "$VCPKG_COMMIT" ]; then
  git -C "$VCPKG_DIR" fetch --quiet origin "$VCPKG_COMMIT" || git -C "$VCPKG_DIR" fetch --quiet origin
  git -C "$VCPKG_DIR" checkout --quiet "$VCPKG_COMMIT"
  rm -f "$VCPKG_DIR/vcpkg" # force re-bootstrap for the new checkout
fi
if [ ! -x "$VCPKG_DIR/vcpkg" ]; then
  echo "--- Bootstrapping vcpkg ---"
  "$VCPKG_DIR/bootstrap-vcpkg.sh" -disableMetrics
fi

# --- duckdb-spatial overlay ports (sparse checkout: vcpkg_ports only) ---
PORTS_DIR="$VENDOR_DIR/duckdb-spatial-ports"
if [ ! -d "$PORTS_DIR/.git" ]; then
  echo "--- Cloning duckdb-spatial (sparse, vcpkg_ports only) ---"
  git clone --quiet --filter=blob:none --no-checkout https://github.com/duckdb/duckdb-spatial "$PORTS_DIR"
  git -C "$PORTS_DIR" sparse-checkout set vcpkg_ports
fi
if [ "$(git -C "$PORTS_DIR" rev-parse HEAD 2>/dev/null)" != "$SPATIAL_COMMIT" ]; then
  git -C "$PORTS_DIR" fetch --quiet origin "$SPATIAL_COMMIT" || git -C "$PORTS_DIR" fetch --quiet origin
  git -C "$PORTS_DIR" checkout --quiet "$SPATIAL_COMMIT"
fi

# --- Install dependencies ---
# duckdb-spatial's own vcpkg.json excludes curl on ios/android via platform
# guards (openssl is only needed for network functionality), so gdal is built
# without its network feature here. The DuckDB build sets
# SPATIAL_USE_NETWORK=OFF to match.
echo "--- Building spatial deps for $TRIPLET (this builds GDAL — first run takes a while) ---"
rm -rf "$OUT_DIR"
(cd "$VCPKG_DIR" && ./vcpkg install \
  "${SPATIAL_DEPS[@]}" \
  --triplet "$TRIPLET" \
  --overlay-ports="$PORTS_DIR/vcpkg_ports" \
  --overlay-triplets="$SCRIPT_DIR/vcpkg-triplets" \
  --x-install-root="$OUT_DIR" \
  --clean-buildtrees-after-build)

# Flatten the triplet dir to a stable name so consumers don't need to know it
mv "$OUT_DIR/$TRIPLET" "$OUT_DIR/prefix"
echo "$STAMP" > "$OUT_DIR/.complete"
echo "=== spatial deps installed: $OUT_DIR/prefix ==="
