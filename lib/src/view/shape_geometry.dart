import 'dart:ui';

import '../api/geo_point.dart';
import '../api/map_polygon.dart';
import '../api/map_polyline.dart';
import '../api/tile_manager.dart';
import '../common/osm_transformation_utilities.dart'
    show maxWebMercatorLatitude;

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

class ProjectedPolygon {
  const ProjectedPolygon(this.path, this.rings);
  final Path path;
  final List<List<Offset>> rings;
}

/// Uses the same path for painting and selection, including hole exclusions.
ProjectedPolygon? projectPolygon(MapPolygon polygon, TileManager manager) {
  if (polygon.points.length < 3 ||
      !polygon.borderWidth.isFinite ||
      polygon.borderWidth < 0) {
    return null;
  }
  final outer = projectRing(polygon.points, manager);
  if (outer == null) return null;
  final rings = <List<Offset>>[outer];
  for (final hole in polygon.holes) {
    if (hole.length < 3) continue;
    final projected = projectRing(hole, manager);
    if (projected == null) return null;
    rings.add(projected);
  }
  final path = Path()..fillType = PathFillType.evenOdd;
  for (final ring in rings) {
    path.moveTo(ring.first.dx, ring.first.dy);
    for (final point in ring.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();
  }
  return ProjectedPolygon(path, rings);
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
MapPolylineHit? hitTestPolylines(
    List<MapPolyline> lines, TileManager manager, Offset position,
    {bool longPress = false, bool enableAll = false}) {
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
    final points = projectRing(line.points, manager);
    if (points == null) continue;
    final border = line.borderColor != null &&
            line.borderWidth.isFinite &&
            line.borderWidth > 0
        ? line.borderWidth
        : 0.0;
    final radius = line.strokeWidth / 2 + border + line.hitTolerance;
    if (!radius.isFinite) continue;
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
  }
  return null;
}

MapPolygonHit? hitTestPolygons(
    List<MapPolygon> polygons, TileManager manager, Offset position,
    {bool longPress = false, bool enableAll = false}) {
  for (final polygon in polygons.reversed) {
    if (!enableAll &&
        !polygon.interactive &&
        (longPress ? polygon.onLongPress == null : polygon.onTap == null)) {
      continue;
    }
    if (!polygon.hitTolerance.isFinite || polygon.hitTolerance < 0) continue;
    final projected = projectPolygon(polygon, manager);
    if (projected == null) continue;
    var contains = projected.path.contains(position);
    // Permit selecting painted boundaries (including a hole's border), but
    // unpainted hole interiors pass through to underlying features/the map.
    if (!contains && polygon.borderWidth > 0 && polygon.borderColor.a > 0) {
      final radius = polygon.borderWidth / 2 + polygon.hitTolerance;
      for (final ring in projected.rings) {
        for (var i = 0; i < ring.length; i++) {
          final nearest =
              nearestOnSegment(position, ring[i], ring[(i + 1) % ring.length]);
          if ((nearest - position).distanceSquared <= radius * radius) {
            contains = true;
            break;
          }
        }
        if (contains) break;
      }
    }
    if (contains) {
      return MapPolygonHit(
          polygon: polygon, point: manager.screenToLatLng(position));
    }
  }
  return null;
}
