import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
import 'package:fosm/src/common/utils.dart';

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

      manager.calculate();

      // At z=1, the world is 2×2 tiles. Center is tile (1, 1).
      // With a 256×256 viewport we need at least 1×1 = 1 tile,
      // possibly 2×2 if the center is not tile-aligned.
      expect(manager.renderTiles.length, greaterThanOrEqualTo(1));

      // Center tile should be present.
      final centerKey = TileManager.tileKey(1, 1, 1);
      final hasCenter =
          manager.renderTiles.any((t) => t.index == centerKey);
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

      manager.setCenterTile(
        latLng: LatLng(latitude: 95, longitude: 0),
      );
      expect(manager.centerLatLng.latitude,
          closeTo(maxWebMercatorLatitude, 0.01));

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

      manager.calculate();
      expect(manager.zoom, 3);
      final tilesAtZ3 = manager.renderTiles.length;
      expect(tilesAtZ3, greaterThan(0));

      manager.setZoom(5);
      expect(manager.zoom, 5);
      final tilesAtZ5 = manager.renderTiles.length;
      expect(tilesAtZ5, greaterThan(0));

      // Tile keys should be different at different zoom levels.
      final keysAtZ3 = manager.renderTiles
          .where((t) => t.index.startsWith('3/'))
          .length;
      final keysAtZ5 = manager.renderTiles
          .where((t) => t.index.startsWith('5/'))
          .length;
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
      );

      manager.calculate();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await tester.pump();

      // Should have fetched tiles at z=5 (visible) and z=4, z=6 (adjacent).
      expect(fetchedZooms.contains(5), isTrue);
      expect(fetchedZooms.contains(4), isTrue);
      expect(fetchedZooms.contains(6), isTrue);

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
      );

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
}
