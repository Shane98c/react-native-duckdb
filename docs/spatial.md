# Geospatial (spatial)

The `spatial` extension turns DuckDB into an on-device geospatial database: a first-class `GEOMETRY` column type, 100+ `ST_*` functions backed by [GEOS](https://libgeos.org), coordinate reprojection via [PROJ](https://proj.org), and reading/writing common geospatial file formats via [GDAL](https://gdal.org) — all offline, statically linked into your app. Pair it with [`httpfs`](extensions.md#remote-queries-httpfs) and you can run spatial queries against cloud-native GeoParquet directly from object storage — no tile server, no backend.

## Setup

Add `spatial` to your extensions:

```json
{
  "react-native-duckdb": {
    "build": {
      "extensions": ["core_functions", "parquet", "spatial"]
    }
  }
}
```

Then load it at runtime:

```ts
db.executeSync("LOAD 'spatial'")
```

> **First build is slow.** The native dependencies (GDAL, PROJ, GEOS, sqlite3, expat, tiff, and friends) are cross-compiled from source via [vcpkg](https://vcpkg.io) into `vendor/spatial/` — expect 20–40 minutes per platform the first time. Subsequent builds use the cached libraries.

## The GEOMETRY Type

```ts
db.executeSync('CREATE TABLE places (name VARCHAR, geom GEOMETRY)')

// Constructors
db.executeSync("INSERT INTO places VALUES ('office', ST_Point(11.087, 47.263))")
db.executeSync(`INSERT INTO places VALUES ('park', ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))'))`)

// Serialization
db.executeSync('SELECT ST_AsText(geom) FROM places')      // WKT
db.executeSync('SELECT ST_AsGeoJSON(geom) FROM places')   // GeoJSON
db.executeSync('SELECT ST_AsWKB(geom) FROM places')       // WKB (binary)

// Accessors
db.executeSync('SELECT ST_X(geom), ST_Y(geom) FROM places')
db.executeSync('SELECT ST_GeometryType(geom) FROM places')
```

Points, linestrings, polygons, and their multi-variants plus geometry collections are supported, matching PostGIS conventions.

## Measurements and Operations

```ts
// Planar measurements (in coordinate units)
db.executeSync('SELECT ST_Distance(a.geom, b.geom) FROM places a, places b')
db.executeSync('SELECT ST_Area(geom), ST_Perimeter(geom) FROM regions')
db.executeSync('SELECT ST_Length(geom) FROM routes')

// Great-circle distance in meters for lon/lat points
db.executeSync('SELECT ST_Distance_Sphere(ST_Point(13.4, 52.5), ST_Point(2.35, 48.85))')

// Geometry operations (GEOS)
db.executeSync('SELECT ST_Buffer(geom, 0.01) FROM places')
db.executeSync('SELECT ST_Union(a.geom, b.geom) FROM zones a, zones b')
db.executeSync('SELECT ST_Intersection(a.geom, b.geom) FROM zones a, zones b')
db.executeSync('SELECT ST_Centroid(geom), ST_ConvexHull(geom), ST_Simplify(geom, 0.001) FROM regions')
```

## Predicates and Spatial Joins

```ts
// Point-in-polygon
const result = db.executeSync(`
  SELECT p.name, r.region_name
  FROM places p
  JOIN regions r ON ST_Within(p.geom, r.geom)
`)

// Other predicates: ST_Contains, ST_Intersects, ST_Overlaps, ST_Touches,
// ST_Crosses, ST_Equals, ST_Disjoint, ST_DWithin
const nearby = db.executeSync(`
  SELECT name FROM places
  WHERE ST_DWithin(geom, ST_Point(11.08, 47.26), 0.05)
`)
```

### R-Tree Indexes

Spatial predicates on large tables benefit from an R-tree index:

```ts
db.executeSync('CREATE INDEX places_rtree ON places USING RTREE (geom)')
```

## Coordinate Transforms (PROJ)

`ST_Transform` reprojects geometries between coordinate reference systems. The full PROJ CRS database (`proj.db`) is **embedded in the binary**, so every EPSG code resolves and standard transformations work fully offline — no data files to bundle:

```ts
// WGS84 lat/lon → Web Mercator
// Note: EPSG:4326 declares lat/lon axis order, so pass (lat, lon).
const mercator = db.executeSync(`
  SELECT ST_Transform(ST_Point(52.52, 13.405), 'EPSG:4326', 'EPSG:3857') AS geom
`)

// Use always_xy := true to keep lon/lat ordering instead
const xy = db.executeSync(`
  SELECT ST_Transform(ST_Point(13.405, 52.52), 'EPSG:4326', 'EPSG:3857', always_xy := true) AS geom
`)
```

> **Accuracy caveat:** `proj.db` holds CRS definitions and transformation metadata, but datum shift *grids* — per-location correction tables that PROJ reads itself, distributed as NTv2/NADCON/GeoTIFF files (no relation to GDAL raster support) — are separate files that are not bundled, and PROJ's network fetch is disabled. Transformations that would use a grid for maximum accuracy — e.g. NAD27→NAD83, or OSGB36 via OSTN15 — silently fall back to a grid-free path, typically costing on the order of a meter or more depending on the datum pair. A transform errors only when no grid-free fallback exists. The common cases (WGS84, Web Mercator, UTM zones, and other Helmert-based pairs) are unaffected.

## File Formats (GDAL)

`ST_Read` reads GDAL-supported vector formats; `COPY ... WITH (FORMAT GDAL)` writes them. The mobile build ships a curated driver set: GeoJSON (+GeoJSONSeq/ESRIJSON/TopoJSON), ESRI Shapefile, GeoPackage, FlatGeobuf, CSV, GPX, KML, GML, SQLite, OpenFileGDB, and VRT. Run `SELECT * FROM ST_Drivers()` to list the exact set. (Niche drivers — nautical charts, CAD, spreadsheets, etc. — are disabled for binary size; see `scripts/vcpkg-spatial-deps-options.cmake`.)

```ts
// Read features (attributes become columns, geometry becomes a GEOMETRY column)
const features = db.executeSync(`SELECT * FROM ST_Read('${dir}/neighborhoods.geojson')`)

// Create a table from a file
db.executeSync(`CREATE TABLE hoods AS SELECT * FROM ST_Read('${dir}/hoods.gpkg')`)

// Write
db.executeSync(`
  COPY (SELECT name, geom FROM places)
  TO '${dir}/places.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON')
`)

// List available drivers
db.executeSync('SELECT * FROM ST_Drivers()')
```

Paths must be absolute — see [File Paths on Mobile](extensions.md#file-paths-on-mobile) for the pattern of resolving your app's documents directory.

GeoParquet also works without GDAL: `SELECT * FROM 'file.parquet'` with the `parquet` extension loads geometry columns, and spatial understands them.

## Use Cases

**Cloud-native geospatial** — With `httpfs`, query GeoParquet on S3 (or any HTTP host) straight from the device. Geometry columns come back as real `GEOMETRY` values, so predicates just work:

```sql
SELECT * FROM read_parquet('s3://bucket/buildings.parquet')
WHERE bbox.xmin < :maxx AND bbox.xmax > :minx  -- prunes row groups via parquet stats
  AND bbox.ymin < :maxy AND bbox.ymax > :miny
  AND ST_Intersects(geometry, ST_MakeEnvelope(:minx, :miny, :maxx, :maxy));
```

If the file has a GeoParquet 1.1 `bbox` covering column and is spatially sorted (like Overture's releases), DuckDB fetches only the parquet footer plus the row groups overlapping the query window — a few hundred KB instead of the whole file.

**Offline maps data** — Ship a GeoPackage or FlatGeobuf with your app and query it locally:

```sql
SELECT name, ST_AsGeoJSON(geom) FROM ST_Read('/path/bundle.gpkg')
WHERE ST_Intersects(geom, ST_MakeEnvelope(:minx, :miny, :maxx, :maxy));
```

**Geofencing** — Which zone is the user in right now?

```sql
SELECT zone_id FROM zones WHERE ST_Contains(geom, ST_Point(:lon, :lat));
```

**Track analysis** — Aggregate GPS traces recorded on device:

```sql
SELECT trip_id, ST_Length(ST_MakeLine(list(geom ORDER BY ts))) AS dist
FROM gps_points GROUP BY trip_id;
```

## Limitations

- **GDAL can't fetch over the network** — to be clear, remote Parquet/GeoParquet/CSV work fine through `httpfs` (the S3 example above); this limitation is only about GDAL *format* files. GeoJSON, GeoPackage, Shapefile, and friends must be local — `ST_Read('https://…/file.geojson')` will fail. Download the file first (your app's own fetch, or `httpfs`), then `ST_Read` the local path. This matches duckdb-spatial's own iOS/Android builds, which exclude the `curl`/`openssl` dependencies.
- **No datum shift grids** — grid-refined transforms fall back to lower-accuracy grid-free paths; see the accuracy caveat under [Coordinate Transforms](#coordinate-transforms-proj).
- **Android: 64-bit only** — spatial is automatically skipped on `armeabi-v7a` and `x86` (like httpfs). All modern devices are 64-bit.
- **Vector data only** — `ST_Read` reads vector formats. Raster support is not exposed.

## Binary Size

The heaviest extension. Measured on Android arm64 against an otherwise identical build: spatial adds **~24 MB installed** (GDAL + GEOS + PROJ + the embedded proj.db) and **~8 MB to the compressed download** — stores deliver one architecture, compressed. Include it only when you need it.

## Version Pinning

The extension is pinned to the duckdb-spatial commit that DuckDB's own CI builds against the bundled DuckDB (`scripts/configure-extensions.js`). Its native dependencies are pinned via vcpkg to the exact versions duckdb-spatial tests (`scripts/build-spatial-deps.sh`).
