import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import '../api/geo_point.dart';
import '../api/tile_manager.dart';
import '../common/osm_transformation_utilities.dart'
    show lat2TileY, lon2TileX, maxWebMercatorLatitude;

/// Camera snapshot for cached-world affine projection.
///
/// The screen projection of a normalized world coordinate is
/// bit-identical to [TileManager.latLngToScreen]: `latLngToScreen` computes
/// the fractional tile coordinate as `((lat/lng input) rounded once) *
/// 2^zoom`, and multiplying a double by an exact power of two never rounds,
/// so scaling the cached `zoom = 0` coordinate by the same factor reproduces
/// the identical bits. Every later operation keeps the original expression
/// shape, so no additional rounding is introduced anywhere.
class ShapeCamera {
  ShapeCamera.of(TileManager manager)
      : worldTiles = math.pow(2.0, manager.zoom).toDouble(),
        centerTileLng = manager.centerTileLng,
        centerTileLat = manager.centerTileLat,
        tileWidth = manager.renderedTileWidth,
        tileHeight = manager.renderedTileHeight,
        centerX = manager.centerCanvasX,
        centerY = manager.centerCanvasY;

  final double worldTiles;
  final double centerTileLng;
  final double centerTileLat;
  final double tileWidth;
  final double tileHeight;
  final double centerX;
  final double centerY;

  /// Screen X of a normalized world X. Same expression as
  /// [TileManager.latLngToScreen] with the tile coordinate replaced by the
  /// bit-identical `nx * worldTiles`.
  double screenX(double nx) =>
      (nx * worldTiles - centerTileLng) * tileWidth + centerX;

  /// Screen Y of a normalized world Y. See [screenX].
  double screenY(double ny) =>
      (ny * worldTiles - centerTileLat) * tileHeight + centerY;

  /// Cached world → screen. See [screenX].
  Offset toScreen(double nx, double ny) =>
      Offset(screenX(nx), screenY(ny));

  /// Inverse projection (screen → normalized world) for spatial queries.
  /// The result may round differently than the forward projection; queries
  /// must pad with [worldQueryRect] before comparing.
  double worldX(double x) =>
      ((x - centerX) / tileWidth + centerTileLng) / worldTiles;

  /// Inverse projection (screen → normalized world). See [worldX].
  double worldY(double y) =>
      ((y - centerY) / tileHeight + centerTileLat) / worldTiles;

  /// World-space preimage of the screen square `position ± radius`, padded
  /// by a relative and an absolute epsilon so float rounding in the inverse
  /// projection and the cell/rect comparisons below can never drop a
  /// segment an exact screen-space test would keep. Over-inclusion is
  /// harmless: callers run the exact test on the returned candidates.
  Rect worldQueryRect(Offset position, double radius) {
    final padded = radius + radius * 1e-6 + 1e-9;
    final x0 = worldX(position.dx - padded);
    final x1 = worldX(position.dx + padded);
    final y0 = worldY(position.dy - padded);
    final y1 = worldY(position.dy + padded);
    return Rect.fromLTRB(
      math.min(x0, x1) - 1e-12,
      math.min(y0, y1) - 1e-12,
      math.max(x0, x1) + 1e-12,
      math.max(y0, y1) + 1e-12,
    );
  }

  /// Screen-space bounds of a cached ring's world bounds. The projection
  /// is axis-aligned with positive scale, so mapping two corners suffices.
  Rect boundsToScreen(CachedShapeRing ring) => Rect.fromPoints(
        toScreen(ring.minNx, ring.minNy),
        toScreen(ring.maxNx, ring.maxNy),
      );
}

/// Cached zoom-independent projection of one ring (polyline vertices or a
/// polygon ring), plus lazily built hit-test acceleration.
///
/// `nx`/`ny` are normalized world coordinates (`lon2TileX(lng, 0)` /
/// `lat2TileY(lat, 0)`): the trigonography runs once per distinct points
/// list and every later frame projects affinely from these values.
/// Non-finite or out-of-range coordinates are retained exactly as
/// projected (the paint path draws them like `latLngToScreen` would);
/// [projectable] separately records whether the ring passes the stricter
/// validation `projectRing` applies before selection.
class CachedShapeRing {
  CachedShapeRing._(
    this.nx,
    this.ny,
    this.projectable,
    this.minNx,
    this.minNy,
    this.maxNx,
    this.maxNy,
  );

  /// Normalized world X per vertex. Invalid vertices keep their projected
  /// value (including infinities and NaN) so the paint path reproduces
  /// `latLngToScreen` bit-for-bit.
  final Float64List nx;

  /// Normalized world Y per vertex. See [nx].
  final Float64List ny;

  /// Whether every vertex passes `projectRing`'s input validation (finite,
  /// within the Web Mercator latitude range and ±180° longitude).
  final bool projectable;

  /// World bounds over all vertices. Only meaningful when [projectable]
  /// (invalid vertices could make these partial); hit tests never read
  /// them otherwise.
  final double minNx;
  final double minNy;
  final double maxNx;
  final double maxNy;

  /// Lazily built segment index; see [ShapeGeometryCache.gridFor].
  RingSegmentGrid? _grid;

  /// Number of vertices.
  int get pointCount => nx.length;

  /// Whether [worldRect] overlaps this ring's world bounds. Only valid for
  /// [projectable] rings.
  bool boundsOverlaps(Rect worldRect) =>
      minNx <= worldRect.right &&
      maxNx >= worldRect.left &&
      minNy <= worldRect.bottom &&
      maxNy >= worldRect.top;

  /// Vertex units charged against the cache budget: coordinates plus the
  /// lazily built segment index.
  int get vertexUnits => pointCount + (_grid == null ? 0 : pointCount);

  static CachedShapeRing build(List<LatLng> points) {
    final count = points.length;
    final nx = Float64List(count);
    final ny = Float64List(count);
    var projectable = true;
    var minNx = double.infinity;
    var minNy = double.infinity;
    var maxNx = double.negativeInfinity;
    var maxNy = double.negativeInfinity;
    for (var i = 0; i < count; i++) {
      final point = points[i];
      final x = lon2TileX(point.longitude, 0);
      final y = lat2TileY(point.latitude, 0);
      nx[i] = x;
      ny[i] = y;
      if (point.latitude.isFinite &&
          point.longitude.isFinite &&
          point.latitude.abs() <= maxWebMercatorLatitude &&
          point.longitude.abs() <= 180) {
        if (x < minNx) minNx = x;
        if (y < minNy) minNy = y;
        if (x > maxNx) maxNx = x;
        if (y > maxNy) maxNy = y;
      } else {
        projectable = false;
      }
    }
    return CachedShapeRing._(
        nx, ny, projectable, minNx, minNy, maxNx, maxNy);
  }
}

/// Uniform grid over segment bounding boxes in world coordinates.
///
/// Built once per data revision and queried at any camera: a query
/// converts the screen-space search square to its world preimage (padded)
/// and collects every segment whose world bounding box overlaps it. The
/// returned candidates are a conservative superset of the segments an
/// exact screen-space distance test would accept; the caller runs that
/// exact test. Segments spanning too many cells are stored in a linear
/// "oversize" list so pathological long segments cannot blow up build
/// cost.
class RingSegmentGrid {
  /// Rings with fewer vertices than this are scanned linearly instead —
  /// brute force is already cheap and needs no index.
  static const int minPointCount = 512;

  /// Upper bound on cells per axis.
  static const int _maxSide = 256;

  /// Target average segment occupancy per occupied cell.
  static const int _targetSegmentsPerCell = 16;

  /// Segments covering more cells than this go to the oversize list.
  static const int _oversizeCellThreshold = 64;

  RingSegmentGrid._(
    this._ring,
    this._side,
    this._cellWidth,
    this._cellHeight,
    this._cells,
    this._oversize,
    this._segmentCount,
  ) : _visitEpoch = Int32List(_ring.pointCount - 1);

  final CachedShapeRing _ring;
  final int _side;

  /// Width of one cell in world units (1.0 degenerates to a single column).
  final double _cellWidth;

  /// Height of one cell in world units. See [_cellWidth].
  final double _cellHeight;
  final Map<int, List<int>> _cells;
  final List<int> _oversize;
  final int _segmentCount;
  final Int32List _visitEpoch;
  int _epoch = 0;

  /// Segments indexed: `i` connects vertices `i` and `i + 1`; the ring is
  /// open (no closing segment — polygon callers test that one explicitly).
  int get segmentCount => _segmentCount;

  static RingSegmentGrid build(CachedShapeRing ring) {
    final nx = ring.nx;
    final ny = ring.ny;
    final segmentCount = nx.length - 1;
    final side = math.max(
        1,
        math.min(_maxSide,
            math.sqrt(segmentCount / _targetSegmentsPerCell).ceil()));
    final spanX = ring.maxNx - ring.minNx;
    final spanY = ring.maxNy - ring.minNy;
    final cellWidth = spanX > 0 ? spanX / side : 1.0;
    final cellHeight = spanY > 0 ? spanY / side : 1.0;
    final cells = <int, List<int>>{};
    final oversize = <int>[];
    for (var i = 0; i < segmentCount; i++) {
      final ix0 = _cellIndex(nx[i], ring.minNx, cellWidth, side);
      final iy0 = _cellIndex(ny[i], ring.minNy, cellHeight, side);
      final ix1 = _cellIndex(nx[i + 1], ring.minNx, cellWidth, side);
      final iy1 = _cellIndex(ny[i + 1], ring.minNy, cellHeight, side);
      final lowX = math.min(ix0, ix1);
      final highX = math.max(ix0, ix1);
      final lowY = math.min(iy0, iy1);
      final highY = math.max(iy0, iy1);
      if ((highX - lowX + 1) * (highY - lowY + 1) > _oversizeCellThreshold) {
        oversize.add(i);
        continue;
      }
      for (var cy = lowY; cy <= highY; cy++) {
        for (var cx = lowX; cx <= highX; cx++) {
          cells.putIfAbsent(cy * side + cx, () => []).add(i);
        }
      }
    }
    return RingSegmentGrid._(
        ring, side, cellWidth, cellHeight, cells, oversize, segmentCount);
  }

  static int _cellIndex(double value, double min, double cell, int side) {
    if (cell <= 0) return 0;
    return ((value - min) / cell).floor().clamp(0, side - 1);
  }

  /// Visits every segment whose world bounding box overlaps [worldRect]
  /// (built from [ShapeCamera.worldQueryRect]). Each segment is visited at
  /// most once, in no particular order.
  void query(Rect worldRect, void Function(int segmentIndex) visit) {
    final nx = _ring.nx;
    final ny = _ring.ny;
    if (_epoch == 0x7fffffff) {
      _visitEpoch.fillRange(0, _visitEpoch.length, 0);
      _epoch = 1;
    } else {
      _epoch++;
    }
    final epoch = _epoch;

    final lowX = _cellIndex(worldRect.left, _ring.minNx, _cellWidth, _side);
    final highX = _cellIndex(worldRect.right, _ring.minNx, _cellWidth, _side);
    final lowY = _cellIndex(worldRect.top, _ring.minNy, _cellHeight, _side);
    final highY =
        _cellIndex(worldRect.bottom, _ring.minNy, _cellHeight, _side);

    for (var cy = lowY; cy <= highY; cy++) {
      for (var cx = lowX; cx <= highX; cx++) {
        final bucket = _cells[cy * _side + cx];
        if (bucket == null) continue;
        for (var k = 0; k < bucket.length; k++) {
          _visitSegment(bucket[k], epoch, worldRect, nx, ny, visit);
        }
      }
    }
    for (var k = 0; k < _oversize.length; k++) {
      _visitSegment(_oversize[k], epoch, worldRect, nx, ny, visit);
    }
  }

  void _visitSegment(
    int i,
    int epoch,
    Rect worldRect,
    Float64List nx,
    Float64List ny,
    void Function(int segmentIndex) visit,
  ) {
    if (_visitEpoch[i] == epoch) return;
    _visitEpoch[i] = epoch;
    final x0 = nx[i];
    final y0 = ny[i];
    final x1 = nx[i + 1];
    final y1 = ny[i + 1];
    final minX = x0 < x1 ? x0 : x1;
    final maxX = x0 < x1 ? x1 : x0;
    final minY = y0 < y1 ? y0 : y1;
    final maxY = y0 < y1 ? y1 : y0;
    if (minX > worldRect.right ||
        maxX < worldRect.left ||
        minY > worldRect.bottom ||
        maxY < worldRect.top) {
      return;
    }
    visit(i);
  }
}

/// Bounded LRU of cached ring projections shared by painting and hit
/// testing.
///
/// Entries are keyed by the *identity* of the caller-owned points list:
/// replacing the list (the documented way to change route/area data)
/// invalidates automatically, while style-only rebuilds that reuse a list
/// keep their cached projection. Mutating a list in place is unsupported
/// for the same reason it is unsupported for [MapPolyline] configuration.
///
/// Retained memory is bounded by [maxCachedVertices] vertex units (16
/// bytes of coordinates per unit, plus the same again once a segment
/// index was built). Live-updating routes that replace their points list
/// every frame simply evict their own older generations.
class ShapeGeometryCache {
  ShapeGeometryCache({this.maxCachedVertices = 262144});

  /// Retention budget in vertex units. Entries are evicted
  /// least-recently-used first; the ring currently being inserted is never
  /// evicted, so a single route larger than the budget still renders.
  final int maxCachedVertices;

  final LinkedHashMap<List<LatLng>, CachedShapeRing> _entries =
      LinkedHashMap<List<LatLng>, CachedShapeRing>(
    equals: (a, b) => identical(a, b),
    hashCode: (list) => identityHashCode(list),
  );

  int _vertexUnits = 0;
  int _builds = 0;

  /// Entries currently retained.
  int get debugRingCount => _entries.length;

  /// Entries currently retained (public attribution surface).
  int get ringCount => _entries.length;

  /// Vertex units currently charged against [maxCachedVertices].
  int get debugCachedVertices => _vertexUnits;

  /// Vertex units currently charged against [maxCachedVertices]
  /// (public attribution surface).
  int get cachedVertexUnits => _vertexUnits;

  /// Total ring projections computed since creation (cache misses).
  int get debugRingBuilds => _builds;

  /// Cached projection for [points], computing it on first sight. The
  /// list instance is retained as the key until evicted.
  CachedShapeRing ring(List<LatLng> points) {
    final existing = _entries[points];
    if (existing != null) {
      // LRU touch: re-insert at the end (most recently used).
      _entries.remove(points);
      _entries[points] = existing;
      return existing;
    }
    final built = CachedShapeRing.build(points);
    _entries[points] = built;
    _vertexUnits += built.vertexUnits;
    _builds++;
    _evictExcept(points);
    return built;
  }

  /// Segment grid for [ring], building it on first use. Returns null when
  /// the ring is too small to benefit from an index; callers then scan
  /// the cached coordinates linearly.
  RingSegmentGrid? gridFor(CachedShapeRing ring, List<LatLng> points) {
    if (ring._grid != null) return ring._grid;
    if (ring.pointCount < RingSegmentGrid.minPointCount) return null;
    final grid = RingSegmentGrid.build(ring);
    ring._grid = grid;
    _vertexUnits += ring.pointCount;
    _evictExcept(points);
    return grid;
  }

  void _evictExcept(List<LatLng> keep) {
    while (_vertexUnits > maxCachedVertices && _entries.length > 1) {
      final eldest = _entries.keys.first;
      if (identical(eldest, keep)) break;
      final removed = _entries.remove(eldest)!;
      _vertexUnits -= removed.vertexUnits;
    }
  }

  /// Drops every cached entry.
  void clear() {
    _entries.clear();
    _vertexUnits = 0;
  }
}
