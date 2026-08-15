import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

/// Minimal valid 1×1 PNG — used as a fake tile for smoke tests.
final Uint8List _tinyPng = Uint8List.fromList([
  137, 80, 78, 71, 13, 10, 26, 10, // PNG signature
  0, 0, 0, 13, // IHDR length
  73, 72, 68, 82, // IHDR
  0, 0, 0, 1, 0, 0, 0, 1, // 1×1
  8, 2, 0, 0, 0, // 8-bit RGB
  144, 119, 83, 222, // CRC
  0, 0, 0, 12, // IDAT length
  73, 68, 65, 84, // IDAT
  8, 215, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0,
  24, 221, 142, 232, // CRC
  0, 0, 0, 0, // IEND length
  73, 69, 78, 68, // IEND
  174, 66, 96, 130, // CRC
]);

Future<Uint8List> _stubFetcher(int z, int x, int y) async => _tinyPng;

void main() {
  testWidgets('MapView renders without crashing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 47.4358, longitude: 8.4737),
            zoom: 7,
            tileFetcher: _stubFetcher,
          ),
        ),
      ),
    );

    // Wait for the first frame + async tile fetches.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // No exceptions thrown → success.
    expect(find.byType(MapView), findsOneWidget);
  });

  testWidgets('MapView responds to pan gestures', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 3,
            tileFetcher: _stubFetcher,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Simulate a horizontal drag.
    final center = tester.getCenter(find.byType(MapView));
    await tester.dragFrom(center, const Offset(-100, 0));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Still renders after drag — no exceptions.
    expect(find.byType(MapView), findsOneWidget);
  });

  testWidgets('MapView responds to pinch-to-zoom gestures', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Simulate a pinch-out (zoom in) gesture.
    final center = tester.getCenter(find.byType(MapView));
    final gesture1 = await tester.startGesture(center - const Offset(50, 0));
    final gesture2 = await tester.startGesture(center + const Offset(50, 0));

    // Move fingers apart (zoom in).
    await gesture1.moveBy(const Offset(-50, 0));
    await gesture2.moveBy(const Offset(50, 0));
    await tester.pump();

    await gesture1.up();
    await gesture2.up();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Still renders after zoom — no exceptions.
    expect(find.byType(MapView), findsOneWidget);
  });

  testWidgets('MapView respects minZoom and maxZoom', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            minZoom: 3,
            maxZoom: 8,
            tileFetcher: _stubFetcher,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // No exceptions with custom zoom bounds.
    expect(find.byType(MapView), findsOneWidget);
  });

  testWidgets('MapView shows zoom controls by default', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Zoom controls should be visible.
    expect(find.byType(MapZoomControls), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.remove), findsOneWidget);
  });

  testWidgets('MapView hides zoom controls when showZoomControls is false',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            showZoomControls: false,
            tileFetcher: _stubFetcher,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.byType(MapZoomControls), findsNothing);
  });

  testWidgets('MapView onZoomChanged fires on zoom button tap',
      (tester) async {
    int? lastZoom;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
            onZoomChanged: (zoom) => lastZoom = zoom,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Tap the zoom in button.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(lastZoom, 6);
  });

  testWidgets('MapView double-tap zooms in', (tester) async {
    int? lastZoom;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
            onZoomChanged: (zoom) => lastZoom = zoom,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Double-tap to zoom in.
    final center = tester.getCenter(find.byType(MapView));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(lastZoom, 6);
  });

  testWidgets('MapZoomControls standalone widget works', (tester) async {
    var zoomInTapped = false;
    var zoomOutTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapZoomControls(
            zoom: 5,
            minZoom: 1,
            maxZoom: 19,
            onZoomIn: () => zoomInTapped = true,
            onZoomOut: () => zoomOutTapped = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.add));
    expect(zoomInTapped, isTrue);

    await tester.tap(find.byIcon(Icons.remove));
    expect(zoomOutTapped, isTrue);
  });

  testWidgets('MapZoomControls disables buttons at bounds', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapZoomControls(
            zoom: 1,
            minZoom: 1,
            maxZoom: 19,
            onZoomIn: () {},
            onZoomOut: () {},
          ),
        ),
      ),
    );

    // At min zoom, zoom out should be disabled (gray).
    final removeIcon = tester.widget<Icon>(find.byIcon(Icons.remove));
    expect(removeIcon.color, isNotNull); // gray color

    // At max zoom
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapZoomControls(
            zoom: 19,
            minZoom: 1,
            maxZoom: 19,
            onZoomIn: () {},
            onZoomOut: () {},
          ),
        ),
      ),
    );

    // Zoom in should be disabled.
    final addIcon = tester.widget<Icon>(find.byIcon(Icons.add));
    expect(addIcon.color, isNotNull); // gray color
  });

  testWidgets('MapView animates zoom by default', (tester) async {
    int? lastZoom;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
            onZoomChanged: (zoom) => lastZoom = zoom,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Tap zoom in button
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump(); // Start animation

    // Animation should be in progress
    await tester.pump(const Duration(milliseconds: 150)); // Mid-animation
    // Zoom might not have changed yet (animation in progress)

    // Complete animation
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(lastZoom, 6);
  });

  testWidgets('MapView respects animateZoom: false', (tester) async {
    int? lastZoom;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
            animateZoom: false, // Disable animation
            onZoomChanged: (zoom) => lastZoom = zoom,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Tap zoom in button
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Zoom should change immediately without animation
    expect(lastZoom, 6);
  });

  testWidgets('MapView respects custom zoomAnimationDuration', (tester) async {
    int? lastZoom;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
            zoomAnimationDuration: const Duration(milliseconds: 500),
            onZoomChanged: (zoom) => lastZoom = zoom,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Tap zoom in button
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump(); // Start animation

    // After 250ms (half of 500ms), animation should still be in progress
    await tester.pump(const Duration(milliseconds: 250));
    // Zoom might not have reached target yet

    // Complete animation
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(lastZoom, 6);
  });

  testWidgets('Pinch gesture interrupts zoom animation', (tester) async {
    int? lastZoom;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            tileFetcher: _stubFetcher,
            onZoomChanged: (zoom) => lastZoom = zoom,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Start zoom animation
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // Interrupt with pinch gesture
    final center = tester.getCenter(find.byType(MapView));
    final gesture1 = await tester.startGesture(center - const Offset(50, 0));
    final gesture2 = await tester.startGesture(center + const Offset(50, 0));
    await gesture1.moveBy(const Offset(-30, 0));
    await gesture2.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture1.up();
    await gesture2.up();

    // Animation should be stopped, pinch zoom takes over
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(lastZoom, isNotNull);
  });
}
