import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';

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
}
