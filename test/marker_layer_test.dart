import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';
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

/// Longitude that projects to [pixels] east of the map center at
/// [_testZoom] (longitude is linear in web mercator).
double _lngAtPixelOffset(double pixels) =>
    tileX2Lng(lon2TileX(0, _testZoom) + pixels / 256, _testZoom);

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

void main() {
  group('TileManager.latLngToScreen', () {
    test('projects the map center to the viewport center', () {
      final manager = TileManager.init(
        width: 800,
        height: 600,
        centerLatLng: _center,
        zoom: _testZoom,
        fetcher: _stubFetcher,
        preloadAdjacentZoom: false,
      );
      manager.calculate();

      expect(manager.latLngToScreen(_center), const Offset(400, 300));
      manager.dispose();
    });

    test('projects a known offset east of the center', () {
      final manager = TileManager.init(
        width: 800,
        height: 600,
        centerLatLng: _center,
        zoom: _testZoom,
        fetcher: _stubFetcher,
        preloadAdjacentZoom: false,
      );
      manager.calculate();

      // 2 tiles east of the center (positive x → right on screen).
      final point = LatLng(latitude: 0, longitude: _lngAtPixelOffset(512));
      final screen = manager.latLngToScreen(point);
      expect(screen.dx, closeTo(400 + 512, 0.001));
      expect(screen.dy, closeTo(300, 0.001));
      manager.dispose();
    });
  });

  group('MarkerLayer rendering', () {
    testWidgets('centered marker renders at the viewport center',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          const Marker(
            point: _center,
            child: SizedBox(width: 40, height: 40, key: Key('center-marker')),
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final rect = tester.getRect(find.byKey(const Key('center-marker')));
      // Alignment.center → the widget's center sits on the anchor point.
      expect(rect.center.dx, closeTo(400, 0.5));
      expect(rect.center.dy, closeTo(300, 0.5));
    });

    testWidgets('bottomCenter anchor pins the widget tip on the point',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          const Marker(
            point: _center,
            alignment: Alignment.bottomCenter,
            child: SizedBox(width: 40, height: 40, key: Key('pin-marker')),
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final rect = tester.getRect(find.byKey(const Key('pin-marker')));
      // The bottom-center of the widget sits on the anchor point.
      expect(rect.bottomCenter.dx, closeTo(400, 0.5));
      expect(rect.bottomCenter.dy, closeTo(300, 0.5));
    });

    testWidgets('marker follows the camera when the map is panned',
        (tester) async {
      final markers = MarkerManager()
        ..add(
          const Marker(
            point: _center,
            child: SizedBox(width: 40, height: 40, key: Key('drag-marker')),
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // dragFrom first sends a kDragSlopDefault (20px) move that the scale
      // recognizer consumes as touch slop, so a -100 drag pans by -80.
      // The marker must follow the camera by exactly that applied pan.
      await tester.dragFrom(const Offset(400, 300), const Offset(-100, 0));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final rect = tester.getRect(find.byKey(const Key('drag-marker')));
      expect(rect.center.dx, closeTo(320, 0.5));
      expect(rect.center.dy, closeTo(300, 0.5));
    });

    testWidgets('text marker renders its text', (tester) async {
      final markers = MarkerManager()
        ..add(Marker.text('hello', _center));
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('hello'), findsOneWidget);
    });
  });

  group('MarkerLayer viewport culling', () {
    testWidgets('markers far outside the viewport are skipped', (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: LatLng(latitude: 0, longitude: _lngAtPixelOffset(2000)),
            child: const SizedBox(
              width: 40,
              height: 40,
              key: Key('far-marker'),
            ),
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // 2000px east of center → 1600px beyond the right edge → culled,
      // the widget is not in the tree at all.
      expect(find.byKey(const Key('far-marker')), findsNothing);
    });

    testWidgets('markers within the cull margin stay in the tree',
        (tester) async {
      // 500px west of center → anchor at x = -100, inside the 256px
      // margin past the left edge → still laid out (clipped by the
      // viewport, but present).
      final markers = MarkerManager()
        ..add(
          Marker(
            point: LatLng(latitude: 0, longitude: _lngAtPixelOffset(-500)),
            child: const SizedBox(
              width: 40,
              height: 40,
              key: Key('edge-marker'),
            ),
          ),
        );
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final rect = tester.getRect(find.byKey(const Key('edge-marker')));
      expect(rect.center.dx, closeTo(-100, 0.5));
    });
  });

  group('MarkerManager live updates', () {
    testWidgets('adding and clearing markers updates the map', (tester) async {
      final markers = MarkerManager();
      await _pumpMap(tester, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('live'), findsNothing);

      markers.add(Marker.text('live', _center));
      await tester.pump();
      expect(find.text('live'), findsOneWidget);

      markers.clear();
      await tester.pump();
      expect(find.text('live'), findsNothing);
    });
  });
}
