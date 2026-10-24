import 'package:flutter/material.dart';

import '../api/map_polygon.dart';
import '../api/tile_manager.dart';
import '../common/geometry_trace.dart';
import 'shape_geometry.dart';
import 'shape_geometry_cache.dart';

/// Painted below routes and markers. Selection uses the map's gesture surface,
/// so this layer never competes with marker or camera recognizers.
///
/// Pass the map's [ShapeGeometryCache] as [cache] so rings project from
/// cached world coordinates and polygons whose outer bounds cannot reach
/// the viewport are skipped before any projection or path work.
class PolygonLayer extends StatelessWidget {
  const PolygonLayer(
      {super.key, required this.polygons, required this.manager, this.cache});
  final List<MapPolygon> polygons;
  final TileManager manager;
  final ShapeGeometryCache? cache;

  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: CustomPaint(
          size: Size.infinite,
          painter: PolygonPainter(
              polygons: polygons, manager: manager, cache: cache)));
}

class PolygonPainter extends CustomPainter {
  PolygonPainter({required this.polygons, required this.manager, this.cache});
  final List<MapPolygon> polygons;
  final TileManager manager;
  final ShapeGeometryCache? cache;

  /// Debug/test instrumentation: polygons that reached path assembly.
  /// Bounds culling keeps offscreen polygons from projecting or building
  /// paths at all, so this stays at the visible count.
  static int debugPaintedPolygons = 0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final camera = cache == null ? null : ShapeCamera.of(manager);
    final canCull = size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0;
    final viewport = canCull ? (Offset.zero & size) : null;

    for (final polygon in polygons) {
      // projectPolygon rejects these; skip before touching the cache.
      if (polygon.points.length < 3 ||
          !polygon.borderWidth.isFinite ||
          polygon.borderWidth < 0) {
        continue;
      }

      if (camera != null && viewport != null) {
        // O(1) rejection from cached world bounds: fill and border pixels
        // stay within the border-outset-padded bounds, so a polygon whose
        // screen bounds miss the padded viewport paints nothing.
        final ring =
            GeometryTrace.sync('project', () => cache!.ring(polygon.points));
        if (!ring.projectable) continue;
        if (!_boundsReachViewport(camera, ring, viewport, polygon)) continue;
      }

      final outer = GeometryTrace.sync(
          'project', () => projectRingCached(polygon.points, manager, cache));
      if (outer == null) continue;

      if (camera == null && viewport != null) {
        // No cache: cull from the freshly projected ring instead.
        if (!_offsetsReachViewport(outer, viewport, polygon)) continue;
      }

      final rings = <List<Offset>>[outer];
      var valid = true;
      for (final hole in polygon.holes) {
        if (hole.length < 3) continue;
        final projected = GeometryTrace.sync(
            'project', () => projectRingCached(hole, manager, cache));
        if (projected == null) {
          valid = false;
          break;
        }
        rings.add(projected);
      }
      if (!valid) continue;

      final path = GeometryTrace.sync('path', () => polygonPath(rings));
      GeometryTrace.sync('paint', () {
        canvas.drawPath(path, Paint()..color = polygon.color);
        if (polygon.borderWidth > 0) {
          canvas.drawPath(
              path,
              Paint()
                ..color = polygon.borderColor
                ..style = PaintingStyle.stroke
                ..strokeWidth = polygon.borderWidth
                ..strokeJoin = StrokeJoin.round);
        }
      });
      debugPaintedPolygons++;
    }
    canvas.restore();
  }

  /// Whether [ring]'s screen bounds can reach the viewport under the
  /// polygon's border outset (fill plus stroke, plus an antialiasing pixel).
  bool _boundsReachViewport(ShapeCamera camera, CachedShapeRing ring,
      Rect viewport, MapPolygon polygon) {
    final bounds = camera.boundsToScreen(ring);
    if (!bounds.isFinite) return true;
    return bounds.overlaps(viewport.inflate(polygon.borderWidth / 2 + 1));
  }

  bool _offsetsReachViewport(
      List<Offset> outer, Rect viewport, MapPolygon polygon) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final point in outer) {
      if (point.dx < minX) minX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy > maxY) maxY = point.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY)
        .overlaps(viewport.inflate(polygon.borderWidth / 2 + 1));
  }

  @override
  bool shouldRepaint(PolygonPainter oldDelegate) => true;
}
