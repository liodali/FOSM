import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

void main() {
  group('MapPolyline', () {
    test('uses the documented defaults and preserves the point list', () {
      final points = <LatLng>[
        const LatLng(latitude: 47.3769, longitude: 8.5417),
        const LatLng(latitude: 47.3811, longitude: 8.5524),
      ];

      final polyline = MapPolyline(points: points);

      expect(polyline.points, same(points));
      expect(polyline.color, const Color(0xFF1976D2));
      expect(polyline.strokeWidth, 5);
    });

    test('preserves custom styling', () {
      const polyline = MapPolyline(
        points: [],
        color: Colors.deepPurple,
        strokeWidth: 8.5,
      );

      expect(polyline.color, Colors.deepPurple);
      expect(polyline.strokeWidth, 8.5);
    });

    test('accepts empty and one-point inputs', () {
      expect(
        () => const MapPolyline(points: []),
        returnsNormally,
      );
      expect(
        () => const MapPolyline(
          points: [LatLng(latitude: 0, longitude: 0)],
        ),
        returnsNormally,
      );
    });

    test('rejects non-positive stroke widths', () {
      expect(
        () => MapPolyline(points: const [], strokeWidth: 0),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(points: const [], strokeWidth: -1),
        throwsAssertionError,
      );
    });
  });
}
