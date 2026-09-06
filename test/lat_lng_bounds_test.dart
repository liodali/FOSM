import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/lat_lng_bounds.dart';

void main() {
  group('LatLngBounds.fromPoints', () {
    test('computes the min/max box and center', () {
      final bounds = LatLngBounds.fromPoints(const [
        LatLng(latitude: 47.4, longitude: 8.5),
        LatLng(latitude: 48.1, longitude: 11.6),
        LatLng(latitude: 46.9, longitude: 9.2),
      ]);

      expect(bounds.south, 46.9);
      expect(bounds.north, 48.1);
      expect(bounds.west, 8.5);
      expect(bounds.east, 11.6);
      expect(bounds.center.latitude, closeTo(47.5, 1e-9));
      expect(bounds.center.longitude, closeTo(10.05, 1e-9));
    });

    test('works with a single point', () {
      const point = LatLng(latitude: 10, longitude: 20);
      final bounds = LatLngBounds.fromPoints([point]);

      expect(bounds.southwest, point);
      expect(bounds.northeast, point);
      expect(bounds.center, point);
    });

    test('throws on empty input', () {
      expect(() => LatLngBounds.fromPoints(const []), throwsArgumentError);
    });

    test('rejects non-finite and out-of-range coordinates', () {
      expect(
        () => LatLngBounds.fromPoints(
          const [LatLng(latitude: double.nan, longitude: 0)],
        ),
        throwsArgumentError,
      );
      expect(
        () => LatLngBounds.fromPoints(
          const [LatLng(latitude: 86, longitude: 0)],
        ),
        throwsArgumentError,
      );
      expect(
        () => LatLngBounds.fromPoints(
          const [LatLng(latitude: 0, longitude: 181)],
        ),
        throwsArgumentError,
      );
    });
  });

  group('LatLngBounds constructor asserts', () {
    test('constructs with valid corners', () {
      final bounds = LatLngBounds(
        southwest: const LatLng(latitude: -10, longitude: -20),
        northeast: const LatLng(latitude: 10, longitude: 20),
      );

      expect(bounds.center, const LatLng(latitude: 0, longitude: 0));
    });

    test('rejects inverted latitude corners', () {
      expect(
        () => LatLngBounds(
          southwest: const LatLng(latitude: 10, longitude: 0),
          northeast: const LatLng(latitude: -10, longitude: 5),
        ),
        throwsAssertionError,
      );
    });

    test('rejects inverted longitude corners', () {
      expect(
        () => LatLngBounds(
          southwest: const LatLng(latitude: 0, longitude: 20),
          northeast: const LatLng(latitude: 10, longitude: -20),
        ),
        throwsAssertionError,
      );
    });

    test('rejects coordinates outside the Web Mercator range', () {
      expect(
        () => LatLngBounds(
          southwest: const LatLng(latitude: -86, longitude: 0),
          northeast: const LatLng(latitude: 10, longitude: 20),
        ),
        throwsAssertionError,
      );
      expect(
        () => LatLngBounds(
          southwest: const LatLng(latitude: -10, longitude: 0),
          northeast: const LatLng(latitude: 10, longitude: 181),
        ),
        throwsAssertionError,
      );
    });
  });

  group('LatLngBounds.contains', () {
    test('accepts points inside and on the edges', () {
      final bounds = LatLngBounds(
        southwest: const LatLng(latitude: -10, longitude: -20),
        northeast: const LatLng(latitude: 10, longitude: 20),
      );

      expect(bounds.contains(const LatLng(latitude: 0, longitude: 0)), isTrue);
      expect(
        bounds.contains(const LatLng(latitude: -10, longitude: -20)),
        isTrue,
      );
      expect(
          bounds.contains(const LatLng(latitude: 10, longitude: 20)), isTrue);
    });

    test('rejects points outside', () {
      final bounds = LatLngBounds(
        southwest: const LatLng(latitude: -10, longitude: -20),
        northeast: const LatLng(latitude: 10, longitude: 20),
      );

      expect(
        bounds.contains(const LatLng(latitude: 11, longitude: 0)),
        isFalse,
      );
      expect(
        bounds.contains(const LatLng(latitude: 0, longitude: -21)),
        isFalse,
      );
    });
  });

  group('LatLngBounds equality', () {
    test('equal boxes are == and share hashCode', () {
      final a = LatLngBounds(
        southwest: const LatLng(latitude: 1, longitude: 2),
        northeast: const LatLng(latitude: 3, longitude: 4),
      );
      final b = LatLngBounds(
        southwest: const LatLng(latitude: 1, longitude: 2),
        northeast: const LatLng(latitude: 3, longitude: 4),
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different boxes are not equal', () {
      final a = LatLngBounds(
        southwest: const LatLng(latitude: 1, longitude: 2),
        northeast: const LatLng(latitude: 3, longitude: 4),
      );
      final b = LatLngBounds(
        southwest: const LatLng(latitude: 1, longitude: 2),
        northeast: const LatLng(latitude: 3, longitude: 5),
      );

      expect(a, isNot(equals(b)));
    });
  });
}
