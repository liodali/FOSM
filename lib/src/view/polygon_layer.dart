import 'package:flutter/material.dart';

import '../api/map_polygon.dart';
import '../api/tile_manager.dart';
import 'shape_geometry.dart';

/// Painted below routes and markers. Selection uses the map's gesture surface,
/// so this layer never competes with marker or camera recognizers.
class PolygonLayer extends StatelessWidget {
  const PolygonLayer(
      {super.key, required this.polygons, required this.manager});
  final List<MapPolygon> polygons;
  final TileManager manager;

  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: CustomPaint(
          size: Size.infinite,
          painter: PolygonPainter(polygons: polygons, manager: manager)));
}

class PolygonPainter extends CustomPainter {
  PolygonPainter({required this.polygons, required this.manager});
  final List<MapPolygon> polygons;
  final TileManager manager;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final polygon in polygons) {
      final projected = projectPolygon(polygon, manager);
      if (projected == null) continue;
      canvas.drawPath(projected.path, Paint()..color = polygon.color);
      if (polygon.borderWidth > 0) {
        canvas.drawPath(
            projected.path,
            Paint()
              ..color = polygon.borderColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = polygon.borderWidth
              ..strokeJoin = StrokeJoin.round);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PolygonPainter oldDelegate) => true;
}
