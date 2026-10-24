import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fosm/src/api/map_polyline.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/geometry_trace.dart';
import 'package:fosm/src/view/shape_geometry_cache.dart';

/// Internal rendering layer for [MapView.polylines]: projects each
/// polyline's vertices to viewport-local pixels and draws them as stroked
/// paths. This paint-only layer ignores pointers; optional route selection is
/// handled by the map's existing gesture surface below markers.
///
/// Positioned above the tile grid (and the old-grid zoom-transition
/// overlay) and below the marker layer and the vector label overlay.
///
/// Pass the map's [ShapeGeometryCache] as [cache] so vertex projection
/// reuses cached world coordinates across frames; without a cache every
/// frame projects through [TileManager.latLngToScreen] directly.
class PolylineLayer extends StatelessWidget {
  final List<MapPolyline> polylines;
  final TileManager manager;
  final ShapeGeometryCache? cache;

  const PolylineLayer({
    super.key,
    required this.polylines,
    required this.manager,
    this.cache,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: PolylinePainter(
          polylines: polylines,
          manager: manager,
          cache: cache,
        ),
      ),
    );
  }
}

/// Projects [MapPolyline] vertices with the same projection markers use, so
/// route geometry stays aligned with the rest of the map on every pan and
/// zoom frame. With a [cache], vertices project affinely from cached
/// zoom-independent world coordinates — bit-identical to
/// [TileManager.latLngToScreen] while skipping the per-vertex
/// trigonography.
class PolylinePainter extends CustomPainter {
  static const double _minCycle = 1.0;
  static const double _minSpacing = 1.0;

  /// Debug/test instrumentation: segments appended to solid stroked paths.
  /// Culling keeps only the segments whose bounding boxes can intersect the
  /// stroke-inflated viewport, so a mostly offscreen route appends far
  /// fewer than its vertex count.
  static int debugSolidSegments = 0;

  final List<MapPolyline> polylines;
  final TileManager manager;
  final ShapeGeometryCache? cache;

  PolylinePainter({
    required this.polylines,
    required this.manager,
    this.cache,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final camera = cache == null ? null : ShapeCamera.of(manager);

    for (final polyline in polylines) {
      if (polyline.points.length < 2) continue;
      if (!polyline.strokeWidth.isFinite || polyline.strokeWidth <= 0) continue;
      if (!polyline.strokeMiterLimit.isFinite ||
          polyline.strokeMiterLimit <= 0) {
        continue;
      }

      final projected =
          GeometryTrace.sync('project', () => _project(polyline, camera));
      final xs = projected.$1;
      final ys = projected.$2;
      switch (polyline.pattern) {
        case SolidMapPolylinePattern _:
          final path = GeometryTrace.sync(
              'path', () => _solidPath(polyline, xs, ys, size));
          GeometryTrace.sync(
              'paint', () => _drawStroke(canvas, polyline, path));
        case DashedMapPolylinePattern pattern:
          final path = GeometryTrace.sync(
              'path', () => _dashedPath(polyline, xs, ys, pattern, size));
          if (path != null) {
            GeometryTrace.sync(
                'paint', () => _drawStroke(canvas, polyline, path));
          }
        case DottedMapPolylinePattern pattern:
          final centers = GeometryTrace.sync(
              'path', () => _dottedCenters(polyline, xs, ys, pattern, size));
          if (centers != null) {
            GeometryTrace.sync(
                'paint', () => _drawDots(canvas, polyline, centers));
          }
      }
    }

    canvas.restore();
  }

  /// Projects every vertex to screen X/Y arrays.
  (Float64List, Float64List) _project(
      MapPolyline polyline, ShapeCamera? camera) {
    final points = polyline.points;
    final count = points.length;
    final xs = Float64List(count);
    final ys = Float64List(count);
    if (camera == null) {
      for (var i = 0; i < count; i++) {
        final offset = manager.latLngToScreen(points[i]);
        xs[i] = offset.dx;
        ys[i] = offset.dy;
      }
    } else {
      final ring = cache!.ring(points);
      final nx = ring.nx;
      final ny = ring.ny;
      for (var i = 0; i < count; i++) {
        xs[i] = camera.screenX(nx[i]);
        ys[i] = camera.screenY(ny[i]);
      }
    }
    return (xs, ys);
  }

  /// Solid stroked path. Segments whose bounding box lies entirely outside
  /// the stroke-inflated viewport start new subpaths instead of being
  /// appended: their stroke (including joins/caps at the shared vertices)
  /// renders at least one logical pixel beyond the clip, so the visible
  /// result is pixel-identical to drawing the full path. Dash phase is
  /// unaffected — culling applies to solid routes only. (CanvasKit's
  /// rasterizer can shift anti-aliased coverage by sub-pixel amounts for
  /// split paths; no geometry appears or disappears — regression-tested.)
  Path _solidPath(
      MapPolyline polyline, Float64List xs, Float64List ys, Size size) {
    final path = Path();
    final canCull = size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0;
    if (canCull) {
      final inflation = _strokeCullInflation(polyline);
      final left = -inflation;
      final top = -inflation;
      final right = size.width + inflation;
      final bottom = size.height + inflation;
      var started = false;
      for (var i = 1; i < xs.length; i++) {
        final x0 = xs[i - 1];
        final y0 = ys[i - 1];
        final x1 = xs[i];
        final y1 = ys[i];
        final outside = (x0 < left && x1 < left) ||
            (x0 > right && x1 > right) ||
            (y0 < top && y1 < top) ||
            (y0 > bottom && y1 > bottom);
        if (outside) {
          started = false;
        } else {
          if (!started) {
            path.moveTo(x0, y0);
            started = true;
          }
          path.lineTo(x1, y1);
          debugSolidSegments++;
        }
      }
    } else {
      path.moveTo(xs[0], ys[0]);
      for (var i = 1; i < xs.length; i++) {
        path.lineTo(xs[i], ys[i]);
        debugSolidSegments++;
      }
    }
    return path;
  }

  /// Full unclosed path — dash/dot phase is anchored to the route start,
  /// so patterned routes never cull geometry from the measured path.
  Path _fullPath(Float64List xs, Float64List ys) {
    final path = Path()..moveTo(xs[0], ys[0]);
    for (var i = 1; i < xs.length; i++) {
      path.lineTo(xs[i], ys[i]);
    }
    return path;
  }

  Path? _dashedPath(MapPolyline polyline, Float64List xs, Float64List ys,
      DashedMapPolylinePattern pattern, Size size) {
    final cycle = pattern.dashLength + pattern.gapLength;
    if (!pattern.dashLength.isFinite ||
        pattern.dashLength <= 0 ||
        !pattern.gapLength.isFinite ||
        pattern.gapLength <= 0 ||
        !cycle.isFinite ||
        cycle < _minCycle ||
        !pattern.offset.isFinite) {
      return null;
    }

    final metricIterator = _fullPath(xs, ys).computeMetrics().iterator;
    if (!metricIterator.moveNext()) return null;
    final metric = metricIterator.current;
    if (!metric.length.isFinite || metric.length <= 0) return null;

    final ranges = _visibleDistanceRanges(
      xs,
      ys,
      size,
      _strokeCullInflation(polyline),
    );
    if (ranges.isEmpty) return null;

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
    return dashPath;
  }

  List<Offset>? _dottedCenters(MapPolyline polyline, Float64List xs,
      Float64List ys, DottedMapPolylinePattern pattern, Size size) {
    final spacing = pattern.spacing;
    if (!spacing.isFinite ||
        spacing < _minSpacing ||
        !pattern.offset.isFinite) {
      return null;
    }

    final borderExtension = polyline.borderColor != null &&
            polyline.borderWidth.isFinite &&
            polyline.borderWidth > 0
        ? polyline.borderWidth
        : 0.0;
    final borderRadius = polyline.strokeWidth / 2 + borderExtension;
    if (!borderRadius.isFinite) return null;

    final metricIterator = _fullPath(xs, ys).computeMetrics().iterator;
    if (!metricIterator.moveNext()) return null;
    final metric = metricIterator.current;
    if (!metric.length.isFinite || metric.length <= 0) return null;

    final ranges = _visibleDistanceRanges(
      xs,
      ys,
      size,
      borderRadius + 1,
    );
    if (ranges.isEmpty) return null;

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

    if (centers.isEmpty) return null;
    return centers;
  }

  void _drawStroke(Canvas canvas, MapPolyline polyline, Path path) {
    final borderPaint = _borderPaint(polyline);
    if (borderPaint != null) {
      canvas.drawPath(path, borderPaint);
    }
    canvas.drawPath(path, _mainPaint(polyline));
  }

  void _drawDots(Canvas canvas, MapPolyline polyline, List<Offset> centers) {
    final borderExtension = polyline.borderColor != null &&
            polyline.borderWidth.isFinite &&
            polyline.borderWidth > 0
        ? polyline.borderWidth
        : 0.0;
    if (borderExtension > 0) {
      final borderPaint = _fillPaint(polyline.borderColor!);
      final borderRadius = polyline.strokeWidth / 2 + borderExtension;
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
    Float64List xs,
    Float64List ys,
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

    for (var i = 1; i < xs.length; i++) {
      final startX = xs[i - 1];
      final startY = ys[i - 1];
      final endX = xs[i];
      final endY = ys[i];
      if (!startX.isFinite ||
          !startY.isFinite ||
          !endX.isFinite ||
          !endY.isFinite) {
        return const [];
      }

      final dx = endX - startX;
      final dy = endY - startY;
      final segmentLength = math.sqrt(dx * dx + dy * dy);
      if (!segmentLength.isFinite) return const [];
      if (segmentLength <= 0) continue;

      final clipped = _clipSegment(startX, startY, endX, endY, viewport);
      if (clipped != null) {
        final visibleStart = cumulativeDistance + clipped.$1 * segmentLength;
        final visibleEnd = cumulativeDistance + clipped.$2 * segmentLength;
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

  (double, double)? _clipSegment(
      double startX, double startY, double endX, double endY, Rect rect) {
    final dx = endX - startX;
    final dy = endY - startY;
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

    if (!clip(-dx, startX - rect.left) ||
        !clip(dx, rect.right - startX) ||
        !clip(-dy, startY - rect.top) ||
        !clip(dy, rect.bottom - startY)) {
      return null;
    }
    return (lower, upper);
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

class _DistanceRange {
  final double start;
  final double end;

  const _DistanceRange(this.start, this.end);
}
