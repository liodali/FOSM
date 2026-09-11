import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/lat_lng_bounds.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/api/tile_source.dart'
    show TilePayloadException, tileUrl;
import 'package:fosm/src/common/cache_tile_mixin.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:hive_ce/hive.dart';

/// Minimal valid 1×1 RGBA PNG — decodable by Flutter's image codec.
final Uint8List fakeTilePng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, // IHDR length
  0x49, 0x48, 0x44, 0x52, // IHDR
  0x00, 0x00, 0x00, 0x01, // width = 1
  0x00, 0x00, 0x00, 0x01, // height = 1
  0x08, 0x06, 0x00, 0x00, 0x00, // 8-bit RGBA
  0x1F, 0x15, 0xC4, 0x89, // CRC
  0x00, 0x00, 0x00, 0x0A, // IDAT length
  0x49, 0x44, 0x41, 0x54, // IDAT
  0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
  0x0D, 0x0A, 0x2D, 0xB4, // CRC
  0x00, 0x00, 0x00, 0x00, // IEND length
  0x49, 0x45, 0x4E, 0x44, // IEND
  0xAE, 0x42, 0x60, 0x82, // CRC
]);

/// Fake fetcher that returns [fakeTilePng] for any tile.
Future<Uint8List> _fakeFetcher(int z, int x, int y) async => fakeTilePng;

/// Fake fetcher that always fails (simulates network error).
Future<Uint8List> _failingFetcher(int z, int x, int y) async =>
    throw Exception('network error');

/// Yields to the real event loop until [condition] holds, with a bounded
/// timeout. Used instead of fixed sleeps so tests prove observable behavior.
Future<void> _runUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  await tester.runAsync(() async {
    final stopwatch = Stopwatch()..start();
    while (!condition() && stopwatch.elapsed < timeout) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
  expect(condition(), isTrue,
      reason: 'condition not met within ${timeout.inSeconds}s');
}

/// Lets already-scheduled real async work run for a bounded number of turns.
Future<void> _flushAsync(WidgetTester tester, {int turns = 20}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
}

void main() {
  group('TileManager grid construction', () {
    test('creates one tile per visible cell (no duplicates)', () {
      final manager = TileManager.init(
        width: 800,
        height: 600,
        centerLatLng: LatLng(latitude: 47.4358, longitude: 8.4737),
        zoom: 7,
        fetcher: _fakeFetcher,
        tilePadding: 0, // disable padding for this test
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      final expected = manager.horizontalTileCount * manager.verticalTileCount;
      expect(manager.renderTiles.length, expected);
      expect(expected, greaterThan(0));

      // All indices should be unique.
      final keys = manager.renderTiles.map((t) => t.index).toSet();
      expect(keys.length, expected);

      manager.dispose();
    });

    test('tile keys include zoom level', () {
      final manager = TileManager.init(
        width: 400,
        height: 400,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      for (final tile in manager.renderTiles) {
        expect(tile.index, startsWith('5/'));
      }

      manager.dispose();
    });

    test('grid covers the viewport center', () {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 1,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // At z=1, the world is 2×2 tiles. Center is tile (1, 1).
      // With a 256×256 viewport we need at least 1×1 = 1 tile,
      // possibly 2×2 if the center is not tile-aligned.
      expect(manager.renderTiles.length, greaterThanOrEqualTo(1));

      // Center tile should be present.
      final centerKey = TileManager.tileKey(1, 1, 1);
      final hasCenter = manager.renderTiles.any((t) => t.index == centerKey);
      expect(hasCenter, isTrue);

      manager.dispose();
    });

    test('tilePadding expands the grid', () {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        tilePadding: 2,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // With padding=2, the grid should be larger than without padding.
      // The exact size depends on the viewport, but it should be at least
      // (visibleH + 4) × (visibleV + 4).
      expect(manager.renderTiles.length, greaterThan(9));

      manager.dispose();
    });
  });

  group('TileManager center clamping', () {
    test('setCenterTile clamps latitude', () {
      final manager = TileManager.init(
        width: 400,
        height: 400,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
      );
      addTearDown(manager.dispose);

      manager.setCenterTile(
        latLng: LatLng(latitude: 95, longitude: 0),
      );
      expect(
          manager.centerLatLng.latitude, closeTo(maxWebMercatorLatitude, 0.01));

      manager.setCenterTile(
        latLng: LatLng(latitude: -95, longitude: 0),
      );
      expect(manager.centerLatLng.latitude,
          closeTo(-maxWebMercatorLatitude, 0.01));

      manager.dispose();
    });

    test('setCenterFromTileCoords clamps to world bounds', () {
      final manager = TileManager.init(
        width: 400,
        height: 400,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
      );
      addTearDown(manager.dispose);

      // Try to set center beyond the world edge.
      manager.setCenterFromTileCoords(-10, -10);
      expect(manager.centerTileLng, 0.0);
      expect(manager.centerTileLat, 0.0);

      manager.setCenterFromTileCoords(100, 100);
      expect(manager.centerTileLng, 8.0); // 2^3 = 8
      expect(manager.centerTileLat, 8.0);

      manager.dispose();
    });
  });

  group('TileManager async tile loading', () {
    testWidgets('fetches tiles and fills placeholders', (tester) async {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 1,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // All tiles start as placeholders (null image).
      expect(manager.renderTiles.every((t) => t.sourceTile == null), isTrue);

      // Use runAsync to let real async (image codec) complete.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pump();

      // After fetches, all tiles should have images.
      final loaded =
          manager.renderTiles.where((t) => t.sourceTile != null).length;
      expect(loaded, manager.renderTiles.length);

      manager.dispose();
    });

    testWidgets('deduplicates concurrent fetches', (tester) async {
      var fetchCount = 0;
      Future<Uint8List> countingFetcher(int z, int x, int y) async {
        fetchCount++;
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 1,
        fetcher: countingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      // Call calculate multiple times rapidly (simulates drag).
      manager.calculate();
      manager.calculate();
      manager.calculate();

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pump();

      // Each unique tile should only be fetched once despite multiple
      // calculate() calls.
      final uniqueTiles =
          manager.renderTiles.map((t) => t.index).toSet().length;
      expect(fetchCount, uniqueTiles);

      manager.dispose();
    });

    testWidgets('handles fetch failures gracefully', (tester) async {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 1,
        fetcher: _failingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      // Tiles remain as placeholders — no crash.
      expect(manager.renderTiles.isNotEmpty, isTrue);

      manager.dispose();
    });
  });

  group('TileManager memory cache', () {
    testWidgets('memory cache hit avoids re-fetch on recalculate',
        (tester) async {
      var fetchCount = 0;
      Future<Uint8List> countingFetcher(int z, int x, int y) async {
        fetchCount++;
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 1,
        fetcher: countingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pump();

      final firstFetchCount = fetchCount;
      expect(firstFetchCount, greaterThan(0));

      // Recalculate — all tiles should be in memory cache.
      manager.calculate();
      expect(fetchCount, firstFetchCount); // no new fetches

      manager.dispose();
    });
  });

  group('TileManager disposal', () {
    testWidgets('dispose prevents further callbacks', (tester) async {
      var callbackCount = 0;
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 1,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);
      manager.onTilesChanged = () => callbackCount++;

      manager.calculate();
      manager.dispose();

      // Drain any pending async work.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      // onTilesChanged should not have been called after dispose.
      expect(callbackCount, 0);
    });
  });

  group('TileManager zoom', () {
    test('setZoom changes zoom level and recalculates', () {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      expect(manager.zoom, 3);
      final tilesAtZ3 = manager.renderTiles.length;
      expect(tilesAtZ3, greaterThan(0));

      manager.setZoom(5);
      expect(manager.zoom, 5);
      final tilesAtZ5 = manager.renderTiles.length;
      expect(tilesAtZ5, greaterThan(0));

      // Tile keys should be different at different zoom levels.
      final keysAtZ3 =
          manager.renderTiles.where((t) => t.index.startsWith('3/')).length;
      final keysAtZ5 =
          manager.renderTiles.where((t) => t.index.startsWith('5/')).length;
      // After setZoom(5), all tiles should be at z=5.
      expect(keysAtZ3, 0);
      expect(keysAtZ5, tilesAtZ5);

      manager.dispose();
    });

    test('setZoomWithFocalPoint preserves geographic point under focal', () {
      final manager = TileManager.init(
        width: 512,
        height: 512,
        centerLatLng: LatLng(latitude: 47.0, longitude: 8.0),
        zoom: 5,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // The focal point is at the center of the widget.
      final focal = const Offset(256, 256);
      final focalLngBefore = tileX2Lng(
        manager.centerTileLng + (focal.dx - manager.centerCanvasX) / tileWidth,
        manager.zoom,
      );
      final focalLatBefore = tileY2Lat(
        manager.centerTileLat + (focal.dy - manager.centerCanvasY) / tileHeight,
        manager.zoom,
      );

      // Zoom in with focal point at center.
      manager.setZoomWithFocalPoint(6, focal, 5);

      // The geographic point under the focal should be the same.
      final focalLngAfter = tileX2Lng(
        manager.centerTileLng + (focal.dx - manager.centerCanvasX) / tileWidth,
        manager.zoom,
      );
      final focalLatAfter = tileY2Lat(
        manager.centerTileLat + (focal.dy - manager.centerCanvasY) / tileHeight,
        manager.zoom,
      );

      expect(focalLngAfter, closeTo(focalLngBefore, 0.01));
      expect(focalLatAfter, closeTo(focalLatBefore, 0.01));

      manager.dispose();
    });

    test('tile keys change when zoom changes', () {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      final keysAtZ3 = manager.renderTiles.map((t) => t.index).toSet();
      expect(keysAtZ3.every((k) => k.startsWith('3/')), isTrue);

      manager.setZoom(5);
      final keysAtZ5 = manager.renderTiles.map((t) => t.index).toSet();
      expect(keysAtZ5.every((k) => k.startsWith('5/')), isTrue);

      // No overlap between zoom levels.
      expect(keysAtZ3.intersection(keysAtZ5).isEmpty, isTrue);

      manager.dispose();
    });
  });

  group('TileManager pre-loading', () {
    testWidgets('padding loads extra tiles beyond viewport', (tester) async {
      var fetchCount = 0;
      Future<Uint8List> countingFetcher(int z, int x, int y) async {
        fetchCount++;
        return fakeTilePng;
      }

      // Without padding.
      final managerNoPadding = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: countingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(managerNoPadding.dispose);
      managerNoPadding.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      final fetchesNoPadding = fetchCount;
      managerNoPadding.dispose();

      // With padding.
      fetchCount = 0;
      final managerWithPadding = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: countingFetcher,
        tilePadding: 2,
        preloadAdjacentZoom: false,
      );
      addTearDown(managerWithPadding.dispose);
      managerWithPadding.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      final fetchesWithPadding = fetchCount;
      managerWithPadding.dispose();

      // Padding should cause more fetches.
      expect(fetchesWithPadding, greaterThan(fetchesNoPadding));
    });

    testWidgets('adjacent zoom pre-loads tiles at z±1', (tester) async {
      final fetchedZooms = <int>{};
      Future<Uint8List> trackingFetcher(int z, int x, int y) async {
        fetchedZooms.add(z);
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        fetcher: trackingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: true,
        preloadDebounce: Duration.zero,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // Visible z=5 work runs first; adjacent-zoom preloads only start once
      // the foreground slots free. Drain with a bounded real-async loop so
      // the image codec can complete (instead of an unbounded settle wait).
      await tester.runAsync(() async {
        final timeout = Stopwatch()..start();
        while ((!fetchedZooms.contains(4) || !fetchedZooms.contains(6)) &&
            timeout.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      await tester.pump();

      // Should have fetched tiles at z=5 (visible) and z=4, z=6 (adjacent).
      expect(fetchedZooms.contains(5), isTrue,
          reason: 'Should fetch visible tiles at z=5');
      expect(fetchedZooms.contains(4), isTrue, reason: 'Should preload z=4');
      expect(fetchedZooms.contains(6), isTrue, reason: 'Should preload z=6');

      manager.dispose();
    });

    testWidgets('zoom change uses cached tiles from pre-load', (tester) async {
      var fetchCount = 0;
      Future<Uint8List> countingFetcher(int z, int x, int y) async {
        fetchCount++;
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        fetcher: countingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: true,
        preloadDebounce: Duration.zero,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pump();
      final fetchesBeforeZoom = fetchCount;

      // Zoom in — some tiles should already be in cache from pre-loading.
      manager.setZoom(6);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pump();
      final fetchesAfterZoom = fetchCount;

      // Some new fetches for tiles not in the pre-loaded set,
      // but fewer than if we had no pre-loading.
      expect(fetchesAfterZoom, greaterThan(fetchesBeforeZoom));

      manager.dispose();
    });
  });

  group('byteOnlyPadding (vector-style padding policy)', () {
    /// A decoder that counts how many times it is invoked and returns a
    /// 1×1 image. In vector mode the decoder is the expensive
    /// parse+render+toImage pipeline, so the count is the signal we care
    /// about.
    // ignore: no_leading_underscores_for_local_identifiers
    int _decodeCount = 0;
    // ignore: no_leading_underscores_for_local_identifiers
    Future<ui.Image> _countingDecoder(
        Uint8List bytes, int z, int x, int y) async {
      _decodeCount++;
      return Tile.decodeImage(bytes);
    }

    setUp(() => _decodeCount = 0);

    testWidgets('only visible tiles are decoded; padding is bytes-only',
        (tester) async {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: _countingDecoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      // Let the byte-only padding preloads and visible decodes settle.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      // With a 256×256 viewport and 256px tiles there is roughly 1
      // visible tile (plus partials). The 2-tile padding ring on every
      // side must NOT go through the decoder.
      final visibleH = manager.horizontalTileCount - 2 * 2;
      final visibleV = manager.verticalTileCount - 2 * 2;
      final maxVisibleDecodes = visibleH * visibleV;
      expect(_decodeCount, lessThanOrEqualTo(maxVisibleDecodes),
          reason: 'padding tiles must not be decoded when byteOnlyPadding');
      expect(_decodeCount, greaterThan(0),
          reason: 'visible tiles must still be decoded');

      manager.dispose();
    });

    testWidgets('padding tiles do not notify on completion', (tester) async {
      var notifications = 0;
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: _countingDecoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);
      manager.onTilesChanged = () => notifications++;

      manager.calculate();
      // Snapshot the notification count after visible tiles settle.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      final notificationsAfterVisible = notifications;

      // Wait longer so any padding byte preloads finish. They must not
      // produce additional notifications.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      expect(notifications, notificationsAfterVisible,
          reason: 'padding byte-only completion must not notify');

      manager.dispose();
    });

    testWidgets('a prefetched padding tile decodes when it becomes visible',
        (tester) async {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: _countingDecoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      // Let padding bytes preload.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      final decodesBeforePan = _decodeCount;

      // Pan the center by one tile so a previously-padding tile enters
      // the visible area. Its bytes are already in the byte cache, so it
      // should decode without a network fetch.
      manager.setCenterTile(
        latLng: const LatLng(latitude: 0, longitude: 0),
      );
      // Shift center by ~one tile east at zoom 3.
      final oneTileLng = tileX2Lng(1, 3) - tileX2Lng(0, 3);
      manager.setCenterTile(
        latLng: LatLng(latitude: 0, longitude: oneTileLng),
      );
      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      // The newly-visible tile decodes from the byte cache.
      expect(_decodeCount, greaterThan(decodesBeforePan),
          reason: 'a padding tile entering the viewport must decode');

      manager.dispose();
    });

    testWidgets('raster defaults: byteOnlyPadding=false still decodes padding',
        (tester) async {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: _countingDecoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        // byteOnlyPadding defaults to false — raster behaviour.
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      // Raster mode decodes the whole padded grid (padding decodes are
      // cheap), so the decode count is well above the single visible tile.
      expect(_decodeCount, greaterThan(1),
          reason: 'raster mode must decode padding tiles too');

      manager.dispose();
    });
  });

  /// Bigger than the 800×600 viewport at zoom 5 in both axes, so the
  /// clamp (not the center-pin) applies.
  final largeBounds = LatLngBounds(
    southwest: const LatLng(latitude: -60, longitude: -80),
    northeast: const LatLng(latitude: 60, longitude: 80),
  );

  TileManager boundedManager() {
    final manager = TileManager.init(
      width: 800,
      height: 600,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      fetcher: _fakeFetcher,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      cameraBounds: largeBounds,
    );
    addTearDown(manager.dispose);
    manager.calculate();
    return manager;
  }

  /// Whether the viewport (given the manager's current camera) stays
  /// within [bounds] at the current zoom.
  bool viewportInside(TileManager manager, LatLngBounds bounds) {
    final halfW = manager.width / (2 * tileWidth);
    final halfH = manager.height / (2 * tileHeight);
    return tileX2Lng(manager.centerTileLng - halfW, manager.zoom) >=
            bounds.west - 0.01 &&
        tileX2Lng(manager.centerTileLng + halfW, manager.zoom) <=
            bounds.east + 0.01 &&
        tileY2Lat(manager.centerTileLat - halfH, manager.zoom) <=
            bounds.north + 0.01 &&
        tileY2Lat(manager.centerTileLat + halfH, manager.zoom) >=
            bounds.south - 0.01;
  }

  group('TileManager cameraBounds', () {
    test('setCenterFromTileCoords clamps at the box edges', () {
      final manager = boundedManager();

      // Far outside the box on both axes.
      manager.setCenterFromTileCoords(0, 0);
      expect(viewportInside(manager, largeBounds), isTrue);

      manager.setCenterFromTileCoords(31, 10);
      expect(viewportInside(manager, largeBounds), isTrue);

      manager.dispose();
    });

    test('setCenterTile clamps at the box edges', () {
      final manager = boundedManager();

      manager.setCenterTile(
        latLng: const LatLng(latitude: 50, longitude: 150),
      );
      expect(viewportInside(manager, largeBounds), isTrue);

      manager.dispose();
    });

    test('bounds smaller than the viewport pin the camera to their center', () {
      final manager = TileManager.init(
        width: 800,
        height: 600,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
        cameraBounds: LatLngBounds(
          southwest: const LatLng(latitude: -1, longitude: -1),
          northeast: const LatLng(latitude: 1, longitude: 1),
        ),
      );
      addTearDown(manager.dispose);
      manager.calculate();

      manager.setCenterFromTileCoords(2, 2);
      expect(manager.centerLatLng.longitude, closeTo(0, 0.01));
      expect(manager.centerLatLng.latitude, closeTo(0, 0.01));

      manager.dispose();
    });

    test('setCameraBounds snaps an outside camera inside; null frees it', () {
      final manager = TileManager.init(
        width: 800,
        height: 600,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);
      manager.calculate();

      manager.setCenterTile(
        latLng: const LatLng(latitude: 30, longitude: 150),
      );
      expect(manager.centerLatLng.longitude, closeTo(150, 0.01));

      manager.setCameraBounds(largeBounds);
      expect(viewportInside(manager, largeBounds), isTrue);

      // Removing the constraint lets the camera leave the box again.
      manager.setCameraBounds(null);
      manager.setCenterTile(
        latLng: const LatLng(latitude: 30, longitude: 150),
      );
      expect(manager.centerLatLng.longitude, closeTo(150, 0.01));

      manager.dispose();
    });

    test('resize re-clamps against the new viewport size', () {
      final manager = boundedManager();

      // A tall viewport: the ±60° latitude span (≈13.4 tiles at zoom 5)
      // is now smaller than the viewport (≈14.8 tiles) → the camera pins
      // to the box's vertical center, while horizontally it still clamps.
      manager.resize(const ui.Size(1400, 3800));
      expect(manager.centerLatLng.latitude, closeTo(0, 0.01));

      // Vertical is pinned (the viewport is taller than the box), so the
      // viewport legitimately extends past north/south — check that the
      // horizontal clamp still holds.
      final halfW = manager.width / (2 * tileWidth);
      expect(
        tileX2Lng(manager.centerTileLng - halfW, manager.zoom),
        greaterThanOrEqualTo(largeBounds.west - 0.01),
      );
      expect(
        tileX2Lng(manager.centerTileLng + halfW, manager.zoom),
        lessThanOrEqualTo(largeBounds.east + 0.01),
      );

      manager.dispose();
    });
  });

  group('strict viewport readiness', () {
    testWidgets('visibleTilesReady ignores bytes-only padding', (tester) async {
      var decodes = 0;
      Future<ui.Image> decoder(Uint8List b, int z, int x, int y) async {
        decodes++;
        return Tile.decodeImage(b);
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: decoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      expect(manager.visibleTilesReady, isFalse);
      expect(manager.missingVisibleTileCount, greaterThan(0));

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      // The strict viewport is ready even though the bytes-only padding
      // ring intentionally never decodes.
      expect(manager.visibleTilesReady, isTrue);
      expect(manager.missingVisibleTileCount, 0);
      expect(decodes, greaterThan(0));
      expect(manager.renderTiles.any((t) => t.sourceTile == null), isTrue,
          reason: 'padding tiles stay undecoded in vector mode');

      manager.dispose();
    });

    test('missingVisibleTileCount ignores invalid world rows', () {
      final manager = TileManager.init(
        width: 800,
        height: 600,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 0,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // At z0 the world is one tile row. The tall viewport spans several
      // out-of-world rows that can never load, so only the valid row
      // counts as missing.
      expect(manager.visibleTileCount, greaterThan(1));
      expect(
          manager.missingVisibleTileCount, lessThan(manager.visibleTileCount));
      expect(manager.missingVisibleTileCount, 5);
      expect(manager.visibleTilesReady, isFalse);

      manager.dispose();
    });

    test('calculate advances revision and generation only on real changes', () {
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: _fakeFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      final revision = manager.revision;
      final generation = manager.generation;

      // A redundant recalculation (e.g. from build()) must not bump
      // either counter.
      manager.calculate();
      expect(manager.revision, revision);
      expect(manager.generation, generation);

      manager.setZoom(4);
      expect(manager.generation, greaterThan(generation));
      expect(manager.revision, greaterThan(revision));

      manager.dispose();
    });
  });

  group('generation-aware scheduler', () {
    testWidgets('stale fetched bytes are cached but never decoded',
        (tester) async {
      final pending = <Completer<Uint8List>>[];
      final decoded = <String>[];

      Future<Uint8List> slowFetcher(int z, int x, int y) {
        final completer = Completer<Uint8List>();
        pending.add(completer);
        return completer.future;
      }

      Future<ui.Image> recordingDecoder(Uint8List b, int z, int x, int y) {
        decoded.add('$z/$x/$y');
        return Tile.decodeImage(b);
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: slowFetcher,
        decoder: recordingDecoder,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      final oldKeys = manager.renderTiles.map((t) => t.index).toSet().toList();
      expect(pending, isNotEmpty);

      // Jump to the opposite corner before any fetch resolves.
      manager.setCenterFromTileCoords(8, 8);
      manager.calculate();

      // Resolve every outstanding fetch, old and new. New-generation jobs
      // start as the bounded foreground slots free, so keep completing them
      // until the current viewport decodes. Readiness is strict-viewport
      // only: the corner viewport includes out-of-world rows that can never
      // load, so `renderTiles.every(...)` would wait forever.
      await tester.runAsync(() async {
        final timeout = Stopwatch()..start();
        while (timeout.elapsed < const Duration(seconds: 5)) {
          for (final completer in List<Completer<Uint8List>>.of(pending)) {
            if (!completer.isCompleted) completer.complete(fakeTilePng);
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (decoded.isNotEmpty && manager.visibleTilesReady) break;
        }
      });
      await tester.pump();

      // Old tiles left the render set: their bytes are retained but they
      // are never decoded.
      for (final key in oldKeys) {
        final parts = key.split('/');
        final decodedKey = '${parts[0]}/${parts[1]}/${parts[2]}';
        expect(decoded.contains(decodedKey), isFalse,
            reason: 'stale tile $key must not be decoded');
      }
      expect(decoded, isNotEmpty, reason: 'the current viewport still decodes');

      manager.dispose();
    });

    testWidgets('preloads wait until visible network work finishes',
        (tester) async {
      final fetchedZooms = <int>[];
      final visibleCompleters = <Completer<Uint8List>>[];

      Future<Uint8List> fetcher(int z, int x, int y) {
        fetchedZooms.add(z);
        if (z == 5) {
          final completer = Completer<Uint8List>();
          visibleCompleters.add(completer);
          return completer.future;
        }
        return Future<Uint8List>.value(fakeTilePng);
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 5,
        fetcher: fetcher,
        tilePadding: 0,
        preloadAdjacentZoom: true,
        preloadDebounce: Duration.zero,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.pump();

      // Visible z5 requests are pending — no adjacent-zoom preload yet.
      expect(visibleCompleters, isNotEmpty);
      expect(fetchedZooms.where((z) => z != 5), isEmpty,
          reason: 'preloads must not start while visible work waits');

      // Finish the visible fetches: preloads may now use spare capacity.
      await tester.runAsync(() async {
        for (final completer in visibleCompleters) {
          if (!completer.isCompleted) completer.complete(fakeTilePng);
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(fetchedZooms.contains(6), isTrue);
      expect(fetchedZooms.contains(4), isTrue);

      manager.dispose();
    });

    testWidgets('a padding tile promoted to visible decodes without re-fetch',
        (tester) async {
      final fetchCounts = <String, int>{};
      Future<Uint8List> countingFetcher(int z, int x, int y) async {
        final key = '$z/$x/$y';
        fetchCounts[key] = (fetchCounts[key] ?? 0) + 1;
        return fakeTilePng;
      }

      var decodes = 0;
      Future<ui.Image> decoder(Uint8List b, int z, int x, int y) async {
        decodes++;
        return Tile.decodeImage(b);
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: countingFetcher,
        decoder: decoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      final decodesBeforePan = decodes;

      // Pan one tile east: a prefetched padding tile enters the viewport.
      final oneTileLng = tileX2Lng(1, 3) - tileX2Lng(0, 3);
      manager.setCenterTile(
        latLng: LatLng(latitude: 0, longitude: oneTileLng),
      );
      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      expect(fetchCounts.values.every((count) => count == 1), isTrue,
          reason: 'no tile may be fetched twice: $fetchCounts');
      expect(decodes, greaterThan(decodesBeforePan),
          reason: 'the promoted tile decodes from the byte cache');

      manager.dispose();
    });

    testWidgets('failures back off instead of retrying immediately',
        (tester) async {
      var attempts = 0;
      Future<Uint8List> failingFetcher(int z, int x, int y) async {
        attempts++;
        throw Exception('network error');
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: failingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      final attemptsAfterFailure = attempts;
      expect(attemptsAfterFailure, greaterThan(0));

      // Recalculating inside the backoff window must not retry.
      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(attempts, attemptsAfterFailure);

      manager.dispose();
    });

    testWidgets('dispose ignores late fetch completions', (tester) async {
      final pending = <Completer<Uint8List>>[];
      var callbacks = 0;

      Future<Uint8List> hangingFetcher(int z, int x, int y) {
        final completer = Completer<Uint8List>();
        pending.add(completer);
        return completer.future;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: hangingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);
      manager.onTilesChanged = () => callbacks++;

      manager.calculate();
      manager.dispose();

      await tester.runAsync(() async {
        for (final completer in pending) {
          if (!completer.isCompleted) completer.complete(fakeTilePng);
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(callbacks, 0);

      manager.dispose();
    });
  });

  group('bounded tile scheduler', () {
    testWidgets('bounds concurrent visible fetches to the visible limit',
        (tester) async {
      final started = <String>[];
      final completers = <String, Completer<Uint8List>>{};

      Future<Uint8List> fetcher(int z, int x, int y) {
        final key = '$z/$x/$y';
        started.add(key);
        final completer = Completer<Uint8List>();
        completers[key] = completer;
        return completer.future;
      }

      final manager = TileManager.init(
        width: 1024,
        height: 1024,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // More visible tiles than the concurrency cap: excess jobs stay queued
      // so they never leave the queue immediately.
      expect(manager.renderTiles.length,
          greaterThan(TileManager.maxConcurrentVisibleLoads));
      expect(started.length, TileManager.maxConcurrentVisibleLoads);
      expect(started.length, lessThan(manager.renderTiles.length));

      // Completing one job frees exactly one slot for the next queued job.
      completers[started.first]!.complete(fakeTilePng);
      await _runUntil(
          tester, () => started.length > TileManager.maxConcurrentVisibleLoads);
      expect(started.length, TileManager.maxConcurrentVisibleLoads + 1);

      manager.dispose();
    });

    testWidgets('freed slot serves the current viewport, not stale work',
        (tester) async {
      final started = <String>[];
      final completers = <String, Completer<Uint8List>>{};

      Future<Uint8List> fetcher(int z, int x, int y) {
        final key = '$z/$x/$y';
        started.add(key);
        final completer = Completer<Uint8List>();
        completers[key] = completer;
        return completer.future;
      }

      final manager = TileManager.init(
        width: 1024,
        height: 1024,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      final oldKeys = manager.renderTiles.map((t) => t.index).toSet();
      expect(started.length, TileManager.maxConcurrentVisibleLoads);

      // Pan one tile east. Some tiles leave the grid and some enter it while
      // the six foreground slots are still occupied by old requests.
      final oneTileLng = tileX2Lng(1, 3) - tileX2Lng(0, 3);
      manager.setCenterTile(latLng: LatLng(latitude: 0, longitude: oneTileLng));
      manager.calculate();

      final newKeys = manager.renderTiles.map((t) => t.index).toSet();
      final stale = oldKeys.difference(newKeys);
      expect(stale, isNotEmpty, reason: 'the pan must drop old tiles');

      final startedBefore = started.toSet();
      completers[started.first]!.complete(fakeTilePng);
      await _runUntil(
          tester, () => started.length > TileManager.maxConcurrentVisibleLoads);

      final newlyStarted =
          started.where((key) => !startedBefore.contains(key)).toList();
      expect(newlyStarted, isNotEmpty);
      expect(newKeys.contains(newlyStarted.first), isTrue,
          reason: 'the freed slot must serve the current viewport');
      expect(stale.contains(newlyStarted.first), isFalse,
          reason: 'stale work must not take the freed slot');

      manager.dispose();
    });

    testWidgets('bytes-only padding preloads wait for visible work',
        (tester) async {
      final started = <String>[];
      final completers = <String, Completer<Uint8List>>{};

      Future<Uint8List> fetcher(int z, int x, int y) {
        final key = '$z/$x/$y';
        started.add(key);
        final completer = Completer<Uint8List>();
        completers[key] = completer;
        return completer.future;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      final visibleCount = manager.missingVisibleTileCount;
      expect(visibleCount, greaterThan(0));
      // Only strict-visible work starts; the bytes-only padding ring waits
      // while visible work is outstanding.
      expect(started.length, visibleCount);
      expect(started.length, lessThan(manager.renderTiles.length));

      // Complete the visible work: padding preloads may now use spare
      // capacity (bounded by the background limit).
      for (final key in started.toList()) {
        completers[key]!.complete(fakeTilePng);
      }
      await _runUntil(tester, () => started.length > visibleCount);
      expect(started.length, greaterThan(visibleCount));

      manager.dispose();
    });

    testWidgets('a camera move starts no new background while visible waits',
        (tester) async {
      late TileManager manager;
      final started = <String>[];
      final backgroundStarted = <String>[];
      final completers = <String, Completer<Uint8List>>{};

      bool relevant(String key) {
        final parts = key.split('/');
        return manager.isTileRelevant(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
      }

      Future<Uint8List> fetcher(int z, int x, int y) {
        final key = '$z/$x/$y';
        started.add(key);
        if (!manager.isTileRelevant(z, x, y)) backgroundStarted.add(key);
        final completer = Completer<Uint8List>();
        completers[key] = completer;
        return completer.future;
      }

      manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      manager.calculate();

      // Finish the strict-visible work so background padding preloads start.
      for (final key in started.where(relevant).toList()) {
        completers[key]!.complete(fakeTilePng);
      }
      await _runUntil(
          tester,
          () =>
              backgroundStarted.length >=
              TileManager.maxConcurrentBackgroundLoads);
      final backgroundBefore = backgroundStarted.length;
      expect(backgroundBefore, greaterThan(0),
          reason: 'background preloads must already be active');

      // Move the camera while the new visible requests stay unresolved.
      final oneTileLng = tileX2Lng(1, 3) - tileX2Lng(0, 3);
      manager.setCenterTile(
        latLng: LatLng(latitude: 0, longitude: oneTileLng),
      );
      manager.calculate();
      await _flushAsync(tester);

      // The active background jobs cannot be cancelled, but no *additional*
      // background job may start while new visible work waits.
      expect(backgroundStarted.length, backgroundBefore,
          reason: 'a camera move must not launch more background work');

      // Finally let the new visible work finish: background resumes.
      for (final key in started.where(relevant).toList()) {
        final completer = completers[key];
        if (completer != null && !completer.isCompleted) {
          completer.complete(fakeTilePng);
        }
      }
      await _runUntil(
          tester, () => backgroundStarted.length > backgroundBefore);
    });
  });

  group('strict decode relevance in vector mode', () {
    testWidgets('a visible tile moved into padding is not published',
        (tester) async {
      final decoders = <String, Completer<ui.Image>>{};
      var notifications = 0;

      Future<Uint8List> fetcher(int z, int x, int y) async => fakeTilePng;

      Future<ui.Image> decoder(Uint8List b, int z, int x, int y) {
        final completer = Completer<ui.Image>();
        decoders['$z/$x/$y'] = completer;
        return completer.future;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        decoder: decoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);
      manager.onTilesChanged = () => notifications++;
      manager.calculate();
      await _runUntil(tester, () => decoders.isNotEmpty);

      // Pan one tile east: a former visible column becomes padding while
      // remaining on the padded render grid.
      final oneTileLng = tileX2Lng(1, 3) - tileX2Lng(0, 3);
      manager.setCenterTile(latLng: LatLng(latitude: 0, longitude: oneTileLng));
      manager.calculate();

      String? target;
      for (final entry in decoders.entries) {
        final parts = entry.key.split('/');
        final z = int.parse(parts[0]);
        final x = int.parse(parts[1]);
        final y = int.parse(parts[2]);
        if (manager.renderTiles.any((t) => t.index == entry.key) &&
            !manager.isTileRelevant(z, x, y)) {
          target = entry.key;
          break;
        }
      }
      expect(target, isNotNull,
          reason: 'the pan must move a decoded visible tile into padding');
      expect(manager.renderTiles.any((t) => t.index == target), isTrue,
          reason: 'the tile stays on the padded render grid');

      final notificationsBefore = notifications;
      final image = await tester.runAsync(() => Tile.decodeImage(fakeTilePng));
      decoders[target!]!.complete(image!);
      await _flushAsync(tester);

      final tile = manager.renderTiles.firstWhere((t) => t.index == target);
      expect(tile.sourceTile, isNull,
          reason: 'a padding tile must not publish an image');
      expect(notifications, notificationsBefore,
          reason: 'an aborted decode must not repaint');

      manager.dispose();
    });
  });

  group('calculate fast path', () {
    testWidgets('unchanged calculate does no work but retries after backoff',
        (tester) async {
      var attempts = 0;
      Future<Uint8List> failingFetcher(int z, int x, int y) async {
        attempts++;
        throw Exception('network error');
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 0,
        fetcher: failingFetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.pump();
      final attemptsAfterFirst = attempts;
      expect(attemptsAfterFirst, greaterThan(0));

      // An unchanged calculate is a real no-op: it must not rebuild the grid,
      // recreate jobs, sort, or pump, so no new attempt happens.
      manager.calculate();
      await tester.pump();
      expect(attempts, attemptsAfterFirst);

      // After the failure backoff a retry still happens even though the grid
      // never changed, because the retry is timer-driven.
      await tester
          .pump(TileManager.failureBackoff + const Duration(seconds: 1));
      expect(attempts, greaterThan(attemptsAfterFirst));

      manager.dispose();
    });
  });

  group('cache corruption recovery', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('fosm_tile_cache_test');
      Hive.init(tempDir.path);
      await CacheTiles.initCache();
    });

    setUp(() async {
      final box = Hive.box(CacheTiles.boxCache);
      await box.clear();
    });

    tearDownAll(() async {
      await Hive.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// Sentinel payload the test decoders reject as malformed. Using a
    /// deterministic marker avoids feeding arbitrary bytes into the real
    /// image codec (which can hang the test binding).
    final corruptBytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

    bool isCorrupt(Uint8List bytes) =>
        bytes.length == corruptBytes.length &&
        bytes[0] == corruptBytes[0] &&
        bytes[1] == corruptBytes[1] &&
        bytes[2] == corruptBytes[2] &&
        bytes[3] == corruptBytes[3];

    Future<ui.Image> sentinelAwareDecoder(
        Uint8List bytes, int z, int x, int y) {
      if (isCorrupt(bytes)) {
        throw const TilePayloadException('sentinel payload');
      }
      return Tile.decodeImage(bytes);
    }

    testWidgets('a corrupt byte-cache entry is dropped and refetched',
        (tester) async {
      // Deterministic tile: with the 256×256 viewport, center (0,0), zoom 3
      // and padding 2 this is the far-right padding column; panning the
      // center to x=6 brings it into the strict viewport.
      final target = TileManager.tileKey(3, 6, 3);

      final fetchCounts = <String, int>{};
      Future<Uint8List> fetcher(int z, int x, int y) async {
        final key = '$z/$x/$y';
        fetchCounts[key] = (fetchCounts[key] ?? 0) + 1;
        if (key == target) {
          // First fetch (bytes-only padding preload) is malformed; the
          // recovery refetch returns a valid tile.
          return fetchCounts[key] == 1 ? corruptBytes : fakeTilePng;
        }
        return fakeTilePng;
      }

      final decodeCalls = <String, int>{};
      Future<ui.Image> decoder(Uint8List bytes, int z, int x, int y) {
        final key = '$z/$x/$y';
        decodeCalls[key] = (decodeCalls[key] ?? 0) + 1;
        return sentinelAwareDecoder(bytes, z, x, y);
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        decoder: decoder,
        tilePadding: 2,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      // The camera mutation triggers Hive deletes, so drive it inside
      // `runAsync` where the real Hive IO can complete.
      await tester.runAsync(() async {
        manager.calculate();
      });

      // Wait for the malformed bytes to reach the byte/disk cache through
      // the bytes-only padding preload.
      await _runUntil(tester, () => fetchCounts[target] == 1);
      await _flushAsync(tester);
      expect(manager.isTileRelevant(3, 6, 3), isFalse,
          reason: 'the target starts as bytes-only padding');
      expect(manager.renderTiles.any((t) => t.index == target), isTrue);

      // Promote the padding tile into the strict viewport. The corrupt cached
      // payload must be invalidated (byte + disk) before one network retry.
      await tester.runAsync(() async {
        manager.setCenterFromTileCoords(6, manager.centerTileLat);
        manager.calculate();
      });

      await _runUntil(
        tester,
        () => manager.renderTiles
            .any((t) => t.index == target && t.sourceTile != null),
      );

      expect(decodeCalls[target], 2,
          reason: 'one failing decode of the cached payload, then one '
              'successful decode of the refetched payload');
      expect(fetchCounts[target], 2,
          reason: 'recovery must refetch the tile exactly once');
    });

    testWidgets('a corrupt persistent entry is deleted and refetched',
        (tester) async {
      final fetchCounts = <String, int>{};
      Future<Uint8List> fetcher(int z, int x, int y) async {
        final key = '$z/$x/$y';
        fetchCounts[key] = (fetchCounts[key] ?? 0) + 1;
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        decoder: sentinelAwareDecoder,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      // Seed a persistent entry with the malformed sentinel payload.
      final key = TileManager.tileKey(3, 4, 4);
      await tester.runAsync(() async {
        await manager.storeTile(key, Tile(null, key, 4, 4), corruptBytes);
      });
      expect(manager.hasStoredTile(key), isTrue);

      // `calculate()` reaches the Hive delete for the corrupt entry, so run
      // it where the real Hive IO can complete.
      await tester.runAsync(() async {
        manager.calculate();
      });
      await _runUntil(
        tester,
        () => manager.renderTiles
            .any((t) => t.index == key && t.sourceTile != null),
      );

      expect(fetchCounts[key], 1,
          reason: 'the corrupt disk entry must be replaced from the network');

      // The bad entry must be gone, replaced by the freshly fetched bytes.
      Uint8List? stored;
      await tester.runAsync(() async {
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsed < const Duration(seconds: 5)) {
          final bytes = await manager.storedTileBytes(key);
          stored = bytes;
          if (bytes != null && bytes.length == fakeTilePng.length) break;
          await Future<void>.delayed(Duration.zero);
        }
      });
      expect(stored, equals(fakeTilePng));
    });

    testWidgets('a legacy logical-key entry is read, migrated, and removed',
        (tester) async {
      final fetchCounts = <String, int>{};
      Future<Uint8List> fetcher(int z, int x, int y) async {
        final key = '$z/$x/$y';
        fetchCounts[key] = (fetchCounts[key] ?? 0) + 1;
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        // A canonical key different from the legacy logical slot key.
        resourceKeyBuilder: (z, x, y) => 'res/$z/$x/$y',
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      const legacyKey = '3/4/4';
      const canonicalKey = 'res/3/4/4';
      await tester.runAsync(() async {
        await manager.storeTile(
          legacyKey,
          Tile(null, legacyKey, 4, 4),
          fakeTilePng,
        );
      });
      expect(manager.hasStoredTile(legacyKey), isTrue);
      expect(manager.hasStoredTile(canonicalKey), isFalse);

      // `calculate()` reads the legacy record and rewrites it, so drive it
      // where the real Hive IO can complete.
      await tester.runAsync(() async {
        manager.calculate();
        final stopwatch = Stopwatch()..start();
        while (!manager.renderTiles
                .any((t) => t.index == legacyKey && t.sourceTile != null) &&
            stopwatch.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      expect(
        manager.renderTiles
            .any((t) => t.index == legacyKey && t.sourceTile != null),
        isTrue,
        reason: 'legacy bytes must render without a network request',
      );
      expect(fetchCounts.containsKey(legacyKey), isFalse,
          reason: 'a valid legacy entry must not be refetched');

      // The record moved to the canonical resource key; the old entry is gone.
      Uint8List? migrated;
      await tester.runAsync(() async {
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsed < const Duration(seconds: 5)) {
          migrated = await manager.storedTileBytes(canonicalKey);
          if (migrated != null) break;
          await Future<void>.delayed(Duration.zero);
        }
      });
      expect(migrated, equals(fakeTilePng));
      expect(manager.hasStoredTile(legacyKey), isFalse,
          reason: 'the legacy entry must be removed after migration');
    });

    testWidgets('malformed network bytes are not persisted', (tester) async {
      var fetches = 0;
      var decodes = 0;

      Future<Uint8List> fetcher(int z, int x, int y) async {
        fetches++;
        return corruptBytes;
      }

      Future<ui.Image> decoder(Uint8List bytes, int z, int x, int y) async {
        decodes++;
        return sentinelAwareDecoder(bytes, z, x, y);
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        decoder: decoder,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      try {
        manager.calculate();
        await _runUntil(tester, () => decodes > 0);
        expect(fetches, greaterThan(0));

        for (final tile in manager.renderTiles) {
          expect(manager.hasStoredTile(tile.index), isFalse,
              reason: 'malformed bytes must not be persisted: ${tile.index}');
        }
      } finally {
        // Cancel the failure-backoff retry timer before the test binding
        // checks for pending timers, even when an expectation fails.
        manager.dispose();
      }
    });
  });

  group('canonical resource deduplication', () {
    testWidgets('wrapped-X slots share one network resource', (tester) async {
      // A viewport wider than the world at z0 makes several logical columns
      // resolve to the same wrapped source tile.
      var fetches = 0;
      Future<Uint8List> fetcher(int z, int x, int y) async {
        fetches++;
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 1024,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 0,
        fetcher: fetcher,
        resourceKeyBuilder: tileUrl,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await _runUntil(tester, () => manager.visibleTilesReady);

      expect(manager.visibleTileCount, greaterThan(1));
      expect(fetches, 1,
          reason: 'every wrapped-X column must share one download');
    });

    testWidgets('one resource future fans out to every waiting slot',
        (tester) async {
      final completers = <Completer<Uint8List>>[];
      Future<Uint8List> fetcher(int z, int x, int y) {
        final completer = Completer<Uint8List>();
        completers.add(completer);
        return completer.future;
      }

      final manager = TileManager.init(
        width: 1024,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 0,
        fetcher: fetcher,
        resourceKeyBuilder: tileUrl,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.pump();

      // All visible slots share the resource; only one fetch is in flight.
      expect(completers.length, 1);

      await tester.runAsync(() async {
        completers.single.complete(fakeTilePng);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(manager.visibleTilesReady, isTrue,
          reason: 'every waiting slot must complete from the shared bytes');
    });

    testWidgets('over-zoom siblings fetch once but render distinct images',
        (tester) async {
      var fetches = 0;
      Future<Uint8List> fetcher(int z, int x, int y) async {
        fetches++;
        return fakeTilePng;
      }

      var decodes = 0;
      Future<ui.Image> decoder(Uint8List bytes, int z, int x, int y) async {
        decodes++;
        return Tile.decodeImage(bytes);
      }

      final manager = TileManager.init(
        width: 512,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 13,
        fetcher: fetcher,
        decoder: decoder,
        // Four z13 slots collapse onto two z12 ancestors.
        resourceKeyBuilder: (z, x, y) => '${z - 1}/${x >> 1}/$y',
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.setCenterFromTileCoords(7, 4);
      manager.calculate();
      await _runUntil(tester, () => manager.visibleTilesReady);

      expect(manager.renderTiles.length, 4);
      expect(decodes, 4, reason: 'each logical slot renders its own image');
      expect(fetches, 2,
          reason: 'two source resources serve four over-zoom siblings');
    });

    testWidgets('a shared fetch failure reaches every waiter and retries',
        (tester) async {
      var attempts = 0;
      Future<Uint8List> fetcher(int z, int x, int y) async {
        attempts++;
        if (attempts == 1) throw Exception('shared failure');
        return fakeTilePng;
      }

      final manager = TileManager.init(
        width: 1024,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 0,
        fetcher: fetcher,
        resourceKeyBuilder: tileUrl,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      try {
        manager.calculate();
        await tester.pump();

        // The single shared fetch failed; every waiting slot backs off.
        expect(attempts, 1);
        expect(manager.visibleTilesReady, isFalse);

        // After the backoff the slots retry and the shared resource is
        // fetched again successfully.
        await tester
            .pump(TileManager.failureBackoff + const Duration(seconds: 1));
        await _runUntil(tester, () => manager.visibleTilesReady);
        expect(attempts, greaterThan(1));
      } finally {
        manager.dispose();
      }
    });

    testWidgets('a resolved resource is not refetched while decode is pending',
        (tester) async {
      var fetches = 0;
      final decodeCompleters = <String, Completer<ui.Image>>{};

      Future<Uint8List> fetcher(int z, int x, int y) async {
        fetches++;
        return fakeTilePng;
      }

      Future<ui.Image> decoder(Uint8List bytes, int z, int x, int y) {
        final completer = Completer<ui.Image>();
        decodeCompleters['$z/$x/$y'] = completer;
        return completer.future;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        decoder: decoder,
        // Every logical slot collapses onto one resource.
        resourceKeyBuilder: (z, x, y) => 'shared',
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await _flushAsync(tester);
      expect(fetches, 1);
      expect(decodeCompleters, isNotEmpty);

      // Widen the viewport: more logical slots with the same resource appear
      // while the first decode is still pending. They must decode from the
      // shared bytes instead of starting another request.
      manager.resize(const ui.Size(900, 256));
      manager.calculate();
      await _flushAsync(tester);
      expect(fetches, 1,
          reason: 'a resource with cached bytes must not be refetched');

      // Release the pending decoders so the manager disposes cleanly.
      await tester.runAsync(() async {
        for (final completer in decodeCompleters.values.toList()) {
          if (completer.isCompleted) continue;
          final image = await Tile.decodeImage(fakeTilePng);
          completer.complete(image);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    });

    test('canonical keys drop URL secrets but track public identity', () {
      TileManager build(String url) => TileManager.init(
            width: 256,
            height: 256,
            centerLatLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 3,
            urlBuilder: (z, x, y) => url
                .replaceAll('{z}', '$z')
                .replaceAll('{x}', '$x')
                .replaceAll('{y}', '$y'),
            tilePadding: 0,
            preloadAdjacentZoom: false,
          );

      final a = build('https://tiles.example/{z}/{x}/{y}.pbf?token=SECRET_A');
      final b = build('https://tiles.example/{z}/{x}/{y}.pbf?token=SECRET_B');
      final c = build('https://other.example/{z}/{x}/{y}.pbf?token=SECRET_A');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);

      final keyA = a.resourceKeyFor(3, 4, 4);
      final keyB = b.resourceKeyFor(3, 4, 4);
      final keyC = c.resourceKeyFor(3, 4, 4);

      expect(keyA, isNot(contains('SECRET_A')));
      expect(keyA, isNot(contains('token')));
      expect(keyA, equals(keyB),
          reason: 'a secret query difference is not part of the identity');
      expect(keyA, isNot(equals(keyC)),
          reason: 'a public host change must invalidate the resource');
    });
  });

  group('frame coalescing', () {
    /// Builds a manager whose fetches stay pending until the test completes
    /// them, so several tiles can finish in the same event-loop turn.
    ({TileManager manager, Map<String, Completer<Uint8List>> completers})
        pendingManager() {
      final completers = <String, Completer<Uint8List>>{};
      Future<Uint8List> fetcher(int z, int x, int y) {
        final key = '$z/$x/$y';
        final completer = Completer<Uint8List>();
        completers[key] = completer;
        return completer.future;
      }

      final manager = TileManager.init(
        width: 512,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);
      return (manager: manager, completers: completers);
    }

    Future<void> drain(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
    }

    testWidgets('many completions in one frame produce one notification',
        (tester) async {
      final (:manager, :completers) = pendingManager();
      var notifications = 0;
      manager.onTilesChanged = () => notifications++;

      manager.calculate();
      await tester.pump();
      expect(completers.length, greaterThan(1));

      // Complete every pending fetch in the same turn.
      for (final completer in completers.values) {
        completer.complete(fakeTilePng);
      }
      await drain(tester);
      await tester.pump();

      expect(notifications, 1,
          reason: 'a whole frame of arrivals must coalesce to one callback');
    });

    testWidgets('a completion in a later frame notifies again', (tester) async {
      final (:manager, :completers) = pendingManager();
      var notifications = 0;
      manager.onTilesChanged = () => notifications++;

      manager.calculate();
      await tester.pump();

      final keys = completers.keys.toList();
      completers[keys.first]!.complete(fakeTilePng);
      await drain(tester);
      await tester.pump();
      expect(notifications, 1);

      completers[keys.last]!.complete(fakeTilePng);
      await drain(tester);
      await tester.pump();
      expect(notifications, 2);
    });

    testWidgets('off-screen-only completion never notifies', (tester) async {
      final completers = <Completer<Uint8List>>[];
      Future<Uint8List> fetcher(int z, int x, int y) {
        final completer = Completer<Uint8List>();
        completers.add(completer);
        return completer.future;
      }

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: fetcher,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await tester.pump();
      final pendingBeforePan = List<Completer<Uint8List>>.of(completers);

      // Move far away so the pending tiles are no longer on screen.
      manager.setCenterFromTileCoords(8, 8);
      manager.calculate();

      var notifications = 0;
      manager.onTilesChanged = () => notifications++;

      // Resolve the now-stale fetches: nothing may be published or notified.
      for (final completer in pendingBeforePan) {
        if (!completer.isCompleted) completer.complete(fakeTilePng);
      }
      await drain(tester);
      await tester.pump();

      expect(notifications, 0);
    });

    testWidgets('camera changes bump the grid revision, not content',
        (tester) async {
      final (:manager, :completers) = pendingManager();
      manager.calculate();
      await tester.pump();

      final gridBefore = manager.gridRevision;
      final contentBefore = manager.contentRevision;
      final revisionBefore = manager.revision;

      manager.setCenterFromTileCoords(
        manager.centerTileLng + 1,
        manager.centerTileLat,
      );
      manager.calculate();

      expect(manager.gridRevision, greaterThan(gridBefore));
      expect(manager.contentRevision, contentBefore);
      expect(manager.revision, greaterThan(revisionBefore));

      // Let the pending fetches settle to avoid pending timers.
      for (final completer in completers.values) {
        if (!completer.isCompleted) completer.complete(fakeTilePng);
      }
      await drain(tester);
      await tester.pump();
    });
  });
}
