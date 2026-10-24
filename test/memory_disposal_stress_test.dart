import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/api/tile_source.dart' show TileDecodeAborted;
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';

import 'vector/vector_pipeline_test.dart'
    show buildDenseLabelTile, buildLoadedStyle;

/// A decodable 1×1 PNG produced without network or fixtures.
Future<Uint8List> _pngBytes() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff204060), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

ui.Image _syncImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff307050), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(4, 4);
  picture.dispose();
  return image;
}

/// Runs already-scheduled real async work for a bounded number of turns
/// inside `tester.runAsync`.
Future<void> _flush(WidgetTester tester, {int turns = 40}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
}

void main() {
  testWidgets(
      'fetches resolving after dispose publish nothing and store '
      'nothing', (tester) async {
    final png = await tester.runAsync(_pngBytes);
    final fetchCompleters = <String, Completer<Uint8List>>{};
    Future<Uint8List> fetcher(int z, int x, int y) {
      final key = '$z/$x/$y';
      final completer = Completer<Uint8List>();
      fetchCompleters[key] = completer;
      return completer.future;
    }

    final manager = TileManager.init(
      width: 256,
      height: 256,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 3,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      fetcher: fetcher,
    );
    manager.calculate();
    await _flush(tester, turns: 5);
    expect(fetchCompleters, isNotEmpty);

    manager.dispose();

    // Every outstanding network future resolves successfully after dispose.
    for (final completer in fetchCompleters.values) {
      completer.complete(png!);
    }
    await _flush(tester);

    expect(manager.renderTiles, isEmpty);
    expect(manager.byteCacheBytes, 0,
        reason: 'a post-dispose fetch must not repopulate caches');
    expect(manager.renderedCacheBytes, 0);
    expect(manager.pendingFetchCount, 0);
  });

  testWidgets('decodes resolving after dispose dispose their images',
      (tester) async {
    final png = await tester.runAsync(_pngBytes);
    final decodeCompleters = <String, Completer<ui.Image>>{};
    Future<ui.Image> decoder(Uint8List bytes, int z, int x, int y) {
      final key = '$z/$x/$y';
      final completer = Completer<ui.Image>();
      decodeCompleters[key] = completer;
      return completer.future;
    }

    final manager = TileManager.init(
      width: 256,
      height: 256,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 3,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      fetcher: (_, __, ___) async => png!,
      decoder: decoder,
    );
    manager.calculate();
    await _flush(tester, turns: 5);
    expect(decodeCompleters, isNotEmpty);

    manager.dispose();

    // Late decodes succeed after dispose: every produced image must be
    // disposed, never published or leaked into the cache.
    final images = <ui.Image>[];
    for (final completer in decodeCompleters.values) {
      final image = _syncImage();
      images.add(image);
      completer.complete(image);
    }
    await _flush(tester);

    expect(manager.renderTiles, isEmpty);
    expect(manager.renderedCacheBytes, 0);
    for (final image in images) {
      expect(image.debugDisposed, isTrue,
          reason: 'a late decode result must be disposed at the boundary');
    }
    expect(manager.pendingPresentationCount, 0);
  });

  testWidgets(
      'mixed outstanding fetch, decode and presentation work '
      'settles cleanly at dispose', (tester) async {
    final png = await tester.runAsync(_pngBytes);
    final fetchCompleters = <String, Completer<Uint8List>>{};
    final decodeCompleters = <String, Completer<ui.Image>>{};
    var fetchCalls = 0;

    Future<Uint8List> fetcher(int z, int x, int y) {
      fetchCalls++;
      // Hold the first fetch; resolve the rest instantly so the pipeline
      // reaches decode/presentation stages for other tiles.
      if (fetchCalls == 1) {
        final completer = Completer<Uint8List>();
        fetchCompleters['$z/$x/$y'] = completer;
        return completer.future;
      }
      return Future.value(png);
    }

    Future<ui.Image> decoder(Uint8List bytes, int z, int x, int y) {
      final completer = Completer<ui.Image>();
      decodeCompleters['$z/$x/$y'] = completer;
      return completer.future;
    }

    final manager = TileManager.init(
      width: 512,
      height: 512,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 4,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      fetcher: fetcher,
      decoder: decoder,
    );
    manager.calculate();
    await _flush(tester, turns: 8);
    expect(fetchCompleters, isNotEmpty);
    expect(decodeCompleters, isNotEmpty);

    manager.dispose();

    // Resolve everything that was outstanding, in arbitrary order.
    for (final completer in fetchCompleters.values) {
      completer.complete(png!);
    }
    final images = <ui.Image>[];
    for (final completer in decodeCompleters.values) {
      final image = _syncImage();
      images.add(image);
      completer.complete(image);
    }
    await _flush(tester);

    expect(manager.renderTiles, isEmpty);
    expect(manager.renderedCacheBytes, 0);
    expect(manager.pendingPresentationCount, 0);
    expect(manager.inFlightLoadCount, 0);
    for (final image in images) {
      expect(image.debugDisposed, isTrue);
    }
  });

  testWidgets(
      'runtime dispose releases queued decode waiters without '
      'running their jobs', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'dispose-stress',
      parseOffThread: false,
    );
    addTearDown(runtime.dispose);
    VectorTileRuntime.debugMaxConcurrentDecodesOverride = 1;
    addTearDown(
        () => VectorTileRuntime.debugMaxConcurrentDecodesOverride = null);

    final gate = Completer<void>();
    runtime.debugOnDecodeStarted = (_, __, ___) => gate.future;

    final held = runtime.decoder(buildDenseLabelTile(), 12, 3, 2);
    final waiters = [
      runtime.decoder(buildDenseLabelTile(), 12, 4, 2),
      runtime.decoder(buildDenseLabelTile(), 12, 5, 2),
    ];
    await tester.runAsync(() async {
      final watch = Stopwatch()..start();
      while (runtime.debugWaiterCount < 2 &&
          watch.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    expect(runtime.debugWaiterCount, 2);

    runtime.dispose();

    // Queued waiters must unwind promptly as aborted work, not hang.
    await expectLater(waiters[0], throwsA(isA<TileDecodeAborted>()));
    await expectLater(waiters[1], throwsA(isA<TileDecodeAborted>()));
    // Only the held decode ever entered the lane.
    expect(runtime.debugDecodeOrder.length, 1);

    // Releasing the held job after dispose fails it without side effects.
    gate.complete();
    await expectLater(held, throwsA(isA<StateError>()));
    runtime.debugOnDecodeStarted = null;
  });

  testWidgets(
      'label preparation pending across dispose is dropped without '
      'notifications', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'dispose-labels',
      parseOffThread: false,
    );
    addTearDown(runtime.dispose);
    var notifications = 0;
    runtime.labelsNotifier.addListener(() => notifications++);

    final image = (await tester
        .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2)))!;
    // Dispose before the deferred label pump timer fires.
    runtime.dispose();
    image.dispose();
    await _flush(tester);

    expect(runtime.labelOverlayPreparedTiles, 0);
    expect(notifications, 0,
        reason: 'a disposed runtime must not notify label listeners');
  });
}
