import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/tile_work_scheduler.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';

import 'vector_pipeline_test.dart'
    show buildLoadedStyle, buildDenseLabelTile, buildHalfWaterTile, Pixels;

void main() {
  testWidgets('vector images and labels progress through a shared frame budget',
      (tester) async {
    var clock = Duration.zero;
    var frames = 0;
    final scheduler = TileWorkScheduler(
      now: () {
        clock += const Duration(microseconds: 500);
        return clock;
      },
      maxImageStartsPerFrame: 1,
      nextFrame: () async {
        frames++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      },
    );
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'shared-budget',
      parseOffThread: false,
      workScheduler: scheduler,
    );
    addTearDown(() {
      runtime.dispose();
      scheduler.dispose();
    });
    var labelUpdates = 0;
    runtime.labelsNotifier.addListener(() {
      labelUpdates++;
    });
    final images = await tester.runAsync(() async {
      final results = await Future.wait([
        runtime.decoder(buildDenseLabelTile(), 12, 3, 2),
        runtime.decoder(buildHalfWaterTile(), 12, 4, 2),
      ]);
      final timeout = Stopwatch()..start();
      while (labelUpdates < 2 && timeout.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return results;
    });
    expect(images, hasLength(2));
    expect(frames, greaterThan(2),
        reason: 'jobs must share and exhaust the allowance across frames');
    expect(labelUpdates, 2, reason: 'labels must not starve behind base tiles');
    final bytes = await tester.runAsync(() => images![1].toByteData());
    final pixels = Pixels(bytes!, 256);
    expect(pixels.blue(40, 100), 255);
    expect(pixels.red(220, 100), 255);
    for (final image in images!) {
      image.dispose();
    }
  });

  testWidgets('raster coverage advances across paced image submissions',
      (tester) async {
    var frames = 0;
    final scheduler = TileWorkScheduler(
      now: () => Duration.zero,
      maxImageStartsPerFrame: 1,
      nextFrame: () async {
        frames++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      },
    );
    // Produce valid encoded bytes without relying on HTTP or disk state.
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1, 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    });
    var decoded = 0;
    final manager = TileManager.init(
      width: 512,
      height: 512,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 4,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      fetcher: (_, __, ___) async => png!,
      decoder: (bytes, _, __, ___) {
        decoded++;
        return Tile.decodeImage(bytes);
      },
      workScheduler: scheduler,
    );
    addTearDown(() {
      manager.dispose();
      scheduler.dispose();
    });
    await tester.runAsync(() async {
      manager.calculate();
      final timeout = Stopwatch()..start();
      while (!manager.visibleTilesReady &&
          timeout.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    expect(manager.visibleTilesReady, isTrue);
    expect(decoded, manager.visibleTileCount);
    expect(frames, greaterThanOrEqualTo(decoded - 1));
    expect(manager.loadState.failures, isEmpty);
  });
}
