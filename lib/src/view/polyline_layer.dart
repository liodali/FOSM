import 'package:flutter/material.dart';
import 'package:fosm/src/api/map_polyline.dart';
import 'package:fosm/src/api/tile_manager.dart';

/// Internal rendering layer for [MapView.polylines]: projects each
/// polyline's vertices to viewport-local pixels and draws them as stroked
/// paths. Non-interactive — never enters hit testing, so map and marker
/// gestures are unaffected.
///
/// Positioned above the tile grid (and the old-grid zoom-transition
/// overlay) and below the marker layer and the vector label overlay.
class PolylineLayer extends StatelessWidget {
  final List<MapPolyline> polylines;
  final TileManager manager;

  const PolylineLayer({
    super.key,
    required this.polylines,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: PolylinePainter(
          polylines: polylines,
          manager: manager,
        ),
      ),
    );
  }
}

/// Projects [MapPolyline] vertices with [TileManager.latLngToScreen] — the
/// same projection markers use, so route geometry stays aligned with the
/// rest of the map on every pan and zoom frame.
class PolylinePainter extends CustomPainter {
  final List<MapPolyline> polylines;
  final TileManager manager;

  PolylinePainter({
    required this.polylines,
    required this.manager,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    for (final polyline in polylines) {
      if (polyline.points.length < 2) continue;

      final path = Path();
      final first = manager.latLngToScreen(polyline.points.first);
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < polyline.points.length; i++) {
        final point = manager.latLngToScreen(polyline.points[i]);
        path.lineTo(point.dx, point.dy);
      }

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = polyline.strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = polyline.color
          ..isAntiAlias = true,
      );
    }

    canvas.restore();
  }

  // TileManager is mutable and the same instance survives camera movement,
  // so identity comparison is not enough — repaint on every build.
  @override
  bool shouldRepaint(PolylinePainter oldDelegate) => true;
}
