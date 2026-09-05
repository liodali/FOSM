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
  static const double _minCycle = 1.0;
  static const double _minSpacing = 1.0;

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
      if (!polyline.strokeWidth.isFinite || polyline.strokeWidth <= 0) continue;
      if (!polyline.strokeMiterLimit.isFinite ||
          polyline.strokeMiterLimit <= 0) {
        continue;
      }

      final route = _buildRoute(polyline);
      switch (polyline.pattern) {
        case SolidMapPolylinePattern _:
          _paintSolid(canvas, polyline, route.path);
        case DashedMapPolylinePattern pattern:
          _paintDashed(canvas, polyline, route, pattern, size);
        case DottedMapPolylinePattern pattern:
          _paintDotted(canvas, polyline, route, pattern, size);
      }
    }

    canvas.restore();
  }

  _ProjectedRoute _buildRoute(MapPolyline polyline) {
    final path = Path();
    final points = <Offset>[];
    for (final point in polyline.points) {
      points.add(manager.latLngToScreen(point));
    }

    path.moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    return _ProjectedRoute(path, points);
  }

  void _paintSolid(Canvas canvas, MapPolyline polyline, Path path) {
    final borderPaint = _borderPaint(polyline);
    if (borderPaint != null) {
      canvas.drawPath(path, borderPaint);
    }
    canvas.drawPath(path, _mainPaint(polyline));
  }

  void _paintDashed(
    Canvas canvas,
    MapPolyline polyline,
    _ProjectedRoute route,
    DashedMapPolylinePattern pattern,
    Size size,
  ) {
    final cycle = pattern.dashLength + pattern.gapLength;
    if (!pattern.dashLength.isFinite ||
        pattern.dashLength <= 0 ||
        !pattern.gapLength.isFinite ||
        pattern.gapLength <= 0 ||
        !cycle.isFinite ||
        cycle < _minCycle ||
        !pattern.offset.isFinite) {
      return;
    }

    final metricIterator = route.path.computeMetrics().iterator;
    if (!metricIterator.moveNext()) return;
    final metric = metricIterator.current;
    if (!metric.length.isFinite || metric.length <= 0) return;

    final ranges = _visibleDistanceRanges(
      route.points,
      size,
      _strokeCullInflation(polyline),
    );
    if (ranges.isEmpty) return;

    var offset = pattern.offset % cycle;
    if (offset < 0) offset += cycle;

    final dashPath = Path();
    var lastDashIndex = -1;
    for (final range in ranges) {
      var dashIndex =
          ((range.start - offset - pattern.dashLength) / cycle).ceil();
      if (dashIndex < 0) dashIndex = 0;

      while (true) {
        final start = offset + dashIndex * cycle;
        if (!start.isFinite || start > range.end || start >= metric.length) {
          break;
        }
        final end = (start + pattern.dashLength).clamp(0.0, metric.length);
        if (end >= range.start && end > start && dashIndex > lastDashIndex) {
          dashPath.addPath(
            metric.extractPath(start, end, startWithMoveTo: true),
            Offset.zero,
          );
          lastDashIndex = dashIndex;
        }
        dashIndex++;
      }
    }

    final borderPaint = _borderPaint(polyline);
    if (borderPaint != null) {
      canvas.drawPath(dashPath, borderPaint);
    }
    canvas.drawPath(dashPath, _mainPaint(polyline));
  }

  void _paintDotted(
    Canvas canvas,
    MapPolyline polyline,
    _ProjectedRoute route,
    DottedMapPolylinePattern pattern,
    Size size,
  ) {
    final spacing = pattern.spacing;
    if (!spacing.isFinite ||
        spacing < _minSpacing ||
        !pattern.offset.isFinite) {
      return;
    }

    final borderExtension = polyline.borderColor != null &&
            polyline.borderWidth.isFinite &&
            polyline.borderWidth > 0
        ? polyline.borderWidth
        : 0.0;
    final borderRadius = polyline.strokeWidth / 2 + borderExtension;
    if (!borderRadius.isFinite) return;

    final metricIterator = route.path.computeMetrics().iterator;
    if (!metricIterator.moveNext()) return;
    final metric = metricIterator.current;
    if (!metric.length.isFinite || metric.length <= 0) return;

    final ranges = _visibleDistanceRanges(
      route.points,
      size,
      borderRadius + 1,
    );
    if (ranges.isEmpty) return;

    var offset = pattern.offset % spacing;
    if (offset < 0) offset += spacing;

    final centers = <Offset>[];
    var lastDotIndex = -1;
    for (final range in ranges) {
      var dotIndex = ((range.start - offset) / spacing).ceil();
      if (dotIndex < 0) dotIndex = 0;

      while (true) {
        final distance = offset + dotIndex * spacing;
        if (!distance.isFinite ||
            distance > range.end ||
            distance >= metric.length) {
          break;
        }
        if (dotIndex > lastDotIndex) {
          final tangent = metric.getTangentForOffset(distance);
          if (tangent != null) centers.add(tangent.position);
          lastDotIndex = dotIndex;
        }
        dotIndex++;
      }
    }

    if (centers.isEmpty) return;

    if (borderExtension > 0) {
      final borderPaint = _fillPaint(polyline.borderColor!);
      for (final center in centers) {
        canvas.drawCircle(center, borderRadius, borderPaint);
      }
    }

    final mainRadius = polyline.strokeWidth / 2;
    final mainPaint = _fillPaint(polyline.color);
    for (final center in centers) {
      canvas.drawCircle(center, mainRadius, mainPaint);
    }
  }

  List<_DistanceRange> _visibleDistanceRanges(
    List<Offset> points,
    Size size,
    double inflation,
  ) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0 ||
        !inflation.isFinite ||
        inflation < 0) {
      return const [];
    }

    final viewport = (Offset.zero & size).inflate(inflation);
    final ranges = <_DistanceRange>[];
    var cumulativeDistance = 0.0;

    for (var i = 1; i < points.length; i++) {
      final start = points[i - 1];
      final end = points[i];
      if (!start.dx.isFinite ||
          !start.dy.isFinite ||
          !end.dx.isFinite ||
          !end.dy.isFinite) {
        return const [];
      }

      final segmentLength = (end - start).distance;
      if (!segmentLength.isFinite) return const [];
      if (segmentLength <= 0) continue;

      final clipped = _clipSegment(start, end, viewport);
      if (clipped != null) {
        final visibleStart = cumulativeDistance + clipped.start * segmentLength;
        final visibleEnd = cumulativeDistance + clipped.end * segmentLength;
        if (ranges.isNotEmpty && visibleStart <= ranges.last.end) {
          final previous = ranges.last;
          ranges[ranges.length - 1] = _DistanceRange(
            previous.start,
            visibleEnd > previous.end ? visibleEnd : previous.end,
          );
        } else {
          ranges.add(_DistanceRange(visibleStart, visibleEnd));
        }
      }
      cumulativeDistance += segmentLength;
    }

    return ranges;
  }

  _DistanceRange? _clipSegment(Offset start, Offset end, Rect rect) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    var lower = 0.0;
    var upper = 1.0;

    bool clip(double direction, double distance) {
      if (direction == 0) return distance >= 0;
      final ratio = distance / direction;
      if (direction < 0) {
        if (ratio > upper) return false;
        if (ratio > lower) lower = ratio;
      } else {
        if (ratio < lower) return false;
        if (ratio < upper) upper = ratio;
      }
      return true;
    }

    if (!clip(-dx, start.dx - rect.left) ||
        !clip(dx, rect.right - start.dx) ||
        !clip(-dy, start.dy - rect.top) ||
        !clip(dy, rect.bottom - start.dy)) {
      return null;
    }
    return _DistanceRange(lower, upper);
  }

  double _strokeCullInflation(MapPolyline polyline) {
    final borderExtension = polyline.borderColor != null &&
            polyline.borderWidth.isFinite &&
            polyline.borderWidth > 0
        ? polyline.borderWidth
        : 0.0;
    final halfWidth = polyline.strokeWidth / 2 + borderExtension;
    var outset = halfWidth;
    if (polyline.strokeCap == StrokeCap.square) {
      outset = halfWidth * 1.4142135623730951;
    }
    if (polyline.strokeJoin == StrokeJoin.miter) {
      final miterOutset = halfWidth * polyline.strokeMiterLimit;
      if (miterOutset > outset) outset = miterOutset;
    }
    return outset + 1;
  }

  Paint? _borderPaint(MapPolyline polyline) {
    if (polyline.borderColor == null ||
        polyline.borderWidth <= 0 ||
        !polyline.borderWidth.isFinite) {
      return null;
    }
    final outerWidth = polyline.strokeWidth + 2 * polyline.borderWidth;
    if (!outerWidth.isFinite || outerWidth <= polyline.strokeWidth) {
      return null;
    }
    return _strokePaint(
      polyline,
      outerWidth,
      polyline.borderColor!,
    );
  }

  Paint _mainPaint(MapPolyline polyline) {
    return _strokePaint(polyline, polyline.strokeWidth, polyline.color);
  }

  Paint _strokePaint(MapPolyline polyline, double width, Color color) {
    return Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = polyline.strokeCap
      ..strokeJoin = polyline.strokeJoin
      ..strokeMiterLimit = polyline.strokeMiterLimit
      ..color = color
      ..isAntiAlias = true;
  }

  Paint _fillPaint(Color color) {
    return Paint()
      ..style = PaintingStyle.fill
      ..color = color
      ..isAntiAlias = true;
  }

  // TileManager is mutable and the same instance survives camera movement,
  // so identity comparison is not enough — repaint on every build.
  @override
  bool shouldRepaint(PolylinePainter oldDelegate) => true;
}

class _ProjectedRoute {
  final Path path;
  final List<Offset> points;

  const _ProjectedRoute(this.path, this.points);
}

class _DistanceRange {
  final double start;
  final double end;

  const _DistanceRange(this.start, this.end);
}
