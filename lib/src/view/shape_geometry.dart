import 'dart:ui';

import '../api/geo_point.dart';
import '../api/map_polygon.dart';
import '../api/map_polyline.dart';
import '../api/tile_manager.dart';
import '../common/geometry_trace.dart';
import '../common/osm_transformation_utilities.dart'
    show maxWebMercatorLatitude;
import 'shape_geometry_cache.dart';

/// Validates before projection so invalid geometry cannot reach Canvas/Path.
List<Offset>? projectRing(List<LatLng> points, TileManager manager) {
  final result = <Offset>[];
  for (final point in points) {
    if (!point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude.abs() > maxWebMercatorLatitude ||
        point.longitude.abs() > 180) {
      return null;
    }
    final projected = manager.latLngToScreen(point);
    if (!projected.dx.isFinite || !projected.dy.isFinite) return null;
    result.add(projected);
  }
  return result;
}

/// Projects [points] to screen offsets through [cache] when available.
///
/// The cached path reuses the ring's zoom-independent world coordinates
/// and projects affinely — bit-identical to [projectRing] while skipping
/// the per-vertex trigonography — and returns null for exactly the same
/// inputs (invalid coordinates or a non-finite screen projection).
List<Offset>? projectRingCached(
    List<LatLng> points, TileManager manager, ShapeGeometryCache? cache) {
  if (cache == null) return projectRing(points, manager);
  final ring = cache.ring(points);
  if (!ring.projectable) return null;
  final camera = ShapeCamera.of(manager);
  final result = List<Offset>.generate(
    ring.pointCount,
    (i) => camera.toScreen(ring.nx[i], ring.ny[i]),
    growable: false,
  );
  for (final offset in result) {
    if (!offset.dx.isFinite || !offset.dy.isFinite) return null;
  }
  return result;
}

class ProjectedPolygon {
  const ProjectedPolygon(this.path, this.rings);
  final Path path;
  final List<List<Offset>> rings;
}

/// Even-odd path over projected rings. Rings close automatically.
Path polygonPath(List<List<Offset>> rings) {
  final path = Path()..fillType = PathFillType.evenOdd;
  for (final ring in rings) {
    path.moveTo(ring.first.dx, ring.first.dy);
    for (final point in ring.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();
  }
  return path;
}

/// Uses the same path for painting and selection, including hole exclusions.
ProjectedPolygon? projectPolygon(MapPolygon polygon, TileManager manager,
    {ShapeGeometryCache? cache}) {
  if (polygon.points.length < 3 ||
      !polygon.borderWidth.isFinite ||
      polygon.borderWidth < 0) {
    return null;
  }
  final outer = projectRingCached(polygon.points, manager, cache);
  if (outer == null) return null;
  final rings = <List<Offset>>[outer];
  for (final hole in polygon.holes) {
    if (hole.length < 3) continue;
    final projected = projectRingCached(hole, manager, cache);
    if (projected == null) return null;
    rings.add(projected);
  }
  return ProjectedPolygon(polygonPath(rings), rings);
}

Offset nearestOnSegment(Offset point, Offset start, Offset end) {
  final delta = end - start;
  final length = delta.distanceSquared;
  if (length == 0) return start;
  final t =
      (((point.dx - start.dx) * delta.dx + (point.dy - start.dy) * delta.dy) /
              length)
          .clamp(0.0, 1.0);
  return start + delta * t;
}

/// Returns the topmost eligible route, rather than a nearer route below it.
///
/// With [cache], selection reuses the cached world coordinates, rejects
/// routes by world bounds before projecting, and scans candidate segments
/// from a per-ring grid instead of every segment. The accepted answers
/// (polyline, nearest segment/point and distance) are identical to the
/// direct scan — the grid query is conservative and the exact
/// screen-space test decides.
MapPolylineHit? hitTestPolylines(
    List<MapPolyline> lines, TileManager manager, Offset position,
    {bool longPress = false, bool enableAll = false,
     ShapeGeometryCache? cache}) {
  return GeometryTrace.sync('hit', () {
    // A non-finite position never hit before (all NaN comparisons fail);
    // the indexed path additionally requires finite query coordinates.
    if (!position.dx.isFinite || !position.dy.isFinite) return null;
    for (final line in lines.reversed) {
      if (!enableAll &&
          !line.interactive &&
          (longPress ? line.onLongPress == null : line.onTap == null)) {
        continue;
      }
      if (line.points.length < 2 ||
          !line.strokeWidth.isFinite ||
          line.strokeWidth <= 0 ||
          !line.hitTolerance.isFinite ||
          line.hitTolerance < 0) {
        continue;
      }
      final border = line.borderColor != null &&
              line.borderWidth.isFinite &&
              line.borderWidth > 0
          ? line.borderWidth
          : 0.0;
      final radius = line.strokeWidth / 2 + border + line.hitTolerance;
      if (!radius.isFinite) continue;
      final hit = cache == null
          ? _hitPolylineDirect(line, manager, position, radius)
          : _hitPolylineCached(line, manager, position, radius, cache);
      if (hit != null) return hit;
    }
    return null;
  });
}

/// The original selection algorithm: project every vertex, then scan every
/// segment. Kept as the reference path (no cache) and as the parity oracle
/// for the cached/indexed path in tests.
MapPolylineHit? _hitPolylineDirect(
    MapPolyline line, TileManager manager, Offset position, double radius) {
  final points = projectRing(line.points, manager);
  if (points == null) return null;
  var distance = double.infinity;
  Offset? nearest;
  var segment = 0;
  for (var i = 0; i < points.length - 1; i++) {
    final candidate = nearestOnSegment(position, points[i], points[i + 1]);
    final squared = (candidate - position).distanceSquared;
    if (squared < distance) {
      distance = squared;
      nearest = candidate;
      segment = i;
    }
  }
  if (nearest != null && distance <= radius * radius) {
    return MapPolylineHit(
        polyline: line,
        point: manager.screenToLatLng(position),
        nearestPoint: manager.screenToLatLng(nearest),
        distancePixels: (nearest - position).distance,
        segmentIndex: segment);
  }
  return null;
}

MapPolylineHit? _hitPolylineCached(MapPolyline line, TileManager manager,
    Offset position, double radius, ShapeGeometryCache cache) {
  final ring = cache.ring(line.points);
  if (!ring.projectable) return null;
  final camera = ShapeCamera.of(manager);
  final query = camera.worldQueryRect(position, radius);
  if (!ring.boundsOverlaps(query)) return null;

  var distance = double.infinity;
  Offset? nearest;
  var segment = -1;

  final grid = cache.gridFor(ring, line.points);
  if (grid == null) {
    // Small ring: scan linearly from the cached coordinates. Identical
    // arithmetic to the direct path (offsets are bit-identical), including
    // the whole-ring rejection on a non-finite screen projection.
    final count = ring.pointCount;
    final points = List<Offset>.generate(
      count,
      (i) => camera.toScreen(ring.nx[i], ring.ny[i]),
      growable: false,
    );
    for (final point in points) {
      if (!point.dx.isFinite || !point.dy.isFinite) return null;
    }
    for (var i = 0; i < count - 1; i++) {
      final candidate = nearestOnSegment(position, points[i], points[i + 1]);
      final squared = (candidate - position).distanceSquared;
      if (squared < distance) {
        distance = squared;
        nearest = candidate;
        segment = i;
      }
    }
  } else {
    // Candidate segments from the grid; the exact screen-space test and
    // the lowest-index tie-break reproduce the direct scan's argmin.
    grid.query(query, (i) {
      final a = camera.toScreen(ring.nx[i], ring.ny[i]);
      final b = camera.toScreen(ring.nx[i + 1], ring.ny[i + 1]);
      final candidate = nearestOnSegment(position, a, b);
      final squared = (candidate - position).distanceSquared;
      if (squared < distance || (squared == distance && i < segment)) {
        distance = squared;
        nearest = candidate;
        segment = i;
      }
    });
  }

  final best = nearest;
  if (best != null && distance <= radius * radius) {
    return MapPolylineHit(
        polyline: line,
        point: manager.screenToLatLng(position),
        nearestPoint: manager.screenToLatLng(best),
        distancePixels: (best - position).distance,
        segmentIndex: segment);
  }
  return null;
}

MapPolygonHit? hitTestPolygons(
    List<MapPolygon> polygons, TileManager manager, Offset position,
    {bool longPress = false, bool enableAll = false,
     ShapeGeometryCache? cache}) {
  return GeometryTrace.sync('hit', () {
    if (!position.dx.isFinite || !position.dy.isFinite) return null;
    for (final polygon in polygons.reversed) {
      if (!enableAll &&
          !polygon.interactive &&
          (longPress ? polygon.onLongPress == null : polygon.onTap == null)) {
        continue;
      }
      if (!polygon.hitTolerance.isFinite || polygon.hitTolerance < 0) continue;
      if (polygon.points.length < 3 ||
          !polygon.borderWidth.isFinite ||
          polygon.borderWidth < 0) {
        continue;
      }
      if (cache != null) {
        // Bounds rejection before any projection/path work. A tap whose
        // padded world preimage misses the outer ring's bounds can select
        // neither the interior nor a painted border.
        final ring = cache.ring(polygon.points);
        if (!ring.projectable) continue;
        final camera = ShapeCamera.of(manager);
        final borderReach = polygon.borderWidth > 0 && polygon.borderColor.a > 0
            ? polygon.borderWidth / 2
            : 0.0;
        if (!ring.boundsOverlaps(
            camera.worldQueryRect(position, borderReach + polygon.hitTolerance))) {
          continue;
        }
      }
      final projected = projectPolygon(polygon, manager, cache: cache);
      if (projected == null) continue;
      var contains = projected.path.contains(position);
      // Permit selecting painted boundaries (including a hole's border), but
      // unpainted hole interiors pass through to underlying features/the map.
      if (!contains && polygon.borderWidth > 0 && polygon.borderColor.a > 0) {
        final radius = polygon.borderWidth / 2 + polygon.hitTolerance;
        contains = cache == null
            ? _borderHitDirect(projected.rings, position, radius)
            : _borderHitCached(polygon, manager, position, radius, cache);
      }
      if (contains) {
        return MapPolygonHit(
            polygon: polygon, point: manager.screenToLatLng(position));
      }
    }
    return null;
  });
}

/// Original border scan: every ring segment, including the closing edge.
bool _borderHitDirect(
    List<List<Offset>> rings, Offset position, double radius) {
  for (final ring in rings) {
    for (var i = 0; i < ring.length; i++) {
      final nearest =
          nearestOnSegment(position, ring[i], ring[(i + 1) % ring.length]);
      if ((nearest - position).distanceSquared <= radius * radius) {
        return true;
      }
    }
  }
  return false;
}

bool _borderHitCached(MapPolygon polygon, TileManager manager,
    Offset position, double radius, ShapeGeometryCache cache) {
  final camera = ShapeCamera.of(manager);
  final query = camera.worldQueryRect(position, radius);

  bool ringBorderHit(List<LatLng> points) {
    final ring = cache.ring(points);
    if (!ring.projectable) return false;
    final count = ring.pointCount;
    final grid = cache.gridFor(ring, points);
    if (grid == null) {
      for (var i = 0; i < count; i++) {
        final next = (i + 1) % count;
        final a = camera.toScreen(ring.nx[i], ring.ny[i]);
        final b = camera.toScreen(ring.nx[next], ring.ny[next]);
        final nearest = nearestOnSegment(position, a, b);
        if ((nearest - position).distanceSquared <= radius * radius) {
          return true;
        }
      }
      return false;
    }
    var hit = false;
    grid.query(query, (i) {
      if (hit) return;
      final a = camera.toScreen(ring.nx[i], ring.ny[i]);
      final b = camera.toScreen(ring.nx[i + 1], ring.ny[i + 1]);
      final nearest = nearestOnSegment(position, a, b);
      if ((nearest - position).distanceSquared <= radius * radius) {
        hit = true;
      }
    });
    if (hit) return true;
    // The grid indexes open segments; polygon rings close, so the edge
    // from the last vertex back to the first is tested separately.
    final a = camera.toScreen(ring.nx[count - 1], ring.ny[count - 1]);
    final b = camera.toScreen(ring.nx[0], ring.ny[0]);
    final nearest = nearestOnSegment(position, a, b);
    return (nearest - position).distanceSquared <= radius * radius;
  }

  if (ringBorderHit(polygon.points)) return true;
  for (final hole in polygon.holes) {
    // Holes with fewer than three points are not part of the projected
    // rings; match that behavior here.
    if (hole.length < 3) continue;
    if (ringBorderHit(hole)) return true;
  }
  return false;
}
