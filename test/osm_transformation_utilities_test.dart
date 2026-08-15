import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';

void main() {
  group('lon2TileX', () {
    test('prime meridian maps to center tile at any zoom', () {
      expect(lon2TileX(0, 7), 64.0); // 2^6 = 64
      expect(lon2TileX(0, 0), 0.5);
      expect(lon2TileX(0, 1), 1.0);
    });

    test('known value: Zürich lon at z=7', () {
      // (8.4737324 + 180) / 360 * 128 ≈ 67.013
      expect(lon2TileX(8.4737324, 7), closeTo(67.013, 0.001));
    });

    test('antimeridian edges', () {
      expect(lon2TileX(-180, 7), 0.0);
      expect(lon2TileX(180, 7), 128.0);
    });
  });

  group('lat2TileY', () {
    test('equator maps to center tile at any zoom', () {
      expect(lat2TileY(0, 7), 64.0); // 2^6 = 64
      expect(lat2TileY(0, 0), 0.5);
    });

    test('known value: Zürich lat at z=7', () {
      // ≈ 44.79
      expect(lat2TileY(47.4358055, 7), closeTo(44.79, 0.05));
    });

    test('northern latitudes produce smaller Y (higher on screen)', () {
      final equator = lat2TileY(0, 7);
      final north = lat2TileY(60, 7);
      final south = lat2TileY(-60, 7);
      expect(north, lessThan(equator));
      expect(south, greaterThan(equator));
    });

    test('max latitude produces y near 0', () {
      expect(lat2TileY(maxWebMercatorLatitude, 7), closeTo(0.0, 0.01));
    });

    test('min latitude produces y near 2^z', () {
      expect(lat2TileY(-maxWebMercatorLatitude, 7), closeTo(128.0, 0.01));
    });
  });

  group('tileX2Lng', () {
    test('center tile maps to prime meridian', () {
      expect(tileX2Lng(64, 7), closeTo(0.0, 0.001));
    });

    test('round-trip with lon2TileX', () {
      for (final lon in <double>[-180, -90, -45, 0, 45, 90, 179.9]) {
        final x = lon2TileX(lon, 10);
        expect(tileX2Lng(x, 10), closeTo(lon, 0.001));
      }
    });
  });

  group('tileY2Lat', () {
    test('y=0 maps to max latitude', () {
      expect(tileY2Lat(0, 7), closeTo(maxWebMercatorLatitude, 0.01));
    });

    test('y=2^z maps to min latitude', () {
      expect(tileY2Lat(128, 7), closeTo(-maxWebMercatorLatitude, 0.01));
    });

    test('center maps to equator', () {
      expect(tileY2Lat(64, 7), closeTo(0.0, 0.001));
    });

    test('round-trip with lat2TileY', () {
      for (final lat in <double>[-85, -60, -45, 0, 30, 47.4358055, 60, 85]) {
        final y = lat2TileY(lat, 10);
        expect(tileY2Lat(y, 10), closeTo(lat, 0.001));
      }
    });
  });

  group('clamping', () {
    test('clampLatitude', () {
      expect(clampLatitude(90), maxWebMercatorLatitude);
      expect(clampLatitude(-90), -maxWebMercatorLatitude);
      expect(clampLatitude(45), 45);
    });

    test('clampLongitude', () {
      expect(clampLongitude(200), 180);
      expect(clampLongitude(-200), -180);
      expect(clampLongitude(45), 45);
    });
  });
}
