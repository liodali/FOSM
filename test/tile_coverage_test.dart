import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';

import 'tile_manager_test.dart' show fakeTilePng;

/// Gates every even-x tile on [released]; odd-x tiles resolve immediately.
class _GatedFetcher {
  final released = Completer<void>();

  Future<Uint8List> call(int z, int x, int y) async {
    if (x.isEven) await released.future;
    return fakeTilePng;
  }
}

/// Runs [action] in the real event-loop zone: raw-TileManager tests must
/// create, drive and dispose the manager entirely inside `runAsync`, or
/// the fetch-timeout timers of the fake zone never fire.
Future<void> _real(Future<void> Function() action) =>
    TestWidgetsFlutterBinding.instance.runAsync(action);

void main() {
  group('FosmTileCoverage value type', () {
    test('empty grid reports ready with full fractions', () {
      const coverage = FosmTileCoverage.empty();
      expect(coverage.visibleCells, 0);
      expect(coverage.missingCells, 0);
      expect(coverage.allCovered, isTrue);
      expect(coverage.allSharp, isTrue);
      expect(coverage.coveredFraction, 1);
      expect(coverage.sharpFraction, 1);
    });

    test('counts derived from the cell totals', () {
      const coverage =
          FosmTileCoverage(visibleCells: 10, coveredCells: 7, sharpCells: 5);
      expect(coverage.missingCells, 3);
      expect(coverage.sharpMissingCells, 5);
      expect(coverage.allCovered, isFalse);
      expect(coverage.allSharp, isFalse);
      expect(coverage.coveredFraction, closeTo(0.7, 1e-9));
      expect(coverage.sharpFraction, closeTo(0.5, 1e-9));
      expect(coverage.toString(), contains('sharp: 5'));
    });

    test('fully covered edge values', () {
      const coverage =
          FosmTileCoverage(visibleCells: 4, coveredCells: 4, sharpCells: 4);
      expect(coverage.allCovered, isTrue);
      expect(coverage.allSharp, isTrue);
      expect(coverage.missingCells, 0);
      expect(coverage.sharpMissingCells, 0);
    });
  });

  group('TileManager.coverage', () {
    test('empty before calculate, complete after load', () async {
      await _real(() async {
        final manager = TileManager.init(
          width: 300,
          height: 300,
          centerLatLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 5,
          fetcher: (z, x, y) async => fakeTilePng,
          tilePadding: 0,
          preloadAdjacentZoom: false,
        );
        addTearDown(manager.dispose);

        expect(manager.coverage().visibleCells, 0,
            reason: 'an uncalculated grid has no visible cells');
        expect(manager.coverage().allCovered, isTrue,
            reason: 'an uncalculated grid never reports blank area');

        manager.calculate();
        await _settleSharp(manager);

        final coverage = manager.coverage();
        expect(coverage.visibleCells, greaterThan(0));
        expect(coverage.coveredCells, coverage.visibleCells);
        expect(coverage.sharpCells, coverage.visibleCells,
            reason: 'every published raster cell retains its image');
        expect(coverage.allCovered, isTrue);
        expect(coverage.allSharp, isTrue);
        expect(manager.visibleTilesReady, isTrue);
      });
    });

    test('partial load reports partial coverage', () async {
      await _real(() async {
        final gated = _GatedFetcher();
        final manager = TileManager.init(
          width: 300,
          height: 300,
          centerLatLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 5,
          fetcher: gated.call,
          tilePadding: 0,
          preloadAdjacentZoom: false,
        );
        addTearDown(manager.dispose);

        manager.calculate();
        // Odd-x cells publish; even-x cells wait on the gate.
        final evenCells = manager.renderTiles.where((t) => t.lngIndex.isEven);
        while (manager.coverage().coveredCells !=
            manager.coverage().visibleCells - evenCells.length) {
          await Future<void>.delayed(Duration.zero);
        }

        final partial = manager.coverage();
        expect(partial.visibleCells, greaterThan(0));
        expect(partial.allCovered, isFalse);
        expect(partial.coveredCells, partial.visibleCells - evenCells.length);
        expect(partial.sharpCells, partial.coveredCells,
            reason: 'a published cell always retains its current-zoom image');
        expect(partial.coveredFraction, lessThan(1));

        gated.released.complete();
        await _settleSharp(manager);
        expect(manager.coverage().allSharp, isTrue);
      });
    });

    test('coverage ignores padding cells', () async {
      await _real(() async {
        final manager = TileManager.init(
          width: 300,
          height: 300,
          centerLatLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 5,
          fetcher: (z, x, y) async => fakeTilePng,
          tilePadding: 1,
          preloadAdjacentZoom: false,
        );
        addTearDown(manager.dispose);

        manager.calculate();
        expect(manager.renderTiles.length,
            greaterThan(manager.coverage().visibleCells),
            reason: 'the padded render set must exceed the strict viewport');
        expect(manager.coverage().visibleCells, manager.visibleTileCount);

        await _settleSharp(manager);
        expect(manager.coverage().allSharp, isTrue);
      });
    });

    test('zoom step drops sharp coverage until the new grid loads', () async {
      await _real(() async {
        final manager = TileManager.init(
          width: 300,
          height: 300,
          centerLatLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 5,
          fetcher: (z, x, y) async => fakeTilePng,
          tilePadding: 0,
          preloadAdjacentZoom: false,
        );
        addTearDown(manager.dispose);

        manager.calculate();
        await _settleSharp(manager);
        expect(manager.coverage().allSharp, isTrue);

        manager.setZoom(6);
        manager.calculate();
        final stepped = manager.coverage();
        expect(stepped.visibleCells, greaterThan(0));
        expect(stepped.allSharp, isFalse,
            reason: 'a fresh zoom step has not loaded its own imagery yet');
        expect(stepped.sharpCells, lessThan(stepped.visibleCells));

        await _settleSharp(manager);
        expect(manager.coverage().allSharp, isTrue);
      });
    });

    test('fallback-covered cells count as covered but never sharp', () async {
      await _real(() async {
        final gated = _GatedFetcher();
        final manager = TileManager.init(
          width: 300,
          height: 300,
          centerLatLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 5,
          fetcher: gated.call,
          tilePadding: 0,
          preloadAdjacentZoom: false,
        );
        addTearDown(manager.dispose);

        manager.calculate();
        final evenKeys = manager.renderTiles
            .where((t) => t.lngIndex.isEven)
            .map((t) => t.index)
            .toSet();
        while (manager.coverage().coveredCells !=
            manager.coverage().visibleCells - evenKeys.length) {
          await Future<void>.delayed(Duration.zero);
        }

        // Without an oracle, gated cells are blank (checkerboard).
        final blank = manager.coverage();
        expect(blank.coveredCells, blank.visibleCells - evenKeys.length);

        // With the zoom-fallback oracle, the same cells count as covered
        // (imagery is painted over them) while staying non-sharp.
        final fallback = manager.coverage(isFallbackCovered: evenKeys.contains);
        expect(fallback.visibleCells, blank.visibleCells);
        expect(fallback.coveredCells, fallback.visibleCells,
            reason: 'every cell now shows imagery');
        expect(fallback.sharpCells, blank.sharpCells,
            reason: 'fallback crops are never the cell\'s own image');
        expect(fallback.allCovered, isTrue);
        expect(fallback.allSharp, isFalse);
        expect(fallback.missingCells, 0);
        expect(fallback.sharpMissingCells, evenKeys.length);
      });
    });

    test('off-world rows never count as blank coverage', () async {
      await _real(() async {
        final manager = TileManager.init(
          width: 300,
          height: 300,
          centerLatLng: const LatLng(latitude: 84.5, longitude: 0),
          zoom: 5,
          fetcher: (z, x, y) async => fakeTilePng,
          tilePadding: 0,
          preloadAdjacentZoom: false,
        );
        addTearDown(manager.dispose);

        manager.calculate();
        // With no padding the render set is the strict viewport; only the
        // rows inside the world count.
        final validWorldRows = manager.renderTiles
            .where((t) => t.latIndex >= 0 && t.latIndex < (1 << 5))
            .length;
        expect(manager.coverage().visibleCells, validWorldRows);
        await _settleSharp(manager);
        expect(manager.coverage().allSharp, isTrue,
            reason: 'off-world cells can never load and never block readiness');
      });
    });
  });

  group('MapController.tileCoverage delegation', () {
    testWidgets('exposes strict-viewport coverage of the attached map',
        (tester) async {
      tester.view.physicalSize = const Size(360, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = MapController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 5,
            showZoomControls: false,
            controller: controller,
            tileFetcher: (z, x, y) async => fakeTilePng,
          ),
        ),
      ));

      expect(controller.tileCoverage, isNotNull,
          reason: 'the controller must expose coverage once attached');
      await _settleControllerCoverage(tester, controller);
      final coverage = controller.tileCoverage!;
      expect(coverage.visibleCells, greaterThan(0));
      expect(coverage.allSharp, isTrue);

      // Detaching removes the delegate: no stale coverage after dispose.
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump();
      expect(controller.tileCoverage, isNull);
    });
  });
}

/// Yields to the real event loop until every strict-viewport cell is sharp.
/// Must run inside the real zone (see [_real]).
Future<void> _settleSharp(TileManager manager) async {
  final stopwatch = Stopwatch()..start();
  while (!manager.coverage().allSharp &&
      stopwatch.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(manager.coverage().allSharp, isTrue);
}

Future<void> _settleControllerCoverage(
    WidgetTester tester, MapController controller) async {
  final watch = Stopwatch()..start();
  while (!(controller.tileCoverage?.allSharp ?? false) &&
      watch.elapsed < const Duration(seconds: 10)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(controller.tileCoverage?.allSharp ?? false, isTrue,
      reason: 'visible cells must reach sharp coverage');
}
