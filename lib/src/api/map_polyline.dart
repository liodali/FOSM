import 'dart:ui';

import 'package:fosm/src/api/geo_point.dart';

/// A styled line whose vertices are geographic coordinates.
///
/// FOSM renders decoded points only — fetching a route from a routing
/// provider and decoding its polyline response is the application's
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

  const MapPolyline({
    required this.points,
    this.color = const Color(0xFF1976D2),
    this.strokeWidth = 5,
  }) : assert(strokeWidth > 0);
}
