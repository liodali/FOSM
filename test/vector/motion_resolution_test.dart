import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/view/render.dart';

import 'mvt_builder.dart';
import 'pipeline_fixture.dart';

ui.Image solid(int size) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff0000ff), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size, size);
  picture.dispose();
  return image;
}

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition() && clock.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

ui.Color pixel(ByteData data, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return ui.Color.fromARGB(data.getUint8(i + 3), data.getUint8(i),
      data.getUint8(i + 1), data.getUint8(i + 2));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('128 snapshots contain the full tile; idle and default renders are 256',
      () async {
    final mvt = MvtBuilder()
      ..addLayer(name: 'water', features: [
        TestFeature(
            type: TestGeomType.polygon,
            geometryCommands: polygonRingCommands(
                const [(2048, 0), (4096, 0), (4096, 4096), (2048, 4096)])),
      ]);
    final bytes = mvt.build();
    final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'motion',
        parseOffThread: false,
        adaptiveResolution: true);
    addTearDown(runtime.dispose);
    runtime.motionActive = true;
    final low = await runtime.decoder(bytes, 10, 120, 60);
    addTearDown(low.dispose);
    expect(low.width, 128);
    expect(low.height, 128);
    final data = (await low.toByteData())!;
    expect(pixel(data, 128, 16, 64), const ui.Color(0xffff0000));
    expect(pixel(data, 128, 112, 64), const ui.Color(0xff0000ff),
        reason:
            'right-hand geography must be scaled into the snapshot, not cropped');
    runtime.motionActive = false;
    final full = await runtime.decoder(bytes, 10, 120, 60);
    addTearDown(full.dispose);
    expect(full.width, 256);
    expect(runtime.parsedTileCount, 1);

    final control = VectorTileRuntime(
        loaded: buildLoadedStyle(), namespace: 'control', parseOffThread: false)
      ..motionActive = true;
    addTearDown(control.dispose);
    final unchanged = await control.decoder(bytes, 10, 120, 60);
    addTearDown(unchanged.dispose);
    expect(unchanged.width, 256);
  });

  test('preview painting fills its logical tile at integer and fractional zoom',
      () async {
    final image = solid(128);
    addTearDown(image.dispose);
    for (final scale in [1.0, 1.25]) {
      final recorder = ui.PictureRecorder();
      RenderCanvasOSM(
              horizontalTileCount: 1,
              verticalTileCount: 1,
              leftColumnTilesLngIndex: 0,
              topRowTilesLatIndex: 0,
              leftColumnTilesCanvasX: 0,
              topRowTilesCanvasY: 0,
              tiles: [Tile(image, '0/0/0', 0, 0, isPreview: true)],
              revision: 1,
              tileScale: scale)
          .paint(ui.Canvas(recorder), const ui.Size(320, 320));
      final picture = recorder.endRecording();
      final frame = await picture.toImage(320, 320);
      final data = (await frame.toByteData())!;
      expect(pixel(data, 320, (240 * scale).toInt(), (240 * scale).toInt()),
          const ui.Color(0xff0000ff));
      frame.dispose();
      picture.dispose();
    }
  });

  test('settled upgrades retain previews and snapshot pins without refetching',
      () async {
    var moving = true;
    var fetches = 0;
    var fullStarted = 0;
    final gate = Completer<void>();
    final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0.01, longitude: 0.01),
        zoom: 3,
        tilePadding: 0,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        adaptiveResolution: true,
        cacheNamespace: 'style',
        maxRenderedCacheBytes: 0,
        fetcher: (_, _, _) async {
          fetches++;
          return Uint8List.fromList([1]);
        },
        decoder: (_, __, ___, ____) async {
          final size = moving ? 128 : 256;
          if (size == 256) {
            fullStarted++;
            await gate.future;
          }
          return solid(size);
        });
    addTearDown(manager.dispose);
    manager.setMotionActive(true);
    manager.calculate();
    await until(() =>
        manager.visibleTilesReady && manager.pendingPresentationCount == 0);
    expect(manager.renderTiles.every((t) => t.isPreview), isTrue);
    expect(manager.coverage().allCovered, isTrue);
    expect(manager.coverage().sharpCells, 0);
    final beforeFetches = fetches;
    final old = manager.renderTiles.first.sourceTile!;
    final release = manager.retainSnapshot(manager.renderTiles);
    moving = false;
    manager.setMotionActive(false);
    await until(() => fullStarted > 0);
    expect(manager.renderTiles.first.sourceTile, same(old));
    expect(old.debugDisposed, isFalse);
    gate.complete();
    await until(() =>
        manager.coverage().allSharp && manager.pendingPresentationCount == 0);
    expect(
        manager.renderTiles
            .every((t) => !t.isPreview && t.sourceTile!.width == 256),
        isTrue);
    expect(fetches, beforeFetches, reason: 'upgrades must reuse source bytes');
    expect(old.debugDisposed, isFalse,
        reason: 'an old zoom snapshot still pins the preview');
    release();
    expect(old.debugDisposed, isTrue,
        reason: 'zero-budget previews release after their final pin');
    manager.setMotionActive(true);
    expect(manager.renderTiles.every((t) => !t.isPreview), isTrue,
        reason: 'motion never downgrades already-sharp imagery');
    moving = true;
    manager.setZoom(4);
    await until(() =>
        manager.visibleTilesReady && manager.pendingPresentationCount == 0);
    expect(manager.renderTiles.every((t) => t.isPreview), isTrue,
        reason: 'a moving zoom loads previews at the new source zoom');
    moving = false;
    manager.setMotionActive(false);
    await until(() =>
        manager.coverage().allSharp && manager.pendingPresentationCount == 0);
    manager.dispose();
  });

  test('resuming motion stops queued upgrades; settling later finishes them',
      () async {
    var moving = true;
    var started = 0;
    final gate = Completer<void>();
    final manager = TileManager.init(
        width: 1024,
        height: 768,
        centerLatLng: const LatLng(latitude: 0.01, longitude: 0.01),
        zoom: 5,
        tilePadding: 0,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        adaptiveResolution: true,
        fetcher: (_, _, _) async => Uint8List.fromList([1]),
        decoder: (_, _, _, _) async {
          final size = moving ? 128 : 256;
          if (size == 256) {
            started++;
            await gate.future;
          }
          return solid(size);
        });
    addTearDown(manager.dispose);
    manager.setMotionActive(true);
    manager.calculate();
    await until(() =>
        manager.visibleTilesReady && manager.pendingPresentationCount == 0);
    moving = false;
    manager.setMotionActive(false);
    await until(() => started > 0);
    moving = true;
    manager.setMotionActive(true);
    final before = started;
    gate.complete();
    await until(() =>
        manager.pendingPresentationCount == 0 &&
        manager.inFlightLoadCount == 0);
    expect(started, before);
    expect(manager.renderTiles.any((t) => t.isPreview), isTrue);
    moving = false;
    manager.setMotionActive(false);
    await until(() =>
        manager.coverage().allSharp && manager.pendingPresentationCount == 0);
    manager.dispose();
  });
}
