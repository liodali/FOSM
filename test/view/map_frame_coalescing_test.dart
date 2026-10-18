import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/view/render.dart';

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

void main() {
  testWidgets('paced tile arrivals rebuild the map at most once per frame',
      (tester) async {
    final completers = <String, Completer<Uint8List>>{};
    Future<Uint8List> fetcher(int z, int x, int y) {
      final completer = Completer<Uint8List>();
      completers['$z/$x/$y'] = completer;
      return completer.future;
    }

    MapView.debugBuildCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 3,
            tileFetcher: fetcher,
            showZoomControls: false,
            animateZoom: false,
          ),
        ),
      ),
    );
    await tester.pump();

    final before = MapView.debugBuildCount;
    expect(completers, isNotEmpty);

    // Complete the first foreground batch in the same event-loop turn.
    final batch = completers.values.toList();
    for (final completer in batch) {
      if (!completer.isCompleted) completer.complete(_tinyPng);
    }

    int decodedCount() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<RenderCanvasOSM>()
        .single
        .tiles
        .where((tile) => tile.sourceTile != null)
        .length;

    // Image creation now spans multiple frames. Keep presenting frames while
    // checking that each batch still coalesces into at most one map rebuild.
    final watch = Stopwatch()..start();
    while (decodedCount() < batch.length &&
        watch.elapsed < const Duration(seconds: 5)) {
      final builds = MapView.debugBuildCount;
      await tester.pump(const Duration(milliseconds: 16));
      expect(MapView.debugBuildCount - builds, lessThanOrEqualTo(1),
          reason: 'tile work must not produce multiple builds in one frame');
      final previous = decodedCount();
      await tester.runAsync(() async {
        final turn = Stopwatch()..start();
        while (decodedCount() == previous &&
            turn.elapsed < const Duration(milliseconds: 20)) {
          await Future<void>.delayed(Duration.zero);
        }
      });
    }
    expect(decodedCount(), batch.length,
        reason: 'paced loading must eventually publish the complete batch');
    final builds = MapView.debugBuildCount;
    await tester.pump();
    expect(MapView.debugBuildCount - builds, lessThanOrEqualTo(1));
    expect(MapView.debugBuildCount, greaterThan(before));

    // Drain the adjacent-zoom preload debounce so no timer is left pending.
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });
}
