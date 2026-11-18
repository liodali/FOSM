import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';

/// Minimal valid 1×1 RGBA PNG — decodable by Flutter's image codec.
final Uint8List fakeTilePng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Future<Uint8List> _fakeFetcher(int z, int x, int y) async => fakeTilePng;

/// Decode counter: `regular` serves visible slots; `speculative` serves
/// every prepared-window job (the variant decoder path) — with
/// `speculativePrepare` off, a `spec:` call is prepared-window work and
/// nothing else.
class _Counts {
  int regularCount = 0;
  int specCount = 0;

  /// Every prepared decode as `z/x/y`.
  final Set<String> preparedKeys = {};

  Future<ui.Image> regular(Uint8List bytes, int z, int x, int y) async {
    regularCount++;
    return Tile.decodeImage(bytes);
  }

  Future<ui.Image> speculative(Uint8List bytes, int z, int x, int y) async {
    specCount++;
    preparedKeys.add('$z/$x/$y');
    return Tile.decodeImage(bytes);
  }
}

Future<void> _settleUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition() && stopwatch.elapsed < timeout) {
    await tester.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }
  expect(condition(), isTrue,
      reason: 'condition not met within ${timeout.inSeconds}s');
}

/// Drains every admitted prepared pipeline: decodes reach the counter,
/// presentation empties, and admissions stop growing across several
/// pumps (shell expansion re-admits as the lane drains).
Future<void> _settlePrepared(
  WidgetTester tester,
  _Counts counts,
  int admittedTarget,
) async {
  await _settleUntil(tester, () => counts.specCount >= admittedTarget);
  var stable = 0;
  var last = -1;
  final watch = Stopwatch()..start();
  while (stable < 12 && watch.elapsed < const Duration(seconds: 10)) {
    await tester.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    final now = counts.specCount;
    if (now == last) {
      stable++;
    } else {
      stable = 0;
    }
    last = now;
  }
}

/// Predicted candidate count replicated from the design formula: the
/// current strict viewport extent scaled by 2^dz around the predicted
/// center (focal or camera center), padded one tile, world-clipped.
int expectedAdmitted({
  required int zoom,
  required int visibleH,
  required int visibleV,
  required double centerLngTile,
  required double centerLatTile,
  required int depth,
}) {
  final keys = <String>{};
  for (var level = 1; level <= depth; level++) {
    for (final dz in [level, -level]) {
      final z = zoom + dz;
      if (z < 0 || z > 19) continue;
      final scale = _pow2(dz);
      final predictedLng = centerLngTile * scale;
      final predictedLat = centerLatTile * scale;
      final halfW = visibleH * scale / 2 + 1;
      final halfH = visibleV * scale / 2 + 1;
      final world = 1 << z;
      final minX = (predictedLng - halfW).floor().clamp(0, world - 1);
      final maxX = (predictedLng + halfW).floor().clamp(0, world - 1);
      final minY = (predictedLat - halfH).floor();
      final maxY = (predictedLat + halfH).floor();
      for (var y = minY; y <= maxY; y++) {
        if (y < 0 || y >= world) continue;
        for (var x = minX; x <= maxX; x++) {
          keys.add('$z/$x/$y');
        }
      }
    }
  }
  return keys.length;
}

double _pow2(int dz) => dz >= 0 ? (1 << dz).toDouble() : 1 / (1 << -dz);

void main() {
  group('prepared zoom window (plan 13 Phase E)', () {
    // 256×256 viewport with 256px tiles and padding 1: grid 4×4, strict
    // viewport 2×2 tiles.
    final center = const LatLng(latitude: 0.01, longitude: 0.01);

    int visibleH(TileManager manager) =>
        manager.horizontalTileCount - 2; // tilePadding 1
    int visibleV(TileManager manager) => manager.verticalTileCount - 2;

    testWidgets('off by default: the gate admits nothing', (tester) async {
      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: counts.regular,
        speculativeDecoder: counts.speculative,
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      await _settleUntil(tester, () => manager.pendingPresentationCount == 0);

      expect(manager.debugPreparedWindowStats['admitted'], 0,
          reason: 'the candidate is separately gated and defaults off');
      expect(counts.specCount, 0, reason: 'no prepared decodes without the '
          'gate');
    });

    testWidgets('prepares the predicted viewport at zoom ±1', (tester) async {
      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: counts.regular,
        speculativeDecoder: counts.speculative,
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        preparedZoomWindow: true,
        preparedWindowDepth: 1,
        maxPreparedPerGeneration: 256,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      final expected = expectedAdmitted(
        zoom: 3,
        visibleH: visibleH(manager),
        visibleV: visibleV(manager),
        centerLngTile: lon2TileX(center.longitude, 3),
        centerLatTile: lat2TileY(center.latitude, 3),
        depth: 1,
      );
      expect(expected, greaterThan(0), reason: 'sanity: nonempty window');
      // Budget high enough that the prediction is admitted exactly.
      expect(expected, lessThanOrEqualTo(256));

      var reached = 0;
      final traces = <String>[];
      TileManager.debugSpeculativeTrace = traces.add;
      addTearDown(() => TileManager.debugSpeculativeTrace = null);
      try {
        await _settleUntil(
            tester,
            () {
              reached = counts.specCount;
              return reached >= expected;
            },
            timeout: const Duration(seconds: 4));
      } catch (_) {
        // ignore: avoid_print
        print('diag reached=$reached expected=$expected '
            'stats=${manager.debugPreparedWindowStats} '
            'pendingPres=${manager.pendingPresentationCount}');
        // ignore: avoid_print
        print('diag tracesTail=${traces.length > 12 ? traces.sublist(traces.length - 12) : traces}');
        rethrow;
      }

      final zooms =
          counts.preparedKeys.map((k) => k.split('/').first).toSet();
      expect(zooms, {'2', '4'},
          reason: 'depth 1 prepares only the nearest levels');
      expect(manager.debugPreparedWindowStats['admitted'], expected,
          reason: 'every predicted candidate is admitted exactly once '
              '(fetches succeed, budget above the candidate count)');
      expect(counts.regularCount, lessThanOrEqualTo(visibleH(manager) * visibleV(manager)),
          reason: 'visible work stays on the regular decoder');
    });

    testWidgets('a zoom step promotes prepared tiles synchronously',
        (tester) async {
      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: counts.regular,
        speculativeDecoder: counts.speculative,
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        preparedZoomWindow: true,
        preparedWindowDepth: 1,
        maxPreparedPerGeneration: 256,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      final expected = expectedAdmitted(
        zoom: 3,
        visibleH: visibleH(manager),
        visibleV: visibleV(manager),
        centerLngTile: lon2TileX(center.longitude, 3),
        centerLatTile: lat2TileY(center.latitude, 3),
        depth: 1,
      );
      await _settlePrepared(tester, counts, expected);

      // Zoom in one level: the predicted z4 viewport was prepared, so the
      // new grid serves its imagery from the cache with no fetch waits.
      manager.setCameraZoom(4.0);
      await tester.pump();
      expect(manager.zoom, 4);
      bool strictHaveImages() {
        final strictH = visibleH(manager);
        final strictV = visibleV(manager);
        final left = manager.leftColumnTilesLngIndex + 1;
        final top = manager.topRowTilesLatIndex + 1;
        return manager.renderTiles
            .where((t) =>
                t.lngIndex >= left &&
                t.lngIndex < left + strictH &&
                t.latIndex >= top &&
                t.latIndex < top + strictV)
            .every((t) => t.sourceTile != null);
      }

      expect(strictHaveImages(), isTrue,
          reason: 'the prepared viewport must reveal sharp immediately');
      expect(manager.debugPreparedWindowStats['promoted'], greaterThan(0),
          reason: 'promotion is counted at the integer switch');

      // Zoom back: the outgoing level stays retained (requirement 4).
      manager.setCameraZoom(3.0);
      await tester.pump();
      expect(strictHaveImages(), isTrue,
          reason: 'reversing must reuse retained imagery, not re-fetch');
    });

    testWidgets('a camera change cancels stale queued preparation and '
        're-admits from the new camera', (tester) async {
      // Gate the first prepared fetch so a prepared job is still
      // outstanding when the camera moves.
      final gate = Completer<void>();
      var gated = false;
      Future<Uint8List> fetcher(int z, int x, int y) async {
        if (z != 3 && !gated) {
          gated = true;
          await gate.future;
        }
        return fakeTilePng;
      }

      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 3,
        fetcher: fetcher,
        decoder: counts.regular,
        speculativeDecoder: counts.speculative,
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        preparedZoomWindow: true,
        preparedWindowDepth: 1,
        maxPreparedPerGeneration: 256,
      );
      addTearDown(manager.dispose);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      manager.calculate();
      final expected = expectedAdmitted(
        zoom: 3,
        visibleH: visibleH(manager),
        visibleV: visibleV(manager),
        centerLngTile: lon2TileX(center.longitude, 3),
        centerLatTile: lat2TileY(center.latitude, 3),
        depth: 1,
      );
      await _settleUntil(
          tester, () => manager.debugPreparedWindowStats['admitted']! >= expected);

      // Camera moves a full level: membership changes → supersede. The
      // stale prepared key set drops (its unfinished work counts as
      // cancelled — it must not occupy the lane for the old camera).
      manager.setCameraZoom(4.0);
      await tester.pump();
      expect(manager.debugPreparedWindowStats['cancelled'], greaterThan(0),
          reason: 'stale prepared work must be cancelled at the camera '
              'change');
      expect(manager.debugPreparedWindowStats['admitted'],
          greaterThanOrEqualTo(expected),
          reason: 'admission counters are monotonic');

      gate.complete();
      await _settleUntil(tester, () => manager.pendingPresentationCount == 0);
    });

    testWidgets('the per-generation budget bounds preparation',
        (tester) async {
      final counts = _Counts();
      final manager = TileManager.init(
        width: 2048,
        height: 2048,
        centerLatLng: center,
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: counts.regular,
        speculativeDecoder: counts.speculative,
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        preparedZoomWindow: true,
        preparedWindowDepth: 1,
        maxPreparedPerGeneration: 24,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      // 8×8 visible tiles → the ±1 predicted rects hold hundreds of
      // candidates, far above the 24-per-generation budget.
      await _settlePrepared(tester, counts, 24);
      await tester.pump(const Duration(milliseconds: 50));
      expect(manager.debugPreparedWindowStats['admitted'], 24,
          reason: 'admission stops at the per-generation budget even as '
              'the lane drains');
    });

    testWidgets('depth 2 expands toward ±2 after the nearest shells',
        (tester) async {
      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: counts.regular,
        speculativeDecoder: counts.speculative,
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        preparedZoomWindow: true,
        preparedWindowDepth: 2,
        maxPreparedPerGeneration: 512,
      );
      addTearDown(manager.dispose);

      manager.calculate();
      final expected = expectedAdmitted(
        zoom: 3,
        visibleH: visibleH(manager),
        visibleV: visibleV(manager),
        centerLngTile: lon2TileX(center.longitude, 3),
        centerLatTile: lat2TileY(center.latitude, 3),
        depth: 2,
      );
      await _settlePrepared(tester, counts, expected);

      final zooms =
          counts.preparedKeys.map((k) => k.split('/').first).toSet();
      expect(zooms, {'1', '2', '4', '5'},
          reason: 'depth 2 prepares the rolling window through ±2');
      expect(manager.debugPreparedWindowStats['admitted'], expected);
    });

    testWidgets('prepared work never delays foreground demand',
        (tester) async {
      // Hold a visible fetch; nothing prepared may decode until the
      // foreground settles.
      final visibleGate = Completer<void>();
      var firstVisibleGated = false;
      Future<Uint8List> fetcher(int z, int x, int y) async {
        if (z == 3 && !firstVisibleGated) {
          firstVisibleGated = true;
          await visibleGate.future;
        }
        return fakeTilePng;
      }

      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 3,
        fetcher: fetcher,
        decoder: counts.regular,
        speculativeDecoder: counts.speculative,
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        preparedZoomWindow: true,
        preparedWindowDepth: 1,
        maxPreparedPerGeneration: 256,
      );
      addTearDown(manager.dispose);
      addTearDown(() {
        if (!visibleGate.isCompleted) visibleGate.complete();
      });

      manager.calculate();
      await tester.pump(const Duration(milliseconds: 100));
      expect(counts.specCount, 0,
          reason: 'with a foreground fetch outstanding, no prepared work '
              'may start');

      visibleGate.complete();
      await _settleUntil(tester, () => counts.specCount > 0);
    });
  });
}
