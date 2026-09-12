import 'package:fosm/src/common/osm_transformation_utilities.dart'
    show maxWebMercatorLatitude;

import 'geo_point.dart';

/// An axis-aligned geographic bounding box in Web Mercator tile space.
///
/// Coordinates must be finite, within the Web Mercator latitude range and
/// within `[-180, 180]` longitude. Boxes crossing the antimeridian are not
/// supported.
class LatLngBounds {
  final LatLng southwest;
  final LatLng northeast;

  /// Debug assertions validate every construction. The constructor is
  /// intentionally not `const` because constant constructors cannot
  /// dereference parameters in assertions.
  LatLngBounds({required this.southwest, required this.northeast})
      : assert(southwest.latitude >= -maxWebMercatorLatitude),
        assert(southwest.latitude <= maxWebMercatorLatitude),
        assert(northeast.latitude >= -maxWebMercatorLatitude),
        assert(northeast.latitude <= maxWebMercatorLatitude),
        assert(southwest.longitude >= -180),
        assert(southwest.longitude <= 180),
        assert(northeast.longitude >= -180),
        assert(northeast.longitude <= 180),
        assert(southwest.latitude <= northeast.latitude),
        assert(southwest.longitude <= northeast.longitude);

  /// Smallest box containing every point in [points].
  ///
  /// Throws [ArgumentError] if [points] is empty or contains a coordinate
  /// outside the Web Mercator range.
  factory LatLngBounds.fromPoints(Iterable<LatLng> points) {
    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    var minLng = double.infinity;
    var maxLng = double.negativeInfinity;
    var hasPoints = false;
    for (final point in points) {
      hasPoints = true;
      _validatePoint(point);
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }
    if (!hasPoints) {
      throw ArgumentError(
          'LatLngBounds.fromPoints requires at least one point');
    }
    return LatLngBounds(
      southwest: LatLng(latitude: minLat, longitude: minLng),
      northeast: LatLng(latitude: maxLat, longitude: maxLng),
    );
  }

  static void _validatePoint(LatLng point) {
    if (!point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude < -maxWebMercatorLatitude ||
        point.latitude > maxWebMercatorLatitude ||
        point.longitude < -180 ||
        point.longitude > 180) {
      throw ArgumentError.value(
        point,
        'points',
        'Coordinates must be finite and within the Web Mercator range',
      );
    }
  }

  double get west => southwest.longitude;
  double get south => southwest.latitude;
  double get east => northeast.longitude;
  double get north => northeast.latitude;

  /// The box's center point.
  LatLng get center => LatLng(
        latitude: (south + north) / 2,
        longitude: (west + east) / 2,
      );

  /// Whether [point] lies inside (or on the edge of) this box.
  bool contains(LatLng point) =>
      point.latitude >= south &&
      point.latitude <= north &&
      point.longitude >= west &&
      point.longitude <= east;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LatLngBounds &&
        southwest == other.southwest &&
        northeast == other.northeast;
  }

  @override
  int get hashCode => Object.hash(southwest, northeast);
}
