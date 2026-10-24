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
  // Paced tile publication advances one scheduler frame per pump, so the
  // budget must tolerate a loaded test machine (parallel suite files),
  // not just an idle one. Ten seconds is still a hang detector: a healthy
  // paced load finishes in well under two.
  while (watch.elapsed < const Duration(seconds: 10)) {
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

/// Shrinks the surface so a full grid is a handful of tiles: paced
/// publication starts at most two images per frame, and a default-sized
/// grid (dozens of tiles) makes this wall-clock-bounded file flaky when
/// the whole suite loads the machine in parallel.
void _smallViewport(WidgetTester tester) {
  tester.view.physicalSize = const ui.Size(360, 240);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  for (final blocked in [false, true]) {
    testWidgets(
        'fractional zoom releases pinned fallback on ${blocked ? 'movement timeout' : 'replacement readiness'}',
        (tester) async {
      _smallViewport(tester);
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
      // Old-grid images keyed by slot, to observe the per-region pins.
      final oldImages = <String, ui.Image>{
        for (final tile in _grids(tester).single.tiles)
          tile.index: tile.sourceTile!,
      };
      controller.setFractionalZoom(6.25, animate: false);
      await tester.pump();
      // Images still serving as per-region fallback (parents of the
      // missing z6 cells) stay pinned despite the zero budget; obsolete
      // imagery (the old grid's padding ring) may already be evicted.
      final grid = _grids(tester).single;
      const pad = 2; // manager default tilePadding
      final visH = grid.horizontalTileCount - 2 * pad;
      final visV = grid.verticalTileCount - 2 * pad;
      var fallbackPinned = 0;
      for (var h = 0; h < visH; h++) {
        for (var v = 0; v < visV; v++) {
          final tile = grid.tiles[(h + pad) * grid.verticalTileCount + pad + v];
          if (tile.sourceTile != null) continue;
          final parent =
              oldImages['5/${tile.lngIndex ~/ 2}/${tile.latIndex ~/ 2}'];
          if (parent == null) continue;
          fallbackPinned++;
          expect(parent.debugDisposed, isFalse,
              reason: 'fallback imagery for ${tile.index} must stay pinned');
        }
      }
      expect(fallbackPinned, greaterThan(0));
      if (blocked) {
        controller.moveTo(const LatLng(latitude: 0.1, longitude: 0),
            animate: false);
        await tester.pump(const Duration(milliseconds: 650));
      } else {
        await _ready(tester);
        await tester.pump();
      }
      expect(oldImages.values.every((image) => image.debugDisposed), isTrue);
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
      _smallViewport(tester);
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
