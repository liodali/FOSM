import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile.dart' show Tile;
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/api/tile_source.dart' show TileDecodeAborted;
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/render/label_overlay.dart' show LabelOverlay;
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

import 'mvt_builder.dart';

/// Style used by the pipeline tests: red background, blue water fill on
/// the `water` source-layer, one text label layer. All tile URLs point at
/// an invalid host — nothing here touches the network.
///
/// [symbolLayout] overrides/extends the symbol layer's layout properties
/// and [symbolFilter] replaces its filter, for data-driven and
/// line-placement variants.
LoadedVectorStyle buildLoadedStyle({
  Map<String, dynamic> symbolLayout = const {},
  Map<String, dynamic>? symbolFilter,
}) {
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
          'text-field': ['get', 'class'],
          ...symbolLayout,
        },
        if (symbolFilter != null) 'filter': symbolFilter,
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
/// dense label set for preparation tests. With [withRanks], each feature
/// also carries a numeric `rank` (10/14/18) for data-driven styling.
Uint8List buildDenseLabelTile({int count = 40, bool withRanks = false}) {
  final builder = MvtBuilder()
    ..addLayer(
      name: 'water',
      keys: withRanks ? const ['class', 'rank'] : const ['class'],
      values: withRanks ? const ['ocean', 10, 14, 18] : const ['ocean'],
      features: [
        for (var i = 1; i <= count; i++)
          TestFeature(
            id: i,
            type: TestGeomType.point,
            tags: withRanks ? [0, 0, 1, 1 + (i % 3)] : const [0, 0],
            geometryCommands: pointCommands(100 + i * 90, 200 + (i % 10) * 300),
          ),
      ],
    );
  return builder.build();
}

/// A water layer with many long zig-zag lines so a `symbol-placement:
/// line` layer samples a dense set of rotated placements along each path.
Uint8List buildDenseLineTile({int count = 24, int pointsPerLine = 40}) {
  final builder = MvtBuilder()
    ..addLayer(
      name: 'water',
      keys: const ['name'],
      values: const ['Aare'],
      features: [
        for (var i = 0; i < count; i++)
          TestFeature(
            id: 100 + i,
            type: TestGeomType.lineString,
            tags: const [0, 0],
            geometryCommands: lineCommands([
              for (var k = 0; k < pointsPerLine; k++)
                (k.isEven ? 40 : 4050, 100 + i * 40 + k * 40),
            ]),
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

    testWidgets('base image resolves before labels are prepared',
        (tester) async {
      final runtime = makeRuntime('label-prep');
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;
      expect(overlay.preparedTileCount, 0);

      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2));
      expect(image, isNotNull, reason: 'the base image must publish first');

      // Labels prepare on the separate lane after publication.
      await tester.runAsync(() async {
        final stopwatch = Stopwatch()..start();
        while (overlay.preparedTileCount == 0 &&
            stopwatch.elapsed < const Duration(seconds: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(overlay.preparedTileCount, greaterThan(0),
          reason: 'labels still prepare, just after the base image publishes');
      image?.dispose();
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

    testWidgets('base image publishes before a failing label preparation',
        (tester) async {
      final runtime = makeRuntime('label-fail');
      addTearDown(runtime.dispose);

      runtime.labelOverlay.debugFailNextPrepare = true;

      ui.Image? image;
      await tester.runAsync(() async {
        image = await runtime.decoder(buildHalfWaterTile(), 12, 3, 2);
      });
      expect(image, isNotNull,
          reason: 'a label failure must not delay or discard the base image');

      // Let the deferred label lane settle; the failed preparation is
      // swallowed and nothing is cached.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(runtime.labelOverlay.preparedTileCount, 0);
      image?.dispose();
    });

    testWidgets('labels notify on a separate notifier after the base image',
        (tester) async {
      final runtime = makeRuntime('label-notify');
      addTearDown(runtime.dispose);

      var notifications = 0;
      runtime.labelsNotifier.addListener(() => notifications++);

      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2));
      expect(image, isNotNull);

      // The label lane runs after the base image resolves.
      await tester.runAsync(() async {
        final stopwatch = Stopwatch()..start();
        while (notifications == 0 &&
            stopwatch.elapsed < const Duration(seconds: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(runtime.labelOverlay.preparedTileCount, greaterThan(0));
      expect(notifications, greaterThan(0),
          reason: 'label-only updates must fire the label notifier');
      image?.dispose();
    });
  });

  group('Label caching and cancellation', () {
    VectorTileRuntime makeRuntime(String namespace,
            {Map<String, dynamic> symbolLayout = const {},
            Map<String, dynamic>? symbolFilter}) =>
        VectorTileRuntime(
          loaded: buildLoadedStyle(
              symbolLayout: symbolLayout, symbolFilter: symbolFilter),
          namespace: namespace,
          parseOffThread: false,
        );

    testWidgets('labels are cached only after text layout completes',
        (tester) async {
      final runtime = makeRuntime('label-store-timing');
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;

      // Parse the source tile via one logical tile; the label lane will
      // prepare *that* tile (12/3/2). Preparing an over-zoom sibling
      // (13/6/4) shares the parsed source without racing the lane.
      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2));
      image?.dispose();

      // 40 point features → 40 build yields, then 40 layout yields. Gate
      // call 41 is the first *layout* yield: the cache must still be empty
      // for this tile at that moment (insertion happens after layout).
      var gateCalls = 0;
      var labelsAtLayoutStart = -1;
      // Everything runs inside one runAsync: the binding forbids a second
      // runAsync while the first is pending, and the gate Completer must
      // be created in the real-async zone — a completer from the test's
      // frozen fake-async zone would never drain its microtasks.
      await tester.runAsync(() async {
        final release = Completer<void>();
        final preparing = overlay.prepare(
          13,
          6,
          4,
          yieldBudget: Duration.zero,
          yieldControl: () async {
            gateCalls++;
            if (gateCalls == 41) {
              labelsAtLayoutStart =
                  overlay.debugPreparedFontSizes(13, 6, 4).length;
              await release.future;
            }
          },
        );
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (labelsAtLayoutStart < 0 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        release.complete();
        await preparing;
      });
      expect(labelsAtLayoutStart, 0,
          reason: 'cache insertion must wait until text layout completes');
      expect(overlay.debugPreparedFontSizes(13, 6, 4), hasLength(40));
    });

    testWidgets('paint after notification performs no text layout',
        (tester) async {
      final runtime = makeRuntime('label-paint-layout');
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;

      var notifications = 0;
      runtime.labelsNotifier.addListener(() => notifications++);

      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2));
      expect(image, isNotNull);
      await tester.runAsync(() async {
        final stopwatch = Stopwatch()..start();
        while (notifications == 0 &&
            stopwatch.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(notifications, greaterThan(0),
          reason: 'labels must be prepared and notified before painting');

      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        overlay.paint(
          canvas,
          const ui.Size(512, 512),
          zoom: 12,
          leftColumnTilesCanvasX: 0,
          topRowTilesCanvasY: 0,
          leftColumnTilesLngIndex: 3,
          topRowTilesLatIndex: 2,
          tiles: [Tile(null, 'label-paint/12/3/2', 2, 3)],
        );
        recorder.endRecording().dispose();
      });
      expect(overlay.debugPaintTimeLayouts, 0,
          reason: 'paint must reuse prepared TextPainters, never lay out');
      image?.dispose();
    });

    testWidgets('prepared-tile cache is bounded', (tester) async {
      final runtime = makeRuntime('label-lru');
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;
      final bytes = buildDenseLabelTile(count: 4);

      // Four parsed z12 source tiles (each also queueing its own label
      // prep on the runtime lane — distinct cache keys, same bound).
      final images = await tester.runAsync(() => Future.wait([
            runtime.decoder(bytes, 12, 3, 2),
            runtime.decoder(bytes, 12, 4, 2),
            runtime.decoder(bytes, 12, 3, 3),
            runtime.decoder(bytes, 12, 4, 3),
          ]));

      // 80 logical over-zoom tiles: 4 z13 + 16 z14 children per source.
      await tester.runAsync(() async {
        for (final (sx, sy) in const [(3, 2), (4, 2), (3, 3), (4, 3)]) {
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              await overlay.prepare(13, sx * 2 + dx, sy * 2 + dy);
            }
          }
          for (var dy = 0; dy < 4; dy++) {
            for (var dx = 0; dx < 4; dx++) {
              await overlay.prepare(14, sx * 4 + dx, sy * 4 + dy);
            }
          }
        }
      });

      expect(overlay.preparedTileCount,
          lessThanOrEqualTo(LabelOverlay.maxPreparedTilesLimit),
          reason: 'the prepared-label cache must stay bounded');
      // 80 direct preps + 4 lane preps exceed the cap of 64, so the LRU
      // must have evicted down to exactly the bound.
      expect(overlay.preparedTileCount, LabelOverlay.maxPreparedTilesLimit);
      for (final image in images!) {
        image.dispose();
      }
    });

    testWidgets(
        'line-label preparation aborting mid-layout disposes the batch and caches nothing',
        (tester) async {
      final runtime = makeRuntime('label-line-cancel', symbolLayout: {
        'symbol-placement': 'line',
        'text-field': ['get', 'name'],
        'text-size': 12,
      });
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;

      final image = await tester
          .runAsync(() => runtime.decoder(buildDenseLineTile(), 12, 3, 2));
      image?.dispose();

      // Prepare a sibling over-zoom tile (same source parent, so identical
      // geometry and label count) successfully to learn the batch size.
      await tester.runAsync(() => overlay.prepare(13, 6, 5));
      final batchLabels = overlay.debugPreparedFontSizes(13, 6, 5).length;
      expect(batchLabels, greaterThan(0),
          reason: 'the fixture must produce line labels');
      final disposedBeforeAbort = overlay.debugDisposedLabels;

      // 24 line features → 24 build yields; flip relevance during the
      // layout phase so the abort hits the pre-insertion cleanup guard
      // with several painters already laid out.
      var gateCalls = 0;
      var stale = false;
      Object? error;
      await tester.runAsync(() async {
        try {
          await overlay.prepare(
            13,
            6,
            4,
            isRelevant: () => !stale,
            yieldBudget: Duration.zero,
            yieldControl: () async {
              gateCalls++;
              if (gateCalls > 24 + 5) stale = true;
            },
          );
        } catch (e) {
          error = e;
        }
      });
      expect(gateCalls, greaterThan(24 + 5),
          reason: 'must abort mid-layout with painters already built');
      expect(error, isA<TileDecodeAborted>());
      expect(overlay.debugPreparedFontSizes(13, 6, 4), isEmpty,
          reason: 'an aborted preparation must leave nothing cached');
      expect(
        overlay.debugDisposedLabels - disposedBeforeAbort,
        batchLabels,
        reason: 'every label of the aborted batch — including the text '
            'painters laid out before the abort — must be disposed',
      );
    });

    testWidgets('zoom-only expression values are shared across tiles',
        (tester) async {
      final runtime = makeRuntime('label-static-exprs', symbolLayout: {
        'text-size': [
          'step',
          ['zoom'],
          9,
          12,
          15
        ],
      });
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;

      final images = await tester.runAsync(() => Future.wait([
            runtime.decoder(buildDenseLabelTile(), 12, 3, 2),
            runtime.decoder(buildDenseLabelTile(), 12, 4, 2),
          ]));

      // Both tiles resolve their shared step expression through one
      // per-zoom style entry: every label at z12 sizes to 15 and only one
      // zoom key is cached.
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (overlay.preparedTileCount < 2 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(overlay.debugPreparedFontSizes(12, 3, 2).toSet(), {15.0});
      expect(overlay.debugPreparedFontSizes(12, 4, 2).toSet(), {15.0});
      expect(overlay.cachedLayerStyleZooms, 1,
          reason: 'tiles at the same zoom share one layer-style entry');

      // A different zoom builds (and caches) its own entry.
      await tester.runAsync(() => overlay.prepare(13, 8, 4));
      expect(overlay.cachedLayerStyleZooms, 2);
      // The z13 entry re-evaluates the step at its own zoom: still 15.
      expect(overlay.debugPreparedFontSizes(13, 8, 4).toSet(), {15.0});

      for (final image in images!) {
        image.dispose();
      }
    });

    testWidgets('data-driven expressions still evaluate per feature',
        (tester) async {
      final runtime = makeRuntime('label-datadriven', symbolLayout: {
        'text-size': ['get', 'rank'],
      });
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;

      final image = await tester.runAsync(() =>
          runtime.decoder(buildDenseLabelTile(withRanks: true), 12, 3, 2));
      expect(image, isNotNull);

      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (overlay.preparedTileCount == 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final sizes = overlay.debugPreparedFontSizes(12, 3, 2).toSet();
      expect(sizes, {10.0, 14.0, 18.0},
          reason: 'each feature must size from its own rank property');
      image?.dispose();
    });

    testWidgets('label preparation drains without starvation while tiles enter',
        (tester) async {
      final runtime = makeRuntime('label-drain');
      addTearDown(runtime.dispose);
      final overlay = runtime.labelOverlay;

      final notificationTimes = <Duration>[];
      final imageTimes = <Duration>[];
      final clock = Stopwatch()..start();
      runtime.labelsNotifier
          .addListener(() => notificationTimes.add(clock.elapsed));
      final tileCount = 12;
      var published = 0;

      // Continuously entering tiles: decode 12 dense tiles; each publish
      // queues label preparation behind the single low-priority lane.
      final images = await tester.runAsync(() async {
        final futures = <Future<ui.Image>>[];
        for (var y = 2; y <= 5; y++) {
          for (var x = 3; x <= 5; x++) {
            futures.add(
                runtime.decoder(buildDenseLabelTile(), 12, x, y).then((image) {
              imageTimes.add(clock.elapsed);
              published++;
              return image;
            }));
          }
        }
        return Future.wait(futures);
      });
      expect(published, tileCount, reason: 'every base image must publish');

      // All label preparations must complete: the lane must drain every
      // queued tile instead of starving behind new arrivals.
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (notificationTimes.length < tileCount &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(notificationTimes, hasLength(tileCount),
          reason: 'no queued tile may be starved out of preparation');
      expect(overlay.preparedTileCount, tileCount);

      // Aggregate drain bound: the last label update must land within a
      // bounded window after the last base image published.
      final drain = notificationTimes.last - imageTimes.last;
      expect(drain, lessThan(const Duration(seconds: 10)),
          reason: 'label latency behind continuous tile entry must stay '
              'bounded (observed drain: $drain)');
      for (final image in images!) {
        image.dispose();
      }
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

    testWidgets('renderAsync disposes the partial picture when cancelled late',
        (tester) async {
      final renderer = VectorTileRenderer(buildLoadedStyle());
      final decoded = decodeVectorTile(buildHalfWaterTile());

      // Relevant for the pre-loop check and the first yield, stale after the
      // resume: cancellation happens after picture recording has started, so
      // the recorder must still be finalized and disposed.
      var calls = 0;
      Object? error;
      await tester.runAsync(() async {
        try {
          final picture = await renderer.renderAsync(
            decoded: decoded,
            srcZ: 12,
            z: 12,
            x: 3,
            y: 2,
            yieldBudget: Duration.zero,
            isRelevant: () => calls++ < 2,
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
