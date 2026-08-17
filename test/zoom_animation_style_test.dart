import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

// Test surface is 800×600 by default; the viewport center is (400, 300).
const _center = LatLng(latitude: 0, longitude: 0);
const _testZoom = 3;

/// Minimal valid 1×1 RGBA PNG — decodable by Flutter's image codec.
final Uint8List _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00,
  0x1F, 0x15, 0xC4, 0x89,
  0x00, 0x00, 0x00, 0x0A,
  0x49, 0x44, 0x41, 0x54,
  0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
  0x0D, 0x0A, 0x2D, 0xB4,
  0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82,
]);

Future<Uint8List> _stubFetcher(int z, int x, int y) async => _tinyPng;

Future<void> _pumpMap(
  WidgetTester tester, {
  required ZoomAnimationStyle style,
  required ValueChanged<int> onZoomChanged,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MapView(
          latLng: _center,
          zoom: _testZoom,
          tileFetcher: _stubFetcher,
          animateZoom: true,
          zoomAnimationDuration: const Duration(milliseconds: 400),
          zoomAnimationStyle: style,
          onZoomChanged: onZoomChanged,
        ),
      ),
    ),
  );
}

/// Double-taps the viewport center and advances ~150 ms into the zoom
/// animation — the old-grid overlay is alive and partway through.
Future<void> _doubleTapZoomIn(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 300));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(const Offset(400, 300));
  // First pump anchors the ticker at elapsed 0; the second advances into
  // the animation.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
}

/// All Transform widgets inside the old-grid overlay, outermost first.
Finder _overlayTransforms() => find.descendant(
      of: find.byKey(const ValueKey('zoom-crossfade')),
      matching: find.byType(Transform),
    );

void main() {
  group('ZoomAnimationStyle', () {
    testWidgets('crossfade scales the old grid around the focal point',
        (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(
        tester,
        style: ZoomAnimationStyle.crossfade,
        onZoomChanged: zoomLog.add,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _doubleTapZoomIn(tester);

      expect(zoomLog, [4]);
      expect(_overlayTransforms(), findsNWidgets(2)); // translate + scale

      final scale = tester.widget<Transform>(_overlayTransforms().last);
      // Zoom-in mid-animation: scaling up towards 2×.
      expect(scale.transform.getMaxScaleOnAxis(), greaterThan(1.1));

      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('zoom-crossfade')), findsNothing);
    });

    testWidgets('fade only changes opacity', (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(
        tester,
        style: ZoomAnimationStyle.fade,
        onZoomChanged: zoomLog.add,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _doubleTapZoomIn(tester);

      expect(zoomLog, [4]);
      // Just the shared pan-tracking translate — no scale transform.
      expect(_overlayTransforms(), findsOneWidget);
      final translate = tester.widget<Transform>(_overlayTransforms().first);
      expect(translate.transform.getTranslation().x, 0.0);
      expect(translate.transform.getMaxScaleOnAxis(), 1.0);

      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('zoom-crossfade')), findsNothing);
    });


  });
}
