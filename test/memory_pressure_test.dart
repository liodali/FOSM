import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart'
    show FosmMemoryAttribution, MapPolyline, RenderedTileCacheStats;
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/map_controller.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/style/style_parser.dart';
import 'package:fosm/src/view/map_view.dart';
import 'package:fosm/src/view/render.dart';

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

/// Yields to the real event loop until [condition] holds, bounded.
/// Call inside `tester.runAsync`.
Future<void> _runUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition() && stopwatch.elapsed < timeout) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition not met in time');
}

void main() {
  testWidgets('TileManager pressure drops rebuildable caches, keeps the grid',
      (tester) async {
    final png = await tester.runAsync(_pngBytes);
    final manager = TileManager.init(
      width: 512,
      height: 512,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 4,
      tilePadding: 0,
      preloadAdjacentZoom: true,
      fetcher: (_, __, ___) async => png!,
    );
    addTearDown(manager.dispose);
    await tester.runAsync(() async {
      manager.calculate();
      await _runUntil(() => manager.visibleTilesReady);
    });

    // Pan far enough that the first grid is fully replaced. Its images
    // stay retained (budget/retention) and fetched bytes fill the byte
    // cache — the rebuildable pools pressure may reclaim.
    await tester.runAsync(() async {
      manager.setCenterTile(latLng: const LatLng(latitude: 40, longitude: 40));
      manager.calculate();
      await _runUntil(() => manager.visibleTilesReady);
    });

    expect(manager.byteCacheBytes, greaterThan(0));
    expect(manager.renderedCacheStats.evictableBytes, greaterThan(0));

    manager.handleMemoryPressure();

    expect(manager.byteCacheBytes, 0);
    expect(manager.byteCacheEntries, 0);
    final stats = manager.renderedCacheStats;
    expect(stats.evictableBytes, 0,
        reason: 'pressure must reclaim every unprotected image');
    expect(stats.evictableEntries, 0);
    expect(stats.protectedEntries, greaterThan(0),
        reason: 'the visible grid must keep its images');
    expect(stats.protectedBytes, greaterThan(0));
    for (final tile in manager.renderTiles) {
      expect(tile.sourceTile, isNotNull,
          reason: 'visible tiles keep painting after pressure');
    }

    // The map keeps working: another pan loads its tiles from scratch.
    await tester.runAsync(() async {
      manager.setCenterTile(
          latLng: const LatLng(latitude: -40, longitude: -40));
      manager.calculate();
      await _runUntil(() => manager.visibleTilesReady);
    });
    expect(manager.renderedCacheStats.protectedEntries, greaterThan(0));
  });

  testWidgets('TileManager pressure is idempotent and safe after disposal',
      (tester) async {
    final png = await tester.runAsync(_pngBytes);
    final manager = TileManager.init(
      width: 256,
      height: 256,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 3,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      fetcher: (_, __, ___) async => png!,
    );
    await tester.runAsync(() async {
      manager.calculate();
      await _runUntil(() => manager.visibleTilesReady);
      manager.handleMemoryPressure();
      manager.handleMemoryPressure();
      expect(manager.renderedCacheStats.evictableBytes, 0);
      manager.dispose();
      // Must be a no-op, not a crash, on a disposed manager.
      manager.handleMemoryPressure();
    });
  });

  testWidgets(
      'vector runtime pressure drops parsed tiles, raster imagery and '
      'labels, then recovers', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'pressure',
      parseOffThread: false,
    );
    addTearDown(runtime.dispose);
    var labelNotifications = 0;
    runtime.labelsNotifier.addListener(() => labelNotifications++);
    final image = (await tester
        .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 3, 2)))!;
    await tester.runAsync(() => _runUntil(() => labelNotifications > 0));
    addTearDown(image.dispose);

    expect(runtime.parsedTileCount, 1);
    expect(runtime.parsedTileEstimatedBytes, greaterThan(0));
    expect(runtime.labelOverlayPreparedTiles, 1);
    expect(runtime.labelOverlayPreparedLabels, greaterThan(0));
    final notificationsBefore = labelNotifications;

    runtime.handleMemoryPressure();

    expect(runtime.parsedTileCount, 0);
    expect(runtime.parsedTileEstimatedBytes, 0);
    expect(runtime.labelOverlayPreparedTiles, 0);
    expect(runtime.labelOverlayPreparedLabels, 0);
    expect(labelNotifications, notificationsBefore + 1,
        reason: 'the label surface must repaint against released caches');

    // Recovery: the next decode re-populates parsed data and labels.
    final again = (await tester
        .runAsync(() => runtime.decoder(buildDenseLabelTile(), 12, 4, 2)))!;
    await tester
        .runAsync(() => _runUntil(() => runtime.labelOverlayPreparedTiles > 0));
    addTearDown(again.dispose);
    expect(runtime.parsedTileCount, 1);
    expect(runtime.labelOverlayPreparedTiles, 1);
  });

  // Plain `test` (not `testWidgets`): the widget-test binding blocks real
  // HttpClient, but the raster fetch must actually reach a loopback server.
  // The real client is constructed while the global mock is briefly lifted
  // ( constructing it inside the zone override would recurse), then handed
  // to a zone-scoped override so dio's adapter gets a working client.
  Future<void> rasterPressureTest() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final png = await _pngBytes();
    server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.add(png);
      await request.response.close();
    });

    final base = buildLoadedStyle();
    final rasterSource = ResolvedTileSource(
      name: 'relief',
      type: 'raster',
      urlTemplate: 'http://127.0.0.1:${server.port}/relief/{z}/{x}/{y}.png',
      maxZoom: 12,
    );
    // `buildLoadedStyle`'s document has no raster layer, and layer presence
    // is what makes the runtime fetch raster imagery — rebuild the same
    // document with one raster layer over the loopback source.
    final loaded = LoadedVectorStyle(
      style: parseStyleJson(jsonEncode({
        'version': 8,
        'sources': {
          'openmaptiles': {
            'type': 'vector',
            'tiles': ['https://example.invalid/{z}/{x}/{y}.pbf'],
            'maxzoom': 12,
          },
          'relief': {
            'type': 'raster',
            'tiles': [rasterSource.urlTemplate],
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
            'id': 'relief',
            'type': 'raster',
            'source': 'relief',
          },
        ],
      })),
      sources: {...base.sources, rasterSource.name: rasterSource},
    );

    final runtime = VectorTileRuntime(
      loaded: loaded,
      namespace: 'raster-pressure',
      parseOffThread: false,
    );
    addTearDown(runtime.dispose);
    VectorTileRuntime.debugMaxConcurrentDecodesOverride = 1;
    addTearDown(
        () => VectorTileRuntime.debugMaxConcurrentDecodesOverride = null);

    // Decode A fetches and caches the raster source tile.
    final a = await runtime.decoder(buildDenseLabelTile(), 12, 3, 2);
    addTearDown(a.dispose);
    await _runUntil(() => runtime.rasterTileCount > 0);
    final rasterTilesBefore = runtime.rasterTileCount;
    expect(runtime.rasterTileBytes, greaterThan(0));

    // Hold decode B inside the presentation lane, then apply pressure: the
    // raster images must not be disposed while B can still reference them.
    final gate = Completer<void>();
    runtime.debugOnDecodeStarted = (_, __, ___) => gate.future;
    final b = runtime.decoder(buildDenseLabelTile(), 12, 4, 2);
    await _runUntil(() => runtime.debugDecodeOrder.length >= 2);

    runtime.handleMemoryPressure();
    expect(runtime.rasterTileCount, rasterTilesBefore,
        reason: 'flush must defer while a decode is active');

    gate.complete();
    final bImage = await b;
    addTearDown(bImage.dispose);
    await _runUntil(() => runtime.rasterTileCount == 0);
    expect(runtime.rasterTileBytes, 0);
    runtime.debugOnDecodeStarted = null;
  }

  test(
      'raster imagery survives pressure while a decode runs and is '
      'flushed once the lane goes idle', () async {
    final mockOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final realClient = HttpClient();
    HttpOverrides.global = mockOverrides;
    addTearDown(realClient.close);
    await HttpOverrides.runZoned(
      rasterPressureTest,
      createHttpClient: (_) => realClient,
    );
  });

  testWidgets(
      'MapView trims its caches on system memory pressure and '
      'attributes retained memory', (tester) async {
    // Small surface: a full default-sized grid is dozens of tiles and this
    // file is wall-clock bounded.
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final png = await tester.runAsync(_pngBytes);
    final controller = MapController();
    Future<void> settleUntil(bool Function() condition) async {
      final watch = Stopwatch()..start();
      while (!condition() && watch.elapsed < const Duration(seconds: 10)) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(condition(), isTrue, reason: 'condition not met in time');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 3,
            controller: controller,
            tileFetcher: (_, __, ___) async => png!,
          ),
        ),
      ),
    );

    final attribution0 = controller.memoryAttribution;
    expect(attribution0, isNotNull,
        reason: 'the controller must expose attribution once attached');
    bool gridLoaded() {
      final grids = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<RenderCanvasOSM>()
          .toList();
      return grids.isNotEmpty &&
          grids.first.tiles.every((tile) => tile.sourceTile != null);
    }

    // Wait until the whole padded window published: tiles still in flight
    // when the pan starts are aborted, and aborted imagery never becomes
    // evictable retained memory.
    await settleUntil(gridLoaded);
    final oldCount = controller.memoryAttribution!.renderedImages.entries;
    expect(oldCount, greaterThan(0));

    // Pan away to retain a second grid as evictable imagery.
    controller.moveTo(const LatLng(latitude: 45, longitude: 45),
        animate: false);
    await tester.pump();
    await settleUntil(() =>
        controller.memoryAttribution!.renderedImages.protectedEntries > 0 &&
        controller.memoryAttribution!.renderedImages.evictableBytes > 0);

    // The real notification path: the binding forwards pressure to every
    // WidgetsBindingObserver, MapView included.
    tester.binding.handleMemoryPressure();
    await tester.pump();

    final attribution = controller.memoryAttribution!;
    expect(attribution.renderedImages.evictableBytes, 0);
    expect(attribution.renderedImages.protectedEntries, greaterThan(0));
    expect(attribution.renderedImages.entries,
        attribution.renderedImages.protectedEntries);
    expect(attribution.toString(), contains('FOSM memory'));
    expect(attribution.toString(), contains('rendered'));
    // Raster mode: vector buckets report absence, not zeros.
    expect(attribution.parsedTiles, isNull);
    expect(attribution.preparedLabels, isNull);
  });

  testWidgets('attribution counts cached geometry coordinates in its total',
      (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final png = await tester.runAsync(_pngBytes);
    final controller = MapController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 3,
            controller: controller,
            tileFetcher: (_, __, ___) async => png!,
            polylines: const [
              MapPolyline(
                points: [
                  LatLng(latitude: -1, longitude: -1),
                  LatLng(latitude: 0, longitude: 0),
                  LatLng(latitude: 1, longitude: 1),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final attribution = controller.memoryAttribution!;
    expect(attribution.geometryRings, greaterThan(0),
        reason: 'the painted route must be cached');
    expect(attribution.geometryVertexUnits, greaterThan(0));
    // 16 bytes per vertex unit (coordinate storage, index build included).
    expect(attribution.geometryEstimatedBytes,
        attribution.geometryVertexUnits * 16);
    // The probe that motivated this: a geometry-only map must report its
    // coordinates inside the total, not zero.
    expect(attribution.estimatedTotalBytes,
        greaterThanOrEqualTo(attribution.geometryEstimatedBytes));
    expect(attribution.toString(), contains('geometry~'));
  });

  test('attribution types are exported from the public barrel', () {
    // Compile-level guarantee: typed consumers importing only
    // package:fosm/fosm.dart can name the attribution types.
    const attribution = FosmMemoryAttribution(
      renderedImages: RenderedTileCacheStats.empty(),
      compressedBytes: 0,
      compressedEntries: 0,
      geometryRings: 1,
      geometryVertexUnits: 100,
      geometryEstimatedBytes: 1600,
      inFlightLoads: 0,
      queuedLoads: 0,
      pendingPresentations: 0,
      pendingFetches: 0,
    );
    expect(attribution.estimatedTotalBytes, 1600);
  });
}
