import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';

/// Predicted admission count for a no-gesture camera at [center]
/// (focal == center, integer capture scale, capture zoom == manager zoom).
int expectedCount({
  required LatLng center,
  required double widthPx,
  required double heightPx,
  required int depth,
}) {
  const z = 3;
  final focalLng = lon2TileX(center.longitude, z);
  final focalLat = lat2TileY(center.latitude, z);
  return expectedAdmitted(
    zoom: z,
    captureZoom: z,
    widthPx: widthPx,
    heightPx: heightPx,
    focalLngTile: focalLng,
    focalLatTile: focalLat,
    centerLngTile: focalLng,
    centerLatTile: focalLat,
    zoomScaleAtCapture: 1.0,
    depth: depth,
  );
}

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

/// Predicted candidate keys replicated from the design formula: the
/// focal-preserving projection maps the camera center to the target
/// zoom (`C' = [C + (F − C)·(1 − zoomScale)]·2^(target − captureZoom)`),
/// the screen shows `width/256 × height/256` tiles of the target level,
/// +1 tile of bounded pad; longitude wraps and deduplicates, latitude
/// clips.
Set<String> expectedKeys({
  required int zoom,
  required int captureZoom,
  required double widthPx,
  required double heightPx,
  required double focalLngTile,
  required double focalLatTile,
  required double centerLngTile,
  required double centerLatTile,
  required double zoomScaleAtCapture,
  required int depth,
}) {
  final keys = <String>{};
  for (var level = 1; level <= depth; level++) {
    for (final dz in [level, -level]) {
      final z = zoom + dz;
      if (z < 0 || z > 19) continue;
      final growth = _pow2(z - captureZoom);
      final predictedLng = (centerLngTile +
              (focalLngTile - centerLngTile) * (1 - zoomScaleAtCapture)) *
          growth;
      final predictedLat = (centerLatTile +
              (focalLatTile - centerLatTile) * (1 - zoomScaleAtCapture)) *
          growth;
      final halfW = widthPx / 512 + 1;
      final halfH = heightPx / 512 + 1;
      final world = 1 << z;
      final minX = (predictedLng - halfW).floor();
      final maxX = (predictedLng + halfW).floor();
      final minY = (predictedLat - halfH).floor().clamp(0, world - 1);
      final maxY = (predictedLat + halfH).floor().clamp(0, world - 1);
      for (var y = minY; y <= maxY; y++) {
        for (var x = minX; x <= maxX; x++) {
          final wx = ((x % world) + world) % world;
          keys.add('$z/$wx/$y');
        }
      }
    }
  }
  return keys;
}

/// Candidate count for the same inputs.
int expectedAdmitted({
  required int zoom,
  required int captureZoom,
  required double widthPx,
  required double heightPx,
  required double focalLngTile,
  required double focalLatTile,
  required double centerLngTile,
  required double centerLatTile,
  required double zoomScaleAtCapture,
  required int depth,
}) {
  return expectedKeys(
    zoom: zoom,
    captureZoom: captureZoom,
    widthPx: widthPx,
    heightPx: heightPx,
    focalLngTile: focalLngTile,
    focalLatTile: focalLatTile,
    centerLngTile: centerLngTile,
    centerLatTile: centerLatTile,
    zoomScaleAtCapture: zoomScaleAtCapture,
    depth: depth,
  ).length;
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
      final expected = expectedCount(
          center: center,
          widthPx: 256,
          heightPx: 256,
          depth: 1);
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
      final expected = expectedCount(
          center: center,
          widthPx: 256,
          heightPx: 256,
          depth: 1);
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
      final expected = expectedCount(
          center: center,
          widthPx: 256,
          heightPx: 256,
          depth: 1);
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
      final expected = expectedCount(
          center: center, widthPx: 256, heightPx: 256, depth: 2);
      await _settlePrepared(tester, counts, expected);
      final zooms =
          counts.preparedKeys.map((k) => k.split('/').first).toSet();
      expect(zooms, {'1', '2', '4', '5'},
          reason: 'depth 2 prepares the rolling window through ±2');
      expect(manager.debugPreparedWindowStats['admitted'], expected);
    });

    testWidgets('an antimeridian-crossing viewport keeps its far side',
        (tester) async {
      // Center 179.5°E at z3: the ±1 predicted rects cross the world edge;
      // wrapped X must appear (not be clipped away) and dedup by key.
      const edgeCenter = LatLng(latitude: 0.01, longitude: 179.5);
      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: edgeCenter,
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
      final expected = expectedCount(
        center: edgeCenter,
        widthPx: 256,
        heightPx: 256,
        depth: 1,
      );
      await _settlePrepared(tester, counts, expected);

      final zooms =
          counts.preparedKeys.map((k) => k.split('/').first).toSet();
      expect(zooms, {'2', '4'});
      // The z4 shell crosses the antimeridian: canonical wrapped columns
      // 0 and 1 must be present beside 14 and 15.
      final z4Columns =
          counts.preparedKeys.where((k) => k.startsWith('4/')).map((k) {
        final parts = k.split('/');
        return parts[1];
      }).toSet();
      expect(z4Columns, containsAll(['0', '1', '14', '15']),
          reason: 'wrapped far-side coverage must be prepared, not '
              'clipped at the world edge');
      expect(counts.preparedKeys.length, expected,
          reason: 'wrapped duplicates must dedup by canonical key');
    });

    testWidgets('memory pressure cancels prepared work and suspends '
        'admission until the camera moves', (tester) async {
      // Gate the first prepared fetch so unfinished prepared work exists
      // when pressure lands.
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
      final expected = expectedCount(
        center: center,
        widthPx: 256,
        heightPx: 256,
        depth: 1,
      );
      await _settleUntil(
          tester, () => manager.debugPreparedWindowStats['admitted']! >= expected);

      // Pressure clears prepared relevance and suspends admission; the
      // unfinished gated work counts as cancelled.
      manager.handleMemoryPressure();
      await tester.pump();
      expect(manager.debugPreparedWindowStats['cancelled'], greaterThan(0),
          reason: 'pressure must cancel prepared work, not leave it '
              'relevant over the flushed cache');

      final admittedAtPressure = manager.debugPreparedWindowStats['admitted']!;
      await tester.pump(const Duration(milliseconds: 300));
      expect(manager.debugPreparedWindowStats['admitted'], admittedAtPressure,
          reason: 'suspended admission must not refill the cleared cache '
              'while the camera rests');

      // A camera generation change lifts the suspension and re-admits
      // from the new camera.
      gate.complete();
      manager.setCameraZoom(4.0);
      await _settleUntil(
        tester,
        () =>
            manager.debugPreparedWindowStats['admitted']! > admittedAtPressure,
      );
    });

    testWidgets('prediction projects from the capture zoom after a zoom '
        'change', (tester) async {
      // The reviewer's repro: capture at z3, admit at zoom 4. The target
      // z5 rect must grow from the capture base (2^(5−3)), not from dz
      // (2^1) — the wrong factor lands two tiles west.
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
      await _settleUntil(tester, () => manager.pendingPresentationCount == 0);

      // Capture happens here, at z3; the manager is now at z4.
      manager.setCameraZoom(4.0);
      await tester.pump();

      final expected = expectedKeys(
        zoom: 4,
        captureZoom: 3,
        widthPx: 256,
        heightPx: 256,
        focalLngTile: lon2TileX(center.longitude, 3),
        focalLatTile: lat2TileY(center.latitude, 3),
        centerLngTile: lon2TileX(center.longitude, 3),
        centerLatTile: lat2TileY(center.latitude, 3),
        zoomScaleAtCapture: 1.0,
        depth: 1,
      );
      await _settleUntil(
          tester,
          () =>
              expected.containsAll(counts.preparedKeys) &&
              counts.preparedKeys.any((k) => k.startsWith('5/')));
      // Drain the lane fully before judging columns — the settle above
      // passes on the first z5 decode while its siblings are in flight.
      var last = -1;
      var stable = 0;
      final watch = Stopwatch()..start();
      while (stable < 10 && watch.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(() async {
          for (var i = 0; i < 5; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        });
        await tester.pump();
        if (counts.specCount == last) {
          stable++;
        } else {
          stable = 0;
        }
        last = counts.specCount;
      }
      // z5 preparation happened and lands on the projected center
      // (tile 16.009 at z5 = 4.0022 × 4), not two tiles west of it.
      final z5Keys = counts.preparedKeys.where((k) => k.startsWith('5/'));
      expect(z5Keys, isNotEmpty, reason: 'the +1 shell must prepare z5');
      final z5Columns = z5Keys.map((k) => k.split('/')[1]).toSet();
      expect(z5Columns, {'14', '15', '16', '17'},
          reason: 'the projected z5 center is tile 16.009; columns must '
              'straddle it (14.5..17.5 rounded), proving the projection '
              'grew from the capture zoom');
    });

    testWidgets('off-center focal prediction matches the projected camera',
        (tester) async {
      // Ground truth comes from driving a real camera through the same
      // two-step focal-preserving gesture and reading where it lands at
      // z5 — the test does not re-implement the prediction formula.
      const focal = Offset(192, 128); // 64 px right of the viewport center
      final counts = _Counts();
      final probe = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 3,
        fetcher: _fakeFetcher,
        decoder: counts.regular,
        tilePadding: 1,
        preloadAdjacentZoom: false,
      );
      addTearDown(probe.dispose);
      probe.setCameraZoom(4.0, focalPoint: focal);
      probe.setCameraZoom(5.0, focalPoint: focal);
      final truthLng = probe.centerTileLng;
      final truthLat = probe.centerTileLat;

      // Candidate: same start, same first gesture step. Its z5 shell
      // must target the camera's actual z5 position.
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
      await _settleUntil(tester, () => manager.pendingPresentationCount == 0);

      manager.setCameraZoom(4.0, focalPoint: focal);
      await tester.pump();

      final half = 256 / 512 + 1;
      final world = 1 << 5;
      Set<String> truthKeys() {
        final keys = <String>{};
        for (var x = (truthLng - half).floor();
            x <= (truthLng + half).floor();
            x++) {
          final wx = ((x % world) + world) % world;
          for (var y = (truthLat - half).floor().clamp(0, world - 1);
              y <= (truthLat + half).floor().clamp(0, world - 1);
              y++) {
            keys.add('5/$wx/$y');
          }
        }
        return keys;
      }

      Iterable<String> preparedZ5Live() =>
          counts.preparedKeys.where((k) => k.startsWith('5/'));
      await _settleUntil(tester, () {
        final live = preparedZ5Live().toSet();
        return truthKeys().containsAll(live) && live.containsAll(truthKeys());
      });
      // Full z5 set equality: the prepared viewport must be exactly the
      // projected camera's viewport. The centered-growth bug prepared
      // columns 14–17 (the old center's) instead of 15–18 (the landed
      // camera's, ~0.75 tiles further east from the off-center focal).
      final preparedZ5 = preparedZ5Live().toSet();
      expect(preparedZ5, truthKeys(),
          reason: 'the prepared z5 viewport must equal the real '
              'focal-preserving projection\'s landing viewport');
    });

    testWidgets('a pan invalidates stale prediction inputs; preparation '
        'follows the live camera', (tester) async {
      final counts = _Counts();
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: center,
        zoom: 5,
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
      await _settleUntil(tester, () => manager.pendingPresentationCount == 0);

      // Pan ~2.7 tiles east at z5 (11.25° per tile). The capture is
      // invalidated; the fallback predicts around the live center.
      const panned = LatLng(latitude: 0.05, longitude: 25.0);
      manager.setCenterTile(latLng: panned);
      await tester.pump();

      final newCenterLngTile = lon2TileX(panned.longitude, 5);
      final newCenterLatTile = lat2TileY(panned.latitude, 5);
      final expected = expectedKeys(
        zoom: 5,
        captureZoom: 5,
        widthPx: 256,
        heightPx: 256,
        focalLngTile: newCenterLngTile,
        focalLatTile: newCenterLatTile,
        centerLngTile: newCenterLngTile,
        centerLatTile: newCenterLatTile,
        zoomScaleAtCapture: 1.0,
        depth: 1,
      );
      final stale = counts.preparedKeys.toSet();
      await _settleUntil(tester, () {
        final fresh =
            counts.preparedKeys.where((k) => !stale.contains(k)).toSet();
        return fresh.isNotEmpty && expected.containsAll(fresh);
      });
      // The +1 shell centers on the panned location's z6 projection
      // (tile 36.4 = 18.223 × 2), proving prediction followed the pan.
      final fresh = counts.preparedKeys.where((k) => !stale.contains(k));
      final z6Keys = fresh.where((k) => k.startsWith('6/'));
      expect(z6Keys, isNotEmpty);
      final z6Columns = z6Keys.map((k) => k.split('/')[1]).toSet();
      expect(z6Columns.intersection({'35', '36', '37', '38'}), isNotEmpty,
          reason: 'the projected z6 center is tile 36.4; prepared columns '
              'must straddle the panned location');
    });

    testWidgets('prepared work never delays foreground demand',
        (tester) async {      // Hold a visible fetch; nothing prepared may decode until the
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
