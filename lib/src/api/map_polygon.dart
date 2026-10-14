import 'dart:ui';

import 'geo_point.dart';

/// A filled geographic ring with optional cut-out rings. Rings close
/// automatically; fewer than three points paint nothing. Coordinates follow
/// the marker/polyline Web Mercator contract. Date-line wrapping is unsupported.
/// Replace lists and rebuild when geometry changes.
class MapPolygon {
  const MapPolygon({
    required this.points,
    this.holes = const [],
    this.color = const Color(0x401976D2),
    this.borderColor = const Color(0xFF1976D2),
    this.borderWidth = 2,
    this.interactive = false,
    this.hitTolerance = 4,
    this.onTap,
    this.onLongPress,
  })  : assert(borderWidth >= 0 && borderWidth < double.infinity),
        assert(hitTolerance >= 0 && hitTolerance < double.infinity);

  final List<LatLng> points;

  /// Cut-out rings, expected to be disjoint and contained by the outer ring.
  /// Winding direction is irrelevant because the fill uses even-odd parity.
  final List<List<LatLng>> holes;
  final Color color;
  final Color borderColor;
  final double borderWidth;

  /// Enables notifications without requiring callbacks. Callbacks also enable
  /// hit testing for their respective gestures. Default polygons are decorative.
  final bool interactive;
  final double hitTolerance;
  final void Function(MapPolygonHit hit)? onTap;
  final void Function(MapPolygonHit hit)? onLongPress;
}

class MapPolygonHit {
  const MapPolygonHit({required this.polygon, required this.point});
  final MapPolygon polygon;
  final LatLng point;
}
