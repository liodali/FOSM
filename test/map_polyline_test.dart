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
      expect(polyline.borderColor, isNull);
      expect(polyline.borderWidth, 0);
      expect(polyline.pattern, isA<SolidMapPolylinePattern>());
      expect(polyline.strokeCap, StrokeCap.round);
      expect(polyline.strokeJoin, StrokeJoin.round);
      expect(polyline.strokeMiterLimit, 4);
    });

    test('preserves custom styling', () {
      const polyline = MapPolyline(
        points: [],
        color: Colors.deepPurple,
        strokeWidth: 8.5,
        borderColor: Colors.white,
        borderWidth: 2,
        pattern: MapPolylinePattern.dashed(dashLength: 14, gapLength: 6),
        strokeCap: StrokeCap.square,
        strokeJoin: StrokeJoin.bevel,
        strokeMiterLimit: 6,
      );

      expect(polyline.color, Colors.deepPurple);
      expect(polyline.strokeWidth, 8.5);
      expect(polyline.borderColor, Colors.white);
      expect(polyline.borderWidth, 2);
      expect(polyline.pattern, isA<DashedMapPolylinePattern>());
      final pattern = polyline.pattern as DashedMapPolylinePattern;
      expect(pattern.dashLength, 14);
      expect(pattern.gapLength, 6);
      expect(polyline.strokeCap, StrokeCap.square);
      expect(polyline.strokeJoin, StrokeJoin.bevel);
      expect(polyline.strokeMiterLimit, 6);
    });

    test('preserves dotted pattern', () {
      const polyline = MapPolyline(
        points: [],
        pattern: MapPolylinePattern.dotted(spacing: 8, offset: 3),
      );

      expect(polyline.pattern, isA<DottedMapPolylinePattern>());
      final pattern = polyline.pattern as DottedMapPolylinePattern;
      expect(pattern.spacing, 8);
      expect(pattern.offset, 3);
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
      expect(
        () => MapPolyline(points: const [], strokeWidth: double.infinity),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(points: const [], strokeWidth: double.nan),
        throwsAssertionError,
      );
    });

    test('rejects invalid border widths', () {
      expect(
        () => MapPolyline(points: const [], borderWidth: -1),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(points: const [], borderWidth: double.infinity),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(points: const [], borderWidth: double.nan),
        throwsAssertionError,
      );
    });

    test('rejects overflowing outer stroke widths', () {
      expect(
        () => MapPolyline(
          points: const [],
          strokeWidth: double.maxFinite,
          borderWidth: double.maxFinite,
        ),
        throwsAssertionError,
      );
    });

    test('rejects invalid miter limits', () {
      expect(
        () => MapPolyline(points: const [], strokeMiterLimit: 0),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(points: const [], strokeMiterLimit: -2),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(points: const [], strokeMiterLimit: double.infinity),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(points: const [], strokeMiterLimit: double.nan),
        throwsAssertionError,
      );
    });

    test('rejects invalid dashed pattern values', () {
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(dashLength: 0),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(
            dashLength: 0.4,
            gapLength: 0.4,
          ),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(dashLength: double.infinity),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(dashLength: double.nan),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(gapLength: -1),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(gapLength: double.infinity),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(gapLength: double.nan),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(
            dashLength: double.maxFinite,
            gapLength: double.maxFinite,
          ),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(
            offset: double.negativeInfinity,
          ),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(
            offset: double.infinity,
          ),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dashed(
            offset: double.nan,
          ),
        ),
        throwsAssertionError,
      );
    });

    test('rejects invalid dotted pattern values', () {
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dotted(spacing: 0),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dotted(spacing: 0.5),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dotted(spacing: double.infinity),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dotted(spacing: double.nan),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dotted(offset: double.infinity),
        ),
        throwsAssertionError,
      );
      expect(
        () => MapPolyline(
          points: const [],
          pattern: MapPolylinePattern.dotted(offset: double.nan),
        ),
        throwsAssertionError,
      );
    });

    test('accepts negative finite pattern offsets', () {
      expect(
        () => const MapPolyline(
          points: [],
          pattern: MapPolylinePattern.dashed(offset: -4),
        ),
        returnsNormally,
      );
      expect(
        () => const MapPolyline(
          points: [],
          pattern: MapPolylinePattern.dotted(offset: -4),
        ),
        returnsNormally,
      );
    });
  });
}
