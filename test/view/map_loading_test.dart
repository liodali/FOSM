import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/api/tile.dart';

Future<Uint8List> _png(WidgetTester tester) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(Colors.blue, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  final data = await tester
      .runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  testWidgets('loading builder is replaced by typed errors and retry recovers',
      (tester) async {
    final bytes = await _png(tester);
    var fail = true;
    MapLoadState? latest;
    final failures = <MapTileFailure>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      tileFetcher: (z, x, y) async {
        if (fail) {
          throw const TileLoadException(TileFailureKind.http, 'Unavailable',
              statusCode: 404);
        }
        return bytes;
      },
      onTileError: failures.add,
      loadingBuilder: (context, state) =>
          const Center(child: Text('Loading map')),
      errorBuilder: (context, state, retry) {
        latest = state;
        return Align(
            alignment: Alignment.topLeft,
            child: TextButton(
                onPressed: () {
                  fail = false;
                  retry();
                },
                child: const Text('Try again')));
      },
    ))));
    expect(find.text('Loading map'), findsOneWidget);
    await _until(tester, () => find.text('Try again').evaluate().isNotEmpty);
    expect(failures, isNotEmpty);
    expect(failures.first.error.statusCode, 404);
    await tester.pump(const Duration(seconds: 6));
    expect(latest!.failedTiles, latest!.totalTiles);
    expect(latest!.loadingTiles, 0);
    final beforeRetry = failures.length;
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(fail, isFalse);
    await _until(
        tester,
        () =>
            find.text('Loading map').evaluate().isEmpty &&
            find.text('Try again').evaluate().isEmpty);
    expect(failures.length, beforeRetry);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('timeout frees custom fetch slots; disposal ignores late results',
      (tester) async {
    final gate = Completer<Uint8List>();
    var callbacks = 0;
    final manager = TileManager.init(
        width: 128,
        height: 128,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        fetcher: (z, x, y) => gate.future,
        requestTimeout: const Duration(milliseconds: 100),
        tilePadding: 0,
        preloadAdjacentZoom: false);
    manager.onTileError = (_) => callbacks++;
    manager.calculate();
    await tester.pump(const Duration(milliseconds: 101));
    expect(manager.loadState.failures, isNotEmpty);
    expect(manager.loadState.error!.kind, TileFailureKind.timeout);
    manager.dispose();
    final before = callbacks;
    gate.complete(Uint8List(1));
    await tester.pump();
    expect(callbacks, before);
    expect(manager.renderedCacheBytes, 0);
  });

  testWidgets('progress keeps loaded tiles and excludes stale failures',
      (tester) async {
    final bytes = await _png(tester);
    final gates = <String, Completer<Uint8List>>{};
    final manager = TileManager.init(
        width: 128,
        height: 128,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        fetcher: (z, x, y) => (gates['$z/$x/$y'] ??= Completer()).future,
        decoder: (bytes, z, x, y) => Tile.decodeImage(bytes),
        tilePadding: 0,
        preloadAdjacentZoom: false);
    manager.calculate();
    final original = gates.values.toList();
    original.first.complete(bytes);
    await _until(tester, () => manager.loadState.loadedTiles == 1);
    original.last.completeError(const TileLoadException(
        TileFailureKind.http, 'Unavailable',
        statusCode: 404));
    await tester.pump();
    expect(manager.loadState.failedTiles, 1);
    expect(manager.loadState.loadingTiles, manager.loadState.totalTiles - 2);
    manager.setCenterFromTileCoords(24, 24);
    manager.calculate();
    expect(manager.loadState.failedTiles, 0);
    manager.dispose();
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete(bytes);
    }
    await tester.pump();
  });

  test('typed status distinguishes transient HTTP failures', () {
    expect(
        const TileLoadException(TileFailureKind.http, 'Error', statusCode: 429)
            .isRetryable,
        isTrue);
    expect(
        const TileLoadException(TileFailureKind.http, 'Error', statusCode: 503)
            .isRetryable,
        isTrue);
    expect(
        const TileLoadException(TileFailureKind.http, 'Error', statusCode: 401)
            .isRetryable,
        isFalse);
  });
}
