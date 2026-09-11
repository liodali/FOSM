import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/api/tile_source.dart' show TileDecodeAborted;
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

import 'mvt_builder.dart';

/// Style used by the pipeline tests: red background, blue water fill on
/// the `water` source-layer, one text label layer. All tile URLs point at
/// an invalid host — nothing here touches the network.
LoadedVectorStyle buildLoadedStyle() {
  final style = parseStyleJson(jsonEncode({
    'version': 8,
    'sources': {
      'openmaptiles': {
        'type': 'vector',
        'tiles': ['https://example.invalid/{z}/{x}/{y}.pbf'],
        'maxzoom': 12,
      },
    },
    'layers': [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#ff0000'},
      },
      {
        'id': 'water',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'paint': {'fill-color': '#0000ff'},
      },
      {
        'id': 'water-labels',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'layout': {
          'text-field': ['get', 'class']
        },
      },
    ],
  }));
  return LoadedVectorStyle(
    style: style,
    sources: const {
      'openmaptiles': ResolvedTileSource(
        name: 'openmaptiles',
        type: 'vector',
        urlTemplate: 'https://example.invalid/{z}/{x}/{y}.pbf',
        maxZoom: 12,
      ),
    },
  );
}

/// Left half of the tile is blue water, the rest shows the red background.
Uint8List buildHalfWaterTile() {
  final builder = MvtBuilder()
    ..addLayer(
      name: 'water',
      keys: const ['class'],
      values: const ['ocean'],
      features: [
        TestFeature(
          id: 1,
          type: TestGeomType.polygon,
          tags: const [0, 0],
          geometryCommands: polygonRingCommands(
            const [(0, 0), (2048, 0), (2048, 4096), (0, 4096)],
          ),
        ),
        TestFeature(
          id: 2,
          type: TestGeomType.point,
          tags: const [0, 0],
          geometryCommands: pointCommands(1024, 2048),
        ),
      ],
    );
  return builder.build();
}

/// A water layer with many point features so the symbol layer produces a
/// dense label set for preparation tests.
Uint8List buildDenseLabelTile({int count = 40}) {
  final builder = MvtBuilder()
    ..addLayer(
      name: 'water',
      keys: const ['class'],
      values: const ['ocean'],
      features: [
        for (var i = 1; i <= count; i++)
          TestFeature(
            id: i,
            type: TestGeomType.point,
            tags: const [0, 0],
            geometryCommands: pointCommands(100 + i * 90, 200 + (i % 10) * 300),
          ),
      ],
    );
  return builder.build();
}

/// A tiny RGBA pixel reader over raw [ByteData] from `toByteData()`.
class Pixels {
  final ByteData data;
  final int width;

  Pixels(this.data, this.width);

  int red(int x, int y) => data.getUint8((y * width + x) * 4);
  int green(int x, int y) => data.getUint8((y * width + x) * 4 + 1);
  int blue(int x, int y) => data.getUint8((y * width + x) * 4 + 2);
  int alpha(int x, int y) => data.getUint8((y * width + x) * 4 + 3);
}

void main() {
  group('VectorTileRenderer', () {
    testWidgets('renders background + fill with correct pixels',
        (tester) async {
      final loaded = buildLoadedStyle();
      final renderer = VectorTileRenderer(loaded);
      final decoded = decodeVectorTile(buildHalfWaterTile());

      final image = await tester.runAsync(() async {
        final picture = renderer.render(
          decoded: decoded,
          srcZ: 12,
          z: 12,
          x: 3,
          y: 2,
        );
        final img = await picture.toImage(256, 256);
        picture.dispose();
        return img;
      });
      expect(image, isNotNull);
      expect(image!.width, 256);
      expect(image.height, 256);

      final bytes = await tester.runAsync(() => image.toByteData());
      expect(bytes, isNotNull);
      final pixels = Pixels(bytes!, 256);

      // Left half: opaque blue. Right half: opaque red background.
      expect(pixels.blue(10, 128), 255);
      expect(pixels.red(10, 128), 0);
      expect(pixels.alpha(10, 128), 255);
      expect(pixels.red(246, 128), 255);
      expect(pixels.blue(246, 128), 0);
      expect(pixels.alpha(246, 128), 255);
    });

    testWidgets('time budget yields within a dense style layer',
        (tester) async {
      final renderer = VectorTileRenderer(buildLoadedStyle());
      final decoded = decodeVectorTile(buildHalfWaterTile());
      var yields = 0;

      final picture = await renderer.renderAsync(
        decoded: decoded,
        srcZ: 12,
        z: 12,
        x: 3,
        y: 2,
        yieldBudget: Duration.zero,
        yieldControl: () async {
          yields++;
        },
      );

      expect(yields, greaterThan(0));
      picture.dispose();
    });

    testWidgets('over-zoom renders the parent sub-rect', (tester) async {
      final loaded = buildLoadedStyle();
      final renderer = VectorTileRenderer(loaded);
      final decoded = decodeVectorTile(buildHalfWaterTile());

      Future<ui.Image> renderAt(int z, int x, int y) async {
        final picture = renderer.render(
          decoded: decoded,
          srcZ: 12,
          z: z,
          x: x,
          y: y,
        );
        final img = await picture.toImage(256, 256);
        picture.dispose();
        return img;
      }

      final images = await tester.runAsync(
        () => Future.wait([renderAt(13, 6, 4), renderAt(13, 7, 4)]),
      );
      final leftChild = images![0];
      final rightChild = images[1];

      final leftBytes = await tester.runAsync(() => leftChild.toByteData());
      final rightBytes = await tester.runAsync(() => rightChild.toByteData());
      final leftPixels = Pixels(leftBytes!, leftChild.width);
      final rightPixels = Pixels(rightBytes!, rightChild.width);

      // Child (6, 4) is the top-left quadrant of the parent: entirely
      // inside the blue half. Child (7, 4) is the top-right: all red.
      expect(leftPixels.blue(128, 128), 255);
      expect(leftPixels.red(128, 128), 0);
      expect(rightPixels.red(128, 128), 255);
      expect(rightPixels.blue(128, 128), 0);
    });
  });

  group('LabelOverlay stability and disposal', () {
    test('createLabelOverlay returns one stable instance', () {
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'label-stability',
        parseOffThread: false,
      );
      // The overlay must be identical across calls so prepared labels and
      // TextPainters survive tile-arrival rebuilds.
      expect(runtime.createLabelOverlay(), same(runtime.labelOverlay));
      expect(runtime.createLabelOverlay(), same(runtime.labelOverlay));
      runtime.dispose();
    });

    test('paint after dispose is a no-op (does not throw)', () {
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'label-dispose',
        parseOffThread: false,
      );
      final overlay = runtime.labelOverlay;
      runtime.dispose();

      // Painting a disposed overlay must not throw and must do nothing.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      overlay.paint(
        canvas,
        const ui.Size(256, 256),
        zoom: 12,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        tiles: const [],
      );
      recorder.endRecording().dispose();
    });
  });

  group('Over-zoom parse sharing', () {
    testWidgets('two over-zoom siblings share one parsed source tile',
        (tester) async {
      // Source maxzoom is 12; z13 tiles resolve to the same z12 source.
      final tileBytes = buildHalfWaterTile();
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'overzoom-share',
        parseOffThread: false,
      );

      // Decode two z13 siblings that map to the same z12 source tile.
      final results = await tester.runAsync(() => Future.wait([
            runtime.decoder(tileBytes, 13, 6, 4),
            runtime.decoder(tileBytes, 13, 7, 4),
          ]));

      expect(results, isNotNull);
      final images = results!;
      expect(images.length, 2);
      for (final image in images) {
        expect(image.width, 256);
        expect(image.height, 256);
        image.dispose();
      }

      // Both siblings resolve to the same z12 source coord → one parsed
      // tile, shared via the in-flight parse dedup + LRU.
      final parsedA = runtime.parsedTileFor(13, 6, 4);
      final parsedB = runtime.parsedTileFor(13, 7, 4);
      expect(parsedA, isNotNull);
      expect(parsedB, isNotNull);
      expect(identical(parsedA, parsedB), isTrue,
          reason: 'over-zoom siblings must share the parsed source tile');

      runtime.dispose();
    });
  });

  group('TileManager vector mode', () {
    testWidgets('namespaced keys + full fetch/decode/render cycle',
        (tester) async {
      final tileBytes = buildHalfWaterTile();
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'pipeline-test',
        parseOffThread: false,
      );

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) async => tileBytes,
        decoder: runtime.decoder,
        cacheNamespace: runtime.namespace,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );

      await tester.runAsync(() async {
        manager.calculate();
        final timeout = Stopwatch()..start();
        while (manager.renderTiles.any((tile) => tile.sourceTile == null) &&
            timeout.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      expect(manager.renderTiles, isNotEmpty);
      for (final tile in manager.renderTiles) {
        expect(tile.index, startsWith('pipeline-test/'));
        expect(tile.sourceTile, isNotNull,
            reason: 'tile ${tile.index} should have rendered');
      }

      // The parsed source tile is shared and cached for the label overlay.
      final anyTile = manager.renderTiles.first;
      final parts = anyTile.index.split('/');
      final parsed = runtime.parsedTileFor(
        int.parse(parts[1]),
        int.parse(parts[2]),
        int.parse(parts[3]),
      );
      expect(parsed, isNotNull);
      expect(parsed!.decoded.layerByName('water'), isNotNull);

      // Label overlay paints without throwing (symbol layer present).
      final overlay = runtime.createLabelOverlay();
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        overlay.paint(
          canvas,
          const ui.Size(256, 256),
          zoom: 12,
          leftColumnTilesCanvasX: 0,
          topRowTilesCanvasY: 0,
          leftColumnTilesLngIndex: int.parse(parts[2]),
          topRowTilesLatIndex: int.parse(parts[3]),
          tiles: manager.renderTiles,
        );
        recorder.endRecording().dispose();
      });

      manager.dispose();
      runtime.dispose();
    });

    testWidgets('over-zoom siblings fetch one source, render distinct images',
        (tester) async {
      final tileBytes = buildHalfWaterTile();
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'overzoom-fetch',
        parseOffThread: false,
      );

      var fetches = 0;
      final manager = TileManager.init(
        width: 512,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 13,
        fetcher: (z, x, y) async {
          fetches++;
          return tileBytes;
        },
        decoder: runtime.decoder,
        // Over-zoom resolution is the canonical source identity.
        resourceKeyBuilder: (z, x, y) =>
            runtime.vectorSource.resolve(z, x, y).toString(),
        cacheNamespace: runtime.namespace,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);
      addTearDown(runtime.dispose);

      // Run the whole load inside runAsync: the vector renderer yields on
      // real timers between layers, so a fake-async zone would stall it.
      await tester.runAsync(() async {
        manager.setCenterFromTileCoords(7, 4);
        manager.calculate();
        final timeout = Stopwatch()..start();
        while (!manager.visibleTilesReady &&
            timeout.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      // Four logical z13 slots, only two z12 source resources.
      expect(manager.renderTiles.length, 4);
      for (final tile in manager.renderTiles) {
        expect(tile.sourceTile, isNotNull, reason: '${tile.index} rendered');
      }
      expect(fetches, 2,
          reason: 'over-zoom siblings must share one source download');
      expect(manager.renderTiles.map((t) => t.sourceTile).toSet().length, 4,
          reason: 'each logical slot keeps its own rendered image');
    });
  });

  group('Label preparation', () {
    VectorTileRuntime makeRuntime(String namespace) => VectorTileRuntime(
          loaded: buildLoadedStyle(),
          namespace: namespace,
          parseOffThread: false,
        );

    testWidgets('preparation completes before the decoder publishes',
        (tester) async {
      final runtime = makeRuntime('label-prep');
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;
      expect(overlay.preparedTileCount, 0);

      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2));
      image?.dispose();

      expect(overlay.preparedTileCount, greaterThan(0),
          reason: 'labels must be prepared before the tile is returned');
    });

    testWidgets('preparation yields cooperatively under a dense tile',
        (tester) async {
      final runtime = makeRuntime('label-yield');
      addTearDown(runtime.dispose);

      // Decode first so the parsed tile is available to the overlay.
      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2));
      image?.dispose();

      var yields = 0;
      await tester.runAsync(() => runtime.labelOverlay.prepare(
            12,
            3,
            2,
            yieldBudget: Duration.zero,
            yieldControl: () async {
              yields++;
            },
          ));
      expect(yields, greaterThan(0),
          reason: 'a dense symbol tile must yield between batches');
    });

    testWidgets('preparation aborts when the tile becomes stale',
        (tester) async {
      final runtime = makeRuntime('label-stale');
      addTearDown(runtime.dispose);

      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2));
      image?.dispose();

      Object? error;
      await tester.runAsync(() async {
        try {
          await runtime.labelOverlay.prepare(
            12,
            3,
            2,
            isRelevant: () => false,
            yieldBudget: Duration.zero,
          );
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<TileDecodeAborted>());
    });

    testWidgets('the created image is disposed when preparation fails',
        (tester) async {
      final runtime = makeRuntime('label-fail');
      addTearDown(runtime.dispose);

      runtime.labelOverlay.debugFailNextPrepare = true;

      Object? error;
      await tester.runAsync(() async {
        try {
          final image = await runtime.decoder(buildHalfWaterTile(), 12, 3, 2);
          image.dispose();
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<StateError>());
      expect(runtime.debugDisposedImages, 1,
          reason: 'a failed preparation must not leak the snapshot image');
    });
  });

  group('Latest-demand presentation lane', () {
    testWidgets('renderAsync aborts with VectorTileCancelled when stale',
        (tester) async {
      final renderer = VectorTileRenderer(buildLoadedStyle());
      final decoded = decodeVectorTile(buildHalfWaterTile());

      Object? error;
      await tester.runAsync(() async {
        try {
          final picture = await renderer.renderAsync(
            decoded: decoded,
            srcZ: 12,
            z: 12,
            x: 3,
            y: 2,
            isRelevant: () => false,
          );
          picture.dispose();
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<VectorTileCancelled>());
    });

    testWidgets('the runtime bridges render cancellation to TileDecodeAborted',
        (tester) async {
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'cancel-bridge',
        parseOffThread: false,
      );
      addTearDown(runtime.dispose);

      // Relevant through the parse/pre-render gates, stale once rendering
      // (which owns its own checkpoint) starts.
      var calls = 0;
      runtime.isTileRelevant = (z, x, y) => calls++ < 3;

      Object? error;
      await tester.runAsync(() async {
        try {
          final image = await runtime.decoder(buildHalfWaterTile(), 12, 3, 2);
          image.dispose();
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<TileDecodeAborted>());
    });

    testWidgets('the lane runs the highest-priority waiter first',
        (tester) async {
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'lane-priority',
        parseOffThread: false,
      );
      addTearDown(runtime.dispose);
      VectorTileRuntime.debugMaxConcurrentDecodesOverride = 1;
      addTearDown(
          () => VectorTileRuntime.debugMaxConcurrentDecodesOverride = null);

      final priorities = <String, int>{
        '0/0/0': 0,
        '12/3/2': 10,
        '12/4/2': 20,
      };
      runtime.tilePriority = (z, x, y) => priorities['$z/$x/$y'] ?? 0;

      final firstGate = Completer<void>();
      runtime.debugOnDecodeStarted = (z, x, y) async {
        if (z == 0 && x == 0 && y == 0) await firstGate.future;
      };

      final bytes = buildHalfWaterTile();
      await tester.runAsync(() async {
        final futures = <Future<ui.Image>>[
          runtime.decoder(bytes, 0, 0, 0),
          runtime.decoder(bytes, 12, 3, 2),
          runtime.decoder(bytes, 12, 4, 2),
        ];
        expect(runtime.debugWaiterCount, 2,
            reason: 'the two later tiles wait behind the first');
        firstGate.complete();
        final images = await Future.wait(futures);
        for (final image in images) {
          image.dispose();
        }
      });

      expect(runtime.debugDecodeOrder, ['0/0/0', '12/4/2', '12/3/2'],
          reason: 'the newest/highest-priority waiter must run next');
    });

    testWidgets('a waiter that leaves the viewport is released, not run',
        (tester) async {
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'lane-prune',
        parseOffThread: false,
      );
      addTearDown(runtime.dispose);
      VectorTileRuntime.debugMaxConcurrentDecodesOverride = 1;
      addTearDown(
          () => VectorTileRuntime.debugMaxConcurrentDecodesOverride = null);

      final relevant = <String>{'0/0/0', '12/3/2'};
      runtime.isTileRelevant = (z, x, y) => relevant.contains('$z/$x/$y');

      final firstGate = Completer<void>();
      runtime.debugOnDecodeStarted = (z, x, y) async {
        if (z == 0 && x == 0 && y == 0) await firstGate.future;
      };

      final bytes = buildHalfWaterTile();
      Object? staleError;
      await tester.runAsync(() async {
        final first = runtime.decoder(bytes, 0, 0, 0);
        final stale = runtime.decoder(bytes, 12, 3, 2);
        final staleFuture = stale
            .then<void>((image) => image.dispose())
            .catchError((Object error) {
          staleError = error;
        });
        expect(runtime.debugWaiterCount, 1);

        // The queued tile scrolls away while the first decode is running.
        relevant.remove('12/3/2');
        firstGate.complete();
        (await first).dispose();
        await staleFuture;
      });

      expect(staleError, isA<TileDecodeAborted>());
      expect(runtime.debugDecodeOrder, ['0/0/0'],
          reason: 'a stale waiter must never enter the lane');
    });
  });
}
