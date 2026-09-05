import 'dart:ui';

import 'package:fosm/src/api/geo_point.dart';

/// A styled line whose vertices are geographic coordinates.
///
/// FOSM renders decoded points only — fetching a route from a routing
/// provider and decoding its encoded-polyline response is the application's
/// responsibility. Pass the decoded [LatLng] values as [points].
///
/// Consecutive points are drawn as straight segments in Web Mercator screen
/// space: for points `[A, B, C]` the layer draws segments `A -> B` and
/// `B -> C`. Zero- and one-point lists are valid transient states while a
/// route is loading and paint nothing.
///
/// The list is caller-owned widget configuration: replace it and rebuild
/// the parent when route data changes — mutating an existing list without a
/// rebuild is not supported.
///
/// Coordinates are expected to be finite and within valid map ranges; no
/// normalization is performed (the same convention markers follow).
///
/// ```dart
/// MapView(
///   latLng: routePoints.first,
///   zoom: 14,
///   polylines: [
///     MapPolyline(
///       points: routePoints,
///       color: Colors.blue,
///       strokeWidth: 5,
///     ),
///   ],
/// )
/// ```
class MapPolyline {
  /// Ordered route/line vertices.
  final List<LatLng> points;

  /// Stroke color, including its opacity.
  final Color color;

  /// Stroke width in logical pixels. It does not scale with map zoom.
  final double strokeWidth;

  /// Optional outer casing color. A border is only drawn when both this
  /// value is non-null and [borderWidth] is greater than zero.
  final Color? borderColor;

  /// Visible extension on each side of the main stroke in logical pixels.
  /// The total outer width is `strokeWidth + (2 * borderWidth)`.
  final double borderWidth;

  /// Stroke pattern: solid, dashed, or dotted.
  final MapPolylinePattern pattern;

  /// Cap style for stroke endpoints and dash endpoints.
  final StrokeCap strokeCap;

  /// Join style at route vertices.
  final StrokeJoin strokeJoin;

  /// Miter limit used when [strokeJoin] is [StrokeJoin.miter].
  final double strokeMiterLimit;

  const MapPolyline({
    required this.points,
    this.color = const Color(0xFF1976D2),
    this.strokeWidth = 5,
    this.borderColor,
    this.borderWidth = 0,
    this.pattern = const MapPolylinePattern.solid(),
    this.strokeCap = StrokeCap.round,
    this.strokeJoin = StrokeJoin.round,
    this.strokeMiterLimit = 4,
  })  : assert(strokeWidth > 0 && strokeWidth < double.infinity),
        assert(borderWidth >= 0 && borderWidth < double.infinity),
        assert(strokeWidth + 2 * borderWidth < double.infinity),
        assert(strokeMiterLimit > 0 && strokeMiterLimit < double.infinity);
}

/// Describes how a [MapPolyline] should be rendered.
///
/// Use the const factory constructors for concise call sites:
///
/// ```dart
/// const MapPolylinePattern.solid()
/// const MapPolylinePattern.dashed(dashLength: 14, gapLength: 8)
/// const MapPolylinePattern.dotted(spacing: 12)
/// ```
sealed class MapPolylinePattern {
  const MapPolylinePattern();

  const factory MapPolylinePattern.solid() = SolidMapPolylinePattern;

  const factory MapPolylinePattern.dashed({
    double dashLength,
    double gapLength,
    double offset,
  }) = DashedMapPolylinePattern;

  const factory MapPolylinePattern.dotted({
    double spacing,
    double offset,
  }) = DottedMapPolylinePattern;
}

/// Solid stroke pattern. This is the default.
final class SolidMapPolylinePattern extends MapPolylinePattern {
  const SolidMapPolylinePattern();
}

/// Dashed stroke pattern with fixed dash and gap lengths in logical pixels.
///
/// The combined dash-and-gap cycle must be at least one logical pixel.
final class DashedMapPolylinePattern extends MapPolylinePattern {
  final double dashLength;
  final double gapLength;

  /// Distance from the route start to the first dash, in logical pixels.
  /// Negative values are normalized into the pattern cycle.
  final double offset;

  const DashedMapPolylinePattern({
    this.dashLength = 12,
    this.gapLength = 8,
    this.offset = 0,
  })  : assert(dashLength > 0 && dashLength < double.infinity),
        assert(gapLength > 0 && gapLength < double.infinity),
        assert(dashLength + gapLength >= 1 &&
            dashLength + gapLength < double.infinity),
        assert(offset > -double.infinity && offset < double.infinity);
}

/// Dotted stroke pattern with fixed center-to-center spacing in logical pixels.
final class DottedMapPolylinePattern extends MapPolylinePattern {
  /// Center-to-center distance between dots, in logical pixels.
  /// Must be at least one logical pixel.
  final double spacing;

  /// Distance from the route start to the first dot, in logical pixels.
  /// Negative values are normalized into the pattern cycle.
  final double offset;

  const DottedMapPolylinePattern({
    this.spacing = 10,
    this.offset = 0,
  })  : assert(spacing >= 1 && spacing < double.infinity),
        assert(offset > -double.infinity && offset < double.infinity);
}
