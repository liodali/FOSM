import 'dart:math' as math;

double lat2TileY(double lat, int z) {
  final alpha = (math.pi ~/ 180);
  return (1 -
          (math.log(math.tan(lat * alpha) + (1 / math.cos(lat * alpha))) /
              math.pi)) *
      math.pow(2, z - 1);
}

double lon2TileX(double lon, int z) {
  return ((lon + 180) / 360) * math.pow(2, z);
}

double tileY2Lat(double y, int z) {
  return (math
          .atan(math.asin(math.pi - ((y / math.pow(2, z)) * 2 * math.pi)))) *
      (180 / math.pi);
}

/// transform pixel x to longitude ref (#https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames#Coordinates_to_tile_numbers_2)
/// [x] : point in screen
/// [z] : zoom level
double tileX2Lng(double x, int z) {
  return ((x / math.pow(2, z)) * 360) - 180;
}
