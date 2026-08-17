import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
import 'package:fosm/src/view/render.dart';

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

/// Longitude that projects to [pixels] east of the map center at [zoom].
double _lngAtPixelOffset(double pixels, int zoom) =>
    tileX2Lng(lon2TileX(0, zoom) + pixels / 256, zoom);

Widget _map({
  required ValueChanged<int> onZoomChanged,
  required void Function(LatLng center, int zoom) onCameraChanged,
  bool animateZoom = false,
  Duration zoomAnimationDuration = const Duration(milliseconds: 350),
}) {
  return MaterialApp(
    home: Scaffold(
      body: MapView(
        latLng: _center,
        zoom: _testZoom,
        tileFetcher: _stubFetcher,
        animateZoom: animateZoom,
        zoomAnimationDuration: zoomAnimationDuration,
        onZoomChanged: onZoomChanged,
        onCameraChanged: onCameraChanged,
      ),
    ),
  );
}

/// Number of tile-grid painters currently in the tree — 1 normally, 2
/// while the crossfade overlay (fading old grid) is alive.
Finder get _gridPainters => find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is RenderCanvasOSM,
    );

// ── Gesture choreography ─────────────────────────────────────────────────────
//
// The ScaleGestureRecognizer records its baseline span/focal when the
// gesture starts — the first pointer event whose span delta exceeds
// kPanSlop (~36px), with the baseline taken from that event's positions
// — not at pointer down. Each finger move is its own pointer event, so
// The recognizer starts on the first finger move whose span change
// exceeds kScaleSlop (18px): that event fires onScaleStart — with the
// baseline span/focal captured AFTER the move — and no update. Only the
// following moves fire onScaleUpdate. Tests therefore use ONE large
// symmetric move per finger: the first starts the gesture, the second
// completes the pinch with the focal exactly between the fingers and no
// intermediate pan events, so the zoom step fires at a known focal point.

/// Moves both fingers symmetrically by [dx] (g1 left, g2 right for a
/// spread; pass negative to pinch in) and pumps after the pair.
Future<void> _pair(
  WidgetTester tester,
  TestGesture g1,
  TestGesture g2,
  double dx,
) async {
  await g1.moveBy(Offset(-dx, 0));
  await g2.moveBy(Offset(dx, 0));
  await tester.pump();
}

void main() {
  group('pinch-to-zoom', () {
    testWidgets('zoom step anchors on the focal point', (tester) async {
      final zoomLog = <int>[];
      LatLng camera = _center;
      await tester.pumpWidget(_map(
        onZoomChanged: zoomLog.add,
        onCameraChanged: (center, zoom) => camera = center,
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Fingers around an OFF-CENTER focal (450, 300), span 100. One
      // large symmetric move per finger: g1's move starts the recognizer
      // (baseline span 175), g2's completes the pinch at span 250
      // (scale ≈ 1.43 → +1 zoom) with the focal back at exactly 450.
      final g1 = await tester.startGesture(const Offset(400, 300));
      final g2 = await tester.startGesture(const Offset(500, 300));
      await tester.pump(kPressTimeout);
      await _pair(tester, g1, g2, 75); // span 250 → zoom 4, focal 450
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(zoomLog, [4]);

      // The geo point under the focal (450, 300) before the step must
      // stay under it: the new center is that point's tile at zoom 4
      // minus 50px of tile space.
      final focalLng = _lngAtPixelOffset(50, _testZoom);
      final expectedCenterTile = lon2TileX(focalLng, 4) - 50 / 256;
      expect(
        camera.longitude,
        closeTo(tileX2Lng(expectedCenterTile, 4), 0.01),
      );
      expect(camera.latitude, closeTo(0, 0.01));

      await g1.up();
      await g2.up();
    });

    testWidgets('no teleport when fingers drift between zoom thresholds',
        (tester) async {
      final zoomLog = <int>[];
      LatLng camera = _center;
      await tester.pumpWidget(_map(
        onZoomChanged: zoomLog.add,
        onCameraChanged: (center, zoom) => camera = center,
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Fingers around the viewport center; focal stays (400, 300).
      // g1's move starts the recognizer (baseline span 175), g2's
      // completes the pinch at span 250 → +1 zoom at the exact focal.
      final g1 = await tester.startGesture(const Offset(350, 300));
      final g2 = await tester.startGesture(const Offset(450, 300));
      await tester.pump(kPressTimeout);
      await _pair(tester, g1, g2, 75); // span 250 → zoom 4
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(zoomLog, [4]);
      // Focal == viewport center → center geo must not move.
      expect(camera.longitude, closeTo(0, 0.01));

      // Drift both fingers 10px right WITHOUT changing the span — still
      // zoom 4, so this is pure pan. The camera must move by 10px of tile
      // space (10/256 tile ≈ 0.88° at zoom 4), not teleport.
      await g1.moveBy(const Offset(10, 0));
      await g2.moveBy(const Offset(10, 0));
      await tester.pump();
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(zoomLog, [4]); // no second zoom step
      expect(camera.longitude, closeTo(_lngAtPixelOffset(-10, 4), 0.05));
      expect(camera.latitude, closeTo(0, 0.01));

      await g1.up();
      await g2.up();
    });

    testWidgets('pinch-in steps the zoom down anchored at the focal',
        (tester) async {
      final zoomLog = <int>[];
      LatLng camera = _center;
      await tester.pumpWidget(_map(
        onZoomChanged: zoomLog.add,
        onCameraChanged: (center, zoom) => camera = center,
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Fingers wide around the center (span 200). g1's move starts the
      // recognizer (baseline span 125), g2's completes the pinch at
      // span 50 (scale 0.4 → −1 zoom) with the focal back at exactly 400.
      final g1 = await tester.startGesture(const Offset(300, 300));
      final g2 = await tester.startGesture(const Offset(500, 300));
      await tester.pump(kPressTimeout);
      await _pair(tester, g1, g2, -75); // span 50 → zoom 2
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(zoomLog, [2]);
      // Focal == viewport center → center geo stays put.
      expect(camera.longitude, closeTo(0, 0.01));

      await g1.up();
      await g2.up();
    });
  });

  group('pinch zoom animation', () {
    testWidgets('pinch steps play the crossfade (animateZoom config)',
        (tester) async {
      final zoomLog = <int>[];
      LatLng camera = _center;
      await tester.pumpWidget(_map(
        onZoomChanged: zoomLog.add,
        onCameraChanged: (center, zoom) => camera = center,
        animateZoom: true,
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(_gridPainters, findsOneWidget); // just the base grid

      final g1 = await tester.startGesture(const Offset(350, 300));
      final g2 = await tester.startGesture(const Offset(450, 300));
      await tester.pump(kPressTimeout);
      await g1.moveBy(const Offset(-75, 0)); // starts the recognizer
      await g2.moveBy(const Offset(75, 0)); // span 250 → zoom step
      await tester.pump(); // first animation frame

      expect(zoomLog, [4]);
      // Two grids mid-animation: the new zoom underneath + the old grid
      // scaling and fading out on top.
      expect(_gridPainters, findsNWidgets(2));

      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(_gridPainters, findsOneWidget); // overlay removed at the end
      // Zoom result identical to the non-animated path.
      expect(camera.longitude, closeTo(0, 0.01));

      await g1.up();
      await g2.up();
    });

    testWidgets('crossfade duration comes from zoomAnimationDuration',
        (tester) async {
      final zoomLog = <int>[];
      await tester.pumpWidget(_map(
        onZoomChanged: zoomLog.add,
        onCameraChanged: (center, zoom) {},
        animateZoom: true,
        zoomAnimationDuration: const Duration(milliseconds: 120),
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final g1 = await tester.startGesture(const Offset(350, 300));
      final g2 = await tester.startGesture(const Offset(450, 300));
      await tester.pump(kPressTimeout);
      await g1.moveBy(const Offset(-75, 0));
      await g2.moveBy(const Offset(75, 0));

      await tester.pump(const Duration(milliseconds: 60));
      expect(_gridPainters, findsNWidgets(2)); // still fading

      await tester.pump(const Duration(milliseconds: 80)); // 140ms total
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(_gridPainters, findsOneWidget);

      await g1.up();
      await g2.up();
    });

    testWidgets('fading old grid follows pans during the animation',
        (tester) async {
      final zoomLog = <int>[];
      await tester.pumpWidget(_map(
        onZoomChanged: zoomLog.add,
        onCameraChanged: (center, zoom) {},
        animateZoom: true,
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final g1 = await tester.startGesture(const Offset(350, 300));
      final g2 = await tester.startGesture(const Offset(450, 300));
      await tester.pump(kPressTimeout);
      await g1.moveBy(const Offset(-75, 0));
      await g2.moveBy(const Offset(75, 0)); // zoom step, crossfade starts

      // Drift both fingers 10px right — pans the map 10px while the old
      // grid is still fading: the overlay must shift with the content.
      await g1.moveBy(const Offset(10, 0));
      await g2.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 100));

      final overlay = find.descendant(
        of: find.byKey(const ValueKey('zoom-crossfade')),
        matching: find.byType(Transform),
      );
      expect(overlay, findsWidgets);
      final matrix = tester.widget<Transform>(overlay.first).transform;
      final translation = matrix.getTranslation();

      expect(translation.x, closeTo(10, 0.5));
      expect(translation.y, closeTo(0, 0.5));

      await tester.pumpAndSettle(const Duration(seconds: 1));
      await g1.up();
      await g2.up();
    });
  });
}
