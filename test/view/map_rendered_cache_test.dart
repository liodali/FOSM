import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/view/render.dart';

List<RenderCanvasOSM> _grids(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<RenderCanvasOSM>()
    .toList();

Future<Uint8List> _png(WidgetTester tester) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xFF336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  try {
    final bytes = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    );
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<void> _ready(WidgetTester tester) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final grids = _grids(tester);
    if (grids.isNotEmpty &&
        grids.first.tiles.every((tile) => tile.sourceTile != null)) {
      return;
    }
  }
  fail('Tile grid did not load within five seconds');
}

void main() {
  for (final blocked in [false, true]) {
    testWidgets(
        'fractional zoom releases pinned fallback on ${blocked ? 'movement timeout' : 'replacement readiness'}',
        (tester) async {
      final png = await _png(tester);
      final controller = MapController();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: MapView(
        latLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        enableFractionalZoom: true,
        controller: controller,
        tileFetcher: (z, x, y) => blocked && z != 5
            ? Future<Uint8List>.delayed(const Duration(seconds: 10), () => png)
            : Future.value(png),
        maxRenderedCacheBytes: 0,
      ))));
      await _ready(tester);
      final oldImages =
          _grids(tester).single.tiles.map((tile) => tile.sourceTile!).toList();
      controller.setFractionalZoom(6.25, animate: false);
      await tester.pump();
      expect(oldImages.every((image) => !image.debugDisposed), isTrue);
      if (blocked) {
        controller.moveTo(const LatLng(latitude: 0.1, longitude: 0),
            animate: false);
        await tester.pump(const Duration(milliseconds: 650));
      } else {
        await _ready(tester);
        await tester.pump();
      }
      expect(oldImages.every((image) => image.debugDisposed), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      // Let only the caller-owned fake fetch settle; MapView has already
      // cancelled its own deadlines and released every image.
      if (blocked) await tester.pump(const Duration(seconds: 10));
    });
  }
  for (final interrupt in [false, true]) {
    testWidgets(
        'zero-budget zoom releases snapshot on '
        '${interrupt ? 'instant interruption' : 'animation completion'}',
        (tester) async {
      final png = await _png(tester);
      final controller = MapController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            controller: controller,
            tileFetcher: (z, x, y) async => png,
            maxRenderedCacheBytes: 0,
          ),
        ),
      ));
      await _ready(tester);
      final oldImages =
          _grids(tester).single.tiles.map((tile) => tile.sourceTile!).toList();

      controller.setZoom(6);
      await tester.pump();
      expect(_grids(tester), hasLength(2));
      expect(oldImages.every((image) => !image.debugDisposed), isTrue);
      await _ready(tester);
      expect(oldImages.every((image) => !image.debugDisposed), isTrue);

      if (interrupt) {
        controller.setZoom(7, animate: false);
        await tester.pump();
      } else {
        // Tile publication and its coalesced readiness notification can land
        // in separate frames. Start the settle phase before advancing time.
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }
      expect(_grids(tester), hasLength(1));
      expect(oldImages.every((image) => image.debugDisposed), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
