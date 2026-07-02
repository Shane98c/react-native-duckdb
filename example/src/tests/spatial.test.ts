import { TestRegistry } from '../testing/TestRegistry'
import { HybridDuckDB } from 'react-native-duckdb'

// Spatial extension tests: GEOMETRY type, ST_* functions, GEOS operations,
// PROJ coordinate transforms (proj.db is embedded in the binary), and
// GDAL-based file I/O.

function getDbDir(db: ReturnType<typeof HybridDuckDB.open>): string {
  const result = db.executeSync('PRAGMA database_list')
  const dbPath = result.toRows()[0].file as string
  return dbPath.substring(0, dbPath.lastIndexOf('/'))
}

// ── Category 1: Geometry Basics (spatial) ───────────────────────────

TestRegistry.registerTest(
  'Geometry Basics (spatial)',
  'ST_Point / ST_AsText round trip',
  async () => {
    const db = HybridDuckDB.open(':memory:', {})
    try {
      db.executeSync("LOAD 'spatial'")
      db.executeSync('CREATE TABLE points (id INTEGER, geom GEOMETRY)')
      db.executeSync('INSERT INTO points VALUES (1, ST_Point(11.087, 47.263))')

      const result = db.executeSync('SELECT ST_AsText(geom) AS wkt FROM points WHERE id = 1')
      const wkt = result.toRows()[0].wkt as string
      if (!wkt.startsWith('POINT')) throw new Error(`Expected POINT WKT, got ${wkt}`)
      if (!wkt.includes('11.087') || !wkt.includes('47.263'))
        throw new Error(`WKT lost coordinates: ${wkt}`)

      // X/Y accessors
      const xy = db.executeSync('SELECT ST_X(geom) AS x, ST_Y(geom) AS y FROM points').toRows()[0]
      if (Math.abs(Number(xy.x) - 11.087) > 1e-9 || Math.abs(Number(xy.y) - 47.263) > 1e-9)
        throw new Error(`ST_X/ST_Y mismatch: ${xy.x}, ${xy.y}`)

      console.debug(`ST_Point round trip: ${wkt}`)
    } finally {
      db.close()
    }
  }
)

TestRegistry.registerTest(
  'Geometry Basics (spatial)',
  'WKT parsing and geometry predicates',
  async () => {
    const db = HybridDuckDB.open(':memory:', {})
    try {
      db.executeSync("LOAD 'spatial'")

      // Unit square polygon and points inside/outside it
      const contains = db.executeSync(`
        SELECT
          ST_Contains(ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))'), ST_Point(0.5, 0.5)) AS inside,
          ST_Contains(ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))'), ST_Point(2.0, 2.0)) AS outside
      `).toRows()[0]

      if (contains.inside !== true) throw new Error(`Point (0.5,0.5) should be inside unit square`)
      if (contains.outside !== false) throw new Error(`Point (2,2) should be outside unit square`)

      // Distance between two points 3-4-5 triangle
      const dist = Number(
        db.executeSync('SELECT ST_Distance(ST_Point(0, 0), ST_Point(3, 4)) AS d').toRows()[0].d
      )
      if (Math.abs(dist - 5) > 1e-9) throw new Error(`ST_Distance should be 5, got ${dist}`)

      console.debug(`Predicates: contains works, ST_Distance(0,0 → 3,4) = ${dist}`)
    } finally {
      db.close()
    }
  }
)

// ── Category 2: GEOS Operations (spatial) ───────────────────────────

TestRegistry.registerTest(
  'GEOS Operations (spatial)',
  'ST_Area / ST_Buffer / ST_Union',
  async () => {
    const db = HybridDuckDB.open(':memory:', {})
    try {
      db.executeSync("LOAD 'spatial'")

      // Unit square has area 1
      const area = Number(
        db.executeSync(
          `SELECT ST_Area(ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))')) AS a`
        ).toRows()[0].a
      )
      if (Math.abs(area - 1) > 1e-9) throw new Error(`Unit square area should be 1, got ${area}`)

      // Buffer of a point approximates a circle: area ≈ π r²
      const bufArea = Number(
        db.executeSync('SELECT ST_Area(ST_Buffer(ST_Point(0, 0), 2)) AS a').toRows()[0].a
      )
      const circleArea = Math.PI * 4
      if (Math.abs(bufArea - circleArea) / circleArea > 0.05)
        throw new Error(`Buffer area should be ~${circleArea.toFixed(3)}, got ${bufArea}`)

      // Union of two adjacent unit squares has area 2
      const unionArea = Number(
        db.executeSync(`
          SELECT ST_Area(ST_Union(
            ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))'),
            ST_GeomFromText('POLYGON((1 0, 2 0, 2 1, 1 1, 1 0))')
          )) AS a
        `).toRows()[0].a
      )
      if (Math.abs(unionArea - 2) > 1e-9) throw new Error(`Union area should be 2, got ${unionArea}`)

      console.debug(
        `GEOS: area=${area}, buffer≈${bufArea.toFixed(3)} (π·4=${circleArea.toFixed(3)}), union=${unionArea}`
      )
    } finally {
      db.close()
    }
  }
)

TestRegistry.registerTest(
  'GEOS Operations (spatial)',
  'Spatial join: points in polygons',
  async () => {
    const db = HybridDuckDB.open(':memory:', {})
    try {
      db.executeSync("LOAD 'spatial'")

      // 10x10 grid of cells, 100 random-ish points
      db.executeSync(`
        CREATE TABLE cells AS
        SELECT x, y, ST_MakeEnvelope(x::DOUBLE, y::DOUBLE, x + 1.0, y + 1.0) AS geom
        FROM range(10) t1(x), range(10) t2(y)
      `)
      db.executeSync(`
        CREATE TABLE pts AS
        SELECT i, ST_Point(5.0 * (1 + sin(i * 0.7)), 5.0 * (1 + cos(i * 1.3))) AS geom
        FROM range(100) t(i)
      `)

      const result = db.executeSync(`
        SELECT count(*) AS cnt
        FROM pts JOIN cells ON ST_Within(pts.geom, cells.geom)
      `)
      const cnt = Number(result.toRows()[0].cnt)
      // Every point lands in [0,10)x[0,10), so each matches exactly one cell
      // (points exactly on cell edges can match zero cells, so allow a little slack)
      if (cnt < 95 || cnt > 100)
        throw new Error(`Expected ~100 point-in-cell matches, got ${cnt}`)

      console.debug(`Spatial join: ${cnt}/100 points matched to grid cells`)
    } finally {
      db.close()
    }
  }
)

// ── Category 3: Coordinate Transforms (spatial) ─────────────────────

TestRegistry.registerTest(
  'Coordinate Transforms (spatial)',
  'ST_Transform WGS84 → Web Mercator (embedded proj.db)',
  async () => {
    const db = HybridDuckDB.open(':memory:', {})
    try {
      db.executeSync("LOAD 'spatial'")

      // Berlin: lon 13.4050, lat 52.5200. EPSG:4326 axis order is lat/lon.
      const result = db.executeSync(`
        SELECT ST_X(t) AS x, ST_Y(t) AS y FROM (
          SELECT ST_Transform(ST_Point(52.5200, 13.4050), 'EPSG:4326', 'EPSG:3857') AS t
        )
      `).toRows()[0]

      const x = Number(result.x)
      const y = Number(result.y)
      // Known Web Mercator coordinates for Berlin
      const expectedX = 1492232.65
      const expectedY = 6894701.42
      if (Math.abs(x - expectedX) > 100 || Math.abs(y - expectedY) > 100)
        throw new Error(`Expected ~(${expectedX}, ${expectedY}), got (${x}, ${y})`)

      console.debug(`ST_Transform: Berlin → EPSG:3857 (${x.toFixed(1)}, ${y.toFixed(1)})`)
    } finally {
      db.close()
    }
  }
)

// ── Category 4: GDAL File I/O (spatial) ─────────────────────────────

TestRegistry.registerTest(
  'GDAL File I/O (spatial)',
  'Write and read GeoJSON via GDAL',
  async () => {
    const suffix = Date.now()
    const dbName = `test_spatial_${suffix}.db`
    const db = HybridDuckDB.open(dbName, {})
    try {
      db.executeSync("LOAD 'spatial'")
      const dir = getDbDir(db)
      const geojsonPath = `${dir}/test_${suffix}.geojson`

      db.executeSync(`
        CREATE TABLE cities (name VARCHAR, pop INTEGER, geom GEOMETRY);
      `)
      db.executeSync(`
        INSERT INTO cities VALUES
          ('Berlin', 3600000, ST_Point(13.4050, 52.5200)),
          ('Paris', 2100000, ST_Point(2.3522, 48.8566)),
          ('Madrid', 3200000, ST_Point(-3.7038, 40.4168))
      `)

      // Export via GDAL's GeoJSON driver
      db.executeSync(
        `COPY cities TO '${geojsonPath}' WITH (FORMAT GDAL, DRIVER 'GeoJSON')`
      )

      // Read it back via ST_Read
      const rows = db
        .executeSync(`SELECT name, pop, ST_AsText(geom) AS wkt FROM ST_Read('${geojsonPath}') ORDER BY name`)
        .toRows()

      if (rows.length !== 3) throw new Error(`Expected 3 features, got ${rows.length}`)
      if (rows[0].name !== 'Berlin') throw new Error(`Expected Berlin first, got ${rows[0].name}`)
      if (!(rows[0].wkt as string).startsWith('POINT'))
        throw new Error(`Expected POINT geometry, got ${rows[0].wkt}`)
      if (Number(rows[0].pop) !== 3600000)
        throw new Error(`Attribute lost in round trip: pop=${rows[0].pop}`)

      console.debug(`GDAL GeoJSON round trip: ${rows.length} features, first=${rows[0].name}`)
    } finally {
      db.close()
      HybridDuckDB.deleteDatabase(dbName)
    }
  }
)
