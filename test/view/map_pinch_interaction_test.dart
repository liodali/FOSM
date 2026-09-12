import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

/// Minimal valid 1×1 RGBA PNG — decodable by Flutter's image codec.
final Uint8List _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

Future<Uint8List> _fastFetcher(int z, int x, int y) async => _tinyPng;

void main() {
  testWidgets('a multi-level pinch starts exactly one zoom transition',
      (tester) async {
    MapView.debugZoomTransitionCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 3,
            tileFetcher: _fastFetcher,
            animateZoom: true,
            zoomAnimationDuration: const Duration(milliseconds: 400),
            showZoomControls: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(MapView.debugZoomTransitionCount, 0,
        reason: 'no transition before the gesture');

    // Spread two fingers to cross several integer zoom levels. Each move is a
    // separate scale update, reproducing a real multi-step pinch.
    final left = await tester.startGesture(const Offset(360, 300));
    final right = await tester.startGesture(const Offset(440, 300));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await left.moveBy(const Offset(-30, 0));
      await right.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await left.up();
    await right.up();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(MapView.debugZoomTransitionCount, 1,
        reason: 'a multi-level pinch must build one transition, not one per '
            'crossed integer zoom');
  });
}
