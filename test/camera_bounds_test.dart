import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

const _center = LatLng(latitude: 0, longitude: 0);
const _testZoom = 5;

/// Minimal valid 1×1 RGBA PNG — decodable by Flutter's image codec.
final Uint8List _tinyPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Future<Uint8List> _stubFetcher(int z, int x, int y) async => _tinyPng;

/// Larger than the 800×600 viewport at zoom 5 in both axes — the clamp
/// applies and centers the camera at ±62.42° longitude / ±43.96°
/// latitude.
final _bounds = LatLngBounds(
  southwest: const LatLng(latitude: -60, longitude: -80),
  northeast: const LatLng(latitude: 60, longitude: 80),
);

Widget _map({
  LatLngBounds? cameraBounds,
  void Function(LatLng center, int zoom)? onCameraChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MapView(
        latLng: _center,
        zoom: _testZoom,
        cameraBounds: cameraBounds,
        tileFetcher: _stubFetcher,
        animateZoom: false,
        onCameraChanged: onCameraChanged,
      ),
    ),
  );
}

void main() {
  testWidgets('drag cannot move the camera outside the bounds', (tester) async {
    LatLng camera = _center;
    await tester.pumpWidget(
      _map(cameraBounds: _bounds, onCameraChanged: (c, _) => camera = c),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Finger drags right → camera moves west; far past the box edge.
    await tester.drag(find.byType(MapView), const Offset(3000, 0));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(camera.longitude, closeTo(-62.42, 0.1));
    expect(_bounds.contains(camera), isTrue);

    // Finger drags left → camera moves east; far past the box edge.
    await tester.drag(find.byType(MapView), const Offset(-6000, 0));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(camera.longitude, closeTo(62.42, 0.1));

    // Finger drags up → camera moves south; past the box edge.
    await tester.drag(find.byType(MapView), const Offset(0, -3000));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(camera.latitude, closeTo(-52.72, 0.1));
    expect(_bounds.contains(camera), isTrue);

    // Finger drags down → camera moves north; past the box edge.
    await tester.drag(find.byType(MapView), const Offset(0, 6000));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(camera.latitude, closeTo(52.72, 0.1));
    expect(_bounds.contains(camera), isTrue);
  });

  testWidgets('rebuilding without bounds frees panning again', (tester) async {
    LatLng camera = _center;
    await tester.pumpWidget(
      _map(cameraBounds: _bounds, onCameraChanged: (c, _) => camera = c),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.pumpWidget(_map(onCameraChanged: (c, _) => camera = c));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.drag(find.byType(MapView), const Offset(-6000, 0));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Zoom 5, drag of 6000px ≈ 23 tiles ≈ 262° of longitude — way past
    // the old east edge of 62.42°.
    expect(camera.longitude.abs(), greaterThan(80));
  });
}
