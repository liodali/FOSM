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
}
