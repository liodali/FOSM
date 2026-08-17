import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';

// Test surface is 800×600 by default; the map fills it, so the viewport
// center is (400, 300).
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

/// Standard 40×40 tappable marker child.
const _markerChild = SizedBox(width: 40, height: 40, key: Key('marker'));

/// Standard 120×50 overlay widget.
Widget _overlayChild(String text) => Container(
      key: Key('overlay-$text'),
      width: 120,
      height: 50,
      color: Colors.white,
      child: Text(text),
    );

Future<void> _pumpMap(
  WidgetTester tester, {
  required MarkerManager markers,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MapView(
          latLng: _center,
          zoom: _testZoom,
          tileFetcher: _stubFetcher,
          markers: markers,
        ),
      ),
    ),
  );
}

/// Taps and waits past the double-tap disambiguation window so single-tap
/// recognizers resolve.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

void main() {
  group('MarkerManager overlay state', () {
    test('showOverlay shows, hideOverlay hides, listeners fire', () {
      final markers = MarkerManager();
      final marker = Marker(
        point: _center,
        child: const SizedBox(),
        overlayBuilder: (context) => _overlayChild('a'),
      );
      markers.add(marker);

      Marker? shown;
      Marker? hidden;
      markers.onOverlayShown = (m) => shown = m;
      markers.onOverlayHidden = (m) => hidden = m;

      expect(markers.showOverlay(marker), isTrue);
      expect(markers.overlayMarker, same(marker));
      expect(shown, same(marker));

      expect(markers.hideOverlay(), isTrue);
      expect(markers.overlayMarker, isNull);
      expect(hidden, same(marker));
      expect(markers.hideOverlay(), isFalse); // nothing open now
    });

    test('showOverlay replaces the previous overlay, firing both events', () {
      final markers = MarkerManager();
      final first = Marker(
        point: _center,
        child: const SizedBox(),
        overlayBuilder: (context) => _overlayChild('a'),
      );
      final second = Marker(
        point: _center,
        child: const SizedBox(),
        overlayBuilder: (context) => _overlayChild('b'),
      );
      markers.addAll([first, second]);

      final events = <String>[];
      markers.onOverlayShown = (m) => events.add('shown');
      markers.onOverlayHidden = (m) => events.add('hidden');

      markers.showOverlay(first);
      markers.showOverlay(second);

      expect(events, ['shown', 'hidden', 'shown']);
      expect(markers.overlayMarker, same(second));
    });

    test('showOverlay rejects markers without a builder or not in the list',
        () {
      final markers = MarkerManager();
      final plain = const Marker(point: _center, child: SizedBox());
      final orphan = Marker(
        point: _center,
        child: const SizedBox(),
        overlayBuilder: (context) => _overlayChild('x'),
      );

      expect(markers.showOverlay(plain), isFalse);
      expect(markers.showOverlay(orphan), isFalse);
      expect(markers.overlayMarker, isNull);
    });

    test('removing or clearing the overlay marker hides the overlay', () {
      final markers = MarkerManager();
      final marker = Marker(
        point: _center,
        child: const SizedBox(),
        overlayBuilder: (context) => _overlayChild('a'),
      );
      markers
        ..add(marker)
        ..showOverlay(marker);

      Marker? hidden;
      markers.onOverlayHidden = (m) => hidden = m;
      markers.remove(marker);
      expect(markers.overlayMarker, isNull);
      expect(hidden, same(marker));

      markers
        ..add(marker)
        ..showOverlay(marker);
      markers.clear();
      expect(markers.overlayMarker, isNull);
    });
  });

  group('Marker gestures', () {
    testWidgets('onTap fires when the marker is tapped', (tester) async {
      var taps = 0;
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            onTap: () => taps++,
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _tap(tester, find.byKey(const Key('marker')));
      expect(taps, 1);
    });

    testWidgets('onLongPress fires on long press', (tester) async {
      var presses = 0;
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            onLongPress: () => presses++,
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.longPress(find.byKey(const Key('marker')));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(presses, 1);
    });

    testWidgets('interactive markers show a hand cursor on hover',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            onTap: () {},
            child: _markerChild,
          ),
        )
        ..add(
          // Plain marker east of the interactive one, at screen (600, 300).
          Marker(
            point: LatLng(
              latitude: 0,
              longitude:
                  tileX2Lng(lon2TileX(0, _testZoom) + 200 / 256, _testZoom),
            ),
            child: const SizedBox(
              width: 40,
              height: 40,
              key: Key('plain-marker'),
            ),
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      addTearDown(mouse.removePointer);

      // Over the tappable marker: hand cursor.
      await mouse.addPointer(location: const Offset(400, 300));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );

      // Over the plain marker: default cursor.
      await mouse.moveTo(const Offset(600, 300));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.basic,
      );

      // Over the bare map: default cursor.
      await mouse.moveTo(const Offset(50, 50));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.basic,
      );
    });

    testWidgets('markers without callbacks do not consume map gestures',
        (tester) async {
      // Panning from a plain marker must still move the camera.
      final markers = MarkerManager()..add(const Marker(point: _center, child: _markerChild));
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final before = tester.getRect(find.byKey(const Key('marker')));
      await tester.dragFrom(before.center, const Offset(-100, 0));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final after = tester.getRect(find.byKey(const Key('marker')));
      expect(after.center.dx, closeTo(before.center.dx - 80, 0.5));
    });
  });

  group('Marker overlay', () {
    testWidgets('tap toggles the overlay; onTap still fires', (tester) async {
      var taps = 0;
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            onTap: () => taps++,
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _tap(tester, find.byKey(const Key('marker')));
      expect(taps, 1);
      expect(markers.overlayMarker, isNotNull);
      expect(find.byKey(const Key('overlay-info')), findsOneWidget);

      await _tap(tester, find.byKey(const Key('marker')));
      expect(markers.overlayMarker, isNull);
      expect(find.byKey(const Key('overlay-info')), findsNothing);
    });

    testWidgets('overlay anchors above the marker with the configured gap',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            alignment: Alignment.bottomCenter,
            overlayConfig: const MarkerOverlayConfig(
              animationDuration: Duration.zero,
              offset: Offset(0, 12),
            ),
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      markers.showOverlay(markers.markers.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final marker = tester.getRect(find.byKey(const Key('marker')));
      final overlay = tester.getRect(find.byKey(const Key('overlay-info')));

      // bottomCenter marker: its top edge is 40px above the anchor (300).
      // Overlay bottom sits 12px above the marker's top, horizontally
      // centered on it.
      expect(overlay.bottom, closeTo(marker.top - 12, 0.5));
      expect(overlay.center.dx, closeTo(marker.center.dx, 0.5));
    });

    testWidgets('overlay follows the marker when the camera pans',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            overlayConfig: const MarkerOverlayConfig(
              animationDuration: Duration.zero,
            ),
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      markers.showOverlay(markers.markers.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final before = tester.getRect(find.byKey(const Key('overlay-info')));
      final markerBefore = tester.getRect(find.byKey(const Key('marker')));

      // dragFrom away from the marker; first 20px are touch slop → -80px.
      await tester.dragFrom(const Offset(700, 300), const Offset(-100, 0));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final after = tester.getRect(find.byKey(const Key('overlay-info')));
      final markerAfter = tester.getRect(find.byKey(const Key('marker')));

      expect(after.center.dx, closeTo(before.center.dx - 80, 0.5));
      expect(after.top, closeTo(before.top, 0.5));
      // Still anchored: same gap to the marker as before the pan.
      expect(
        markerAfter.top - after.bottom,
        closeTo(markerBefore.top - before.bottom, 0.5),
      );
    });

    testWidgets('removeOnMove dismisses the overlay on pan', (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            overlayConfig: const MarkerOverlayConfig(
              removeOnMove: true,
              animationDuration: Duration.zero,
            ),
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      markers.showOverlay(markers.markers.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const Key('overlay-info')), findsOneWidget);

      await tester.dragFrom(const Offset(700, 300), const Offset(-100, 0));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('overlay-info')), findsNothing);
      expect(markers.overlayMarker, isNull);
    });

    testWidgets('removeOnMove also dismisses on zoom changes', (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            overlayConfig: const MarkerOverlayConfig(
              removeOnMove: true,
              animationDuration: Duration.zero,
            ),
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      markers.showOverlay(markers.markers.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Double-tap to zoom in (animateZoom defaults on).
      await tester.tap(find.byKey(const Key('marker')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('marker')));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('overlay-info')), findsNothing);
    });

    testWidgets('tapping the bare map closes the overlay by default',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            overlayConfig: const MarkerOverlayConfig(
              animationDuration: Duration.zero,
            ),
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      markers.showOverlay(markers.markers.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tapAt(const Offset(50, 50));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('overlay-info')), findsNothing);
    });

    testWidgets('closeOnMapTap: false keeps the overlay on map taps',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            overlayConfig: const MarkerOverlayConfig(
              closeOnMapTap: false,
              animationDuration: Duration.zero,
            ),
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      markers.showOverlay(markers.markers.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tapAt(const Offset(50, 50));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('overlay-info')), findsOneWidget);
    });

    testWidgets('taps inside the overlay do not dismiss it', (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            overlayConfig: const MarkerOverlayConfig(
              animationDuration: Duration.zero,
            ),
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      markers.showOverlay(markers.markers.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byKey(const Key('overlay-info')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('overlay-info')), findsOneWidget);
    });

    testWidgets('entrance animation fades the overlay in', (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            // Default 200ms animation.
            overlayBuilder: (context) => _overlayChild('info'),
            child: _markerChild,
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      markers.showOverlay(markers.markers.first);
      await tester.pump();

      // Nearest FadeTransition ancestor — MaterialApp adds its own above.
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(const Key('overlay-info')),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, lessThan(1.0));

      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(fade.opacity.value, 1.0);
    });

    testWidgets('programmatic showOverlay right after add renders',
        (tester) async {
      final marker = Marker(
        point: _center,
        overlayConfig: const MarkerOverlayConfig(
          animationDuration: Duration.zero,
        ),
        overlayBuilder: (context) => _overlayChild('info'),
        child: _markerChild,
      );
      final markers = MarkerManager()..add(marker)..showOverlay(marker);

      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('overlay-info')), findsOneWidget);
    });
  });
}
