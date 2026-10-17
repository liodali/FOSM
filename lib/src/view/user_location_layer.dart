import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/map_location.dart';
import '../api/geo_point.dart';
import '../common/osm_transformation_utilities.dart';
import '../api/tile_manager.dart';
import '../common/scale_bar_metrics.dart';

/// Geographic accuracy radius plus a fixed-size, pointer-transparent dot.
class UserLocationLayer extends StatelessWidget {
  const UserLocationLayer(
      {super.key,
      required this.location,
      required this.manager,
      this.stale = false});
  final MapLocation location;
  final TileManager manager;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final position = manager.latLngToScreen(LatLng(
        latitude: clampLatitude(location.point.latitude),
        longitude: location.point.longitude));
    final color = stale ? Colors.grey : const Color(0xff1976d2);
    final label = stale ? 'Last known location' : 'Current location';
    return IgnorePointer(
        child: Stack(clipBehavior: Clip.hardEdge, children: [
      if (location.accuracyMeters != null && location.accuracyMeters! > 0)
        Positioned.fill(
            child: CustomPaint(
                painter: _AccuracyPainter(
                    position,
                    location.accuracyMeters! /
                        mapMetersPerPixel(
                            location.point.latitude, manager.cameraZoom),
                    color))),
      if (position.dx >= -24 &&
          position.dy >= -24 &&
          position.dx <= manager.width + 24 &&
          position.dy <= manager.height + 24)
        Positioned(
            left: position.dx - 24,
            top: position.dy - 24,
            width: 48,
            height: 48,
            child: Semantics(
                label: label,
                child: CustomPaint(
                    painter: _PositionPainter(color, location.bearing)))),
    ]));
  }
}

class _AccuracyPainter extends CustomPainter {
  const _AccuracyPainter(this.position, this.radius, this.color);
  final Offset position;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final viewport = Offset.zero & size;
    canvas.clipRect(viewport);
    final fill = Paint()..color = color.withValues(alpha: 0.12);
    final farthest = [
      viewport.topLeft,
      viewport.topRight,
      viewport.bottomLeft,
      viewport.bottomRight
    ].map((point) => (point - position).distance).reduce(math.max);
    if (radius >= farthest) {
      canvas.drawRect(viewport, fill);
    } else if (radius.isFinite) {
      canvas.drawCircle(position, radius, fill);
      canvas.drawCircle(
          position,
          radius,
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AccuracyPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.radius != radius ||
      oldDelegate.color != color;
}

class _PositionPainter extends CustomPainter {
  const _PositionPainter(this.color, this.bearing);
  final Color color;
  final double? bearing;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    if (bearing != null) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(bearing! * math.pi / 180);
      canvas.drawPath(
          Path()
            ..moveTo(0, -21)
            ..lineTo(-5, -11)
            ..lineTo(5, -11)
            ..close(),
          Paint()..color = color.withValues(alpha: 0.8));
      canvas.restore();
    }
    canvas.drawCircle(center, 9, Paint()..color = Colors.white);
    canvas.drawCircle(center, 6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PositionPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.bearing != bearing;
}
