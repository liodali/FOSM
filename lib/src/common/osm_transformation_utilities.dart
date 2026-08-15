import 'dart:math' as math;

/// Maximum latitude (degrees) representable by the Web Mercator projection.
/// Beyond this the projection degenerates (poles → infinity).
const double maxWebMercatorLatitude = 85.0511287798066;

double _degToRad(double deg) => deg * math.pi / 180;

/// OSM slippy-map: longitude (degrees) → fractional tile X at zoom [z].
///
/// See https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
double lon2TileX(double lon, int z) {
  return (lon + 180) / 360 * math.pow(2, z);
}

/// OSM slippy-map: latitude (degrees) → fractional tile Y at zoom [z].
///
/// **FIX**: previously used `math.pi ~/ 180` (integer division = 0), which
/// always returned `2^(z-1)` regardless of latitude — locking the vertical
/// center at the equator.
double lat2TileY(double lat, int z) {
  final phi = _degToRad(lat);
  return (1 - math.log(math.tan(phi) + 1 / math.cos(phi)) / math.pi) *
      math.pow(2, z - 1);
}

/// Fractional tile X → longitude (degrees).
double tileX2Lng(double x, int z) {
  return x / math.pow(2, z) * 360 - 180;
}

/// Fractional tile Y → latitude (degrees).
///
/// **FIX**: previously used `asin` whose domain is [-1, 1], but the argument
/// spans [-π, π] → NaN for most values. Correct function is `sinh`.
/// Dart's `dart:math` doesn't ship `sinh`, so we compute it inline.
double tileY2Lat(double y, int z) {
  final n = math.pi - (y / math.pow(2, z)) * 2 * math.pi;
  return math.atan(_sinh(n)) * 180 / math.pi;
}

/// Hyperbolic sine — `dart:math` doesn't provide this.
double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

/// Clamp latitude to the Web Mercator valid range.
double clampLatitude(double lat) =>
    lat.clamp(-maxWebMercatorLatitude, maxWebMercatorLatitude);

/// Clamp longitude to [-180, 180].
double clampLongitude(double lng) => lng.clamp(-180.0, 180.0);
