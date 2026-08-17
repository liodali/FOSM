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

/// Fast fetcher — tiles resolve via microtasks.
Future<Uint8List> _fastFetcher(int z, int x, int y) async => _tinyPng;

/// Slow fetcher — tiles take 2 seconds, keeping the wait phase active.
Future<Uint8List> _slowFetcher(int z, int x, int y) =>
    Future.delayed(const Duration(seconds: 2), () => _tinyPng);

Future<void> _pumpMap(
  WidgetTester tester, {
  required ValueChanged<int> onZoomChanged,
  bool animateZoom = true,
  ZoomAnimationStyle style = ZoomAnimationStyle.scale,
  TileFetcher? fetcher,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MapView(
          latLng: _center,
          zoom: _testZoom,
          tileFetcher: fetcher ?? _fastFetcher,
          animateZoom: animateZoom,
          zoomAnimationDuration: const Duration(milliseconds: 400),
          zoomAnimationStyle: style,
          onZoomChanged: onZoomChanged,
        ),
      ),
    ),
  );
}

/// All Transform widgets inside the old-grid overlay, outermost first.
Finder _overlayTransforms() => find.descendant(
      of: find.byKey(const ValueKey('zoom-scale')),
      matching: find.byType(Transform),
    );

/// ImageFiltered widgets inside the old-grid overlay (blur).
Finder _overlayBlurs() => find.descendant(
      of: find.byKey(const ValueKey('zoom-scale')),
      matching: find.byType(ImageFiltered),
    );

void main() {
  group('Two-phase zoom animation', () {
    testWidgets('scale: wait phase shows blurred overlay while tiles load',
        (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(
        tester,
        onZoomChanged: zoomLog.add,
        fetcher: _slowFetcher,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Trigger zoom-in via double-tap.
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      // Advance a small amount — tiles still loading (2s fetcher).
      await tester.pump(const Duration(milliseconds: 50));

      expect(zoomLog, [4]);
      // Overlay present in wait phase.
      expect(find.byKey(const ValueKey('zoom-scale')), findsOneWidget);
      // Blur is applied.
      expect(_overlayBlurs(), findsOneWidget);
      // Scale is 1.0 (static — waiting for tiles).
      final scale = tester.widget<Transform>(_overlayTransforms().last);
      expect(scale.transform.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

      // Drain everything: wait timeout (600ms) + scale animation (400ms)
      // + slow fetcher (2s).
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('zoom-scale')), findsNothing);
    });

    testWidgets('scale: fast fetcher skips wait, scale animates and removes',
        (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(tester, onZoomChanged: zoomLog.add);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      // Tiles load via microtasks → wait phase skipped → scale starts.
      await tester.pump(const Duration(milliseconds: 50));

      expect(zoomLog, [4]);
      // Overlay is present during the animation.
      expect(find.byKey(const ValueKey('zoom-scale')), findsOneWidget);
      // Blur is applied for both styles.
      expect(_overlayBlurs(), findsOneWidget);
      // translate + scale transforms present.
      expect(_overlayTransforms(), findsNWidgets(2));

      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('zoom-scale')), findsNothing);
    });

    testWidgets('crossfade: overlay has blur and scale, then cleans up',
        (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(
        tester,
        onZoomChanged: zoomLog.add,
        style: ZoomAnimationStyle.crossfade,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 150));

      expect(zoomLog, [4]);
      expect(find.byKey(const ValueKey('zoom-scale')), findsOneWidget);
      expect(_overlayBlurs(), findsOneWidget);
      expect(_overlayTransforms(), findsNWidgets(2));

      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('zoom-scale')), findsNothing);
    });

    testWidgets('crossfade: wait phase shows blurred overlay',
        (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(
        tester,
        onZoomChanged: zoomLog.add,
        style: ZoomAnimationStyle.crossfade,
        fetcher: _slowFetcher,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(zoomLog, [4]);
      expect(find.byKey(const ValueKey('zoom-scale')), findsOneWidget);
      expect(_overlayBlurs(), findsOneWidget);
      // Static (not scaling).
      final scale = tester.widget<Transform>(_overlayTransforms().last);
      expect(scale.transform.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

      // Drain everything.
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('zoom-scale')), findsNothing);
    });

    testWidgets('zoom-out via − button: overlay appears and cleans up',
        (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(tester, onZoomChanged: zoomLog.add);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 150));

      expect(zoomLog, [2]);
      expect(find.byKey(const ValueKey('zoom-scale')), findsOneWidget);
      expect(_overlayBlurs(), findsOneWidget);

      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('zoom-scale')), findsNothing);
    });

    testWidgets('animateZoom: false skips the overlay entirely',
        (tester) async {
      final zoomLog = <int>[];
      await _pumpMap(
        tester,
        onZoomChanged: zoomLog.add,
        animateZoom: false,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(zoomLog, [4]);
      expect(find.byKey(const ValueKey('zoom-scale')), findsNothing);
    });
  });
}
