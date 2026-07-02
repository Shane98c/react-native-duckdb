# Shared settings for react-native-duckdb spatial dependency triplets
# (included by scripts/vcpkg-triplets/*-rn.cmake).

# Compile every dependency with one section per function/data item so the
# final mobile link can drop unreferenced code with --gc-sections (Android;
# iOS dead-strips natively at app link).
set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -ffunction-sections -fdata-sections")
set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -ffunction-sections -fdata-sections")

# sqlite_scanner's bundled SQLite is compiled with FTS3 parenthesis syntax
# (extended AND/OR/NOT query operators for fts3/fts4 MATCH). The vcpkg port
# has no feature flag for it, so inject the define directly — the mobile link
# replaces the scanner's SQLite with this one, so behavior must match.
if(PORT STREQUAL "sqlite3")
  set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -DSQLITE_ENABLE_FTS3_PARENTHESIS")
  set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -DSQLITE_ENABLE_FTS3_PARENTHESIS")
endif()

# Trim GDAL's niche vector drivers for mobile. Upstream's port is already
# vector-only (rasters/network off) but enables ~40 OGR drivers; registered
# drivers can't be dead-stripped, so disabling them here is a real size win.
# Kept: GeoJSON (+GeoJSONSeq/ESRIJSON/TopoJSON), Shapefile, GeoPackage,
# FlatGeobuf, CSV, GPX, KML, GML, SQLite, OpenFileGDB, VRT, MEM.
# These come after the port's own options, so OFF here wins.
if(PORT STREQUAL "gdal")
  list(APPEND VCPKG_CMAKE_CONFIGURE_OPTIONS
    -DOGR_ENABLE_DRIVER_TAB=OFF
    -DOGR_ENABLE_DRIVER_AVC=OFF
    -DOGR_ENABLE_DRIVER_NTF=OFF
    -DOGR_ENABLE_DRIVER_LVBAG=OFF
    -DOGR_ENABLE_DRIVER_S57=OFF
    -DOGR_ENABLE_DRIVER_DGN=OFF
    -DOGR_ENABLE_DRIVER_GMT=OFF
    -DOGR_ENABLE_DRIVER_TIGER=OFF
    -DOGR_ENABLE_DRIVER_GEOCONCEPT=OFF
    -DOGR_ENABLE_DRIVER_GEORSS=OFF
    -DOGR_ENABLE_DRIVER_DXF=OFF
    -DOGR_ENABLE_DRIVER_PGDUMP=OFF
    -DOGR_ENABLE_DRIVER_GPSBABEL=OFF
    -DOGR_ENABLE_DRIVER_EDIGEO=OFF
    -DOGR_ENABLE_DRIVER_SXF=OFF
    -DOGR_ENABLE_DRIVER_WASP=OFF
    -DOGR_ENABLE_DRIVER_SELAFIN=OFF
    -DOGR_ENABLE_DRIVER_JML=OFF
    -DOGR_ENABLE_DRIVER_VDV=OFF
    -DOGR_ENABLE_DRIVER_MAPML=OFF
    -DOGR_ENABLE_DRIVER_SVG=OFF
    -DOGR_ENABLE_DRIVER_XLSX=OFF
    -DOGR_ENABLE_DRIVER_CAD=OFF
    -DOGR_ENABLE_DRIVER_ODS=OFF
    -DOGR_ENABLE_DRIVER_OSM=OFF
  )
endif()
