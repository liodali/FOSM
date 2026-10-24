import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/view/render.dart';
import 'package:fosm/src/view/zoom_fallback.dart';

/// Minimal valid 1×1 RGBA PNG — decodable by Flutter's image codec.
final Uint8List tinyTilePng = Uint8List.fromList([
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

/// Encodes a 1×1 PNG of a solid [color] (or fully transparent when null).
Future<Uint8List> _unitPng(WidgetTester tester, ui.Color? color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
      .drawColor(color ?? const ui.Color(0x00000000), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  try {
    final bytes = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    );
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Pixel color of a rasterized fallback painting.
ui.Color _pixel(ByteData data, int x, int y, int width) {
  final offset = (y * width + x) * 4;
  return ui.Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}

/// Deterministic per-tile fetcher: requests stay pending until the test
/// completes them, so coverage can be observed mid-replacement.
class _GatedFetcher {
  final _pending = <String, Completer<Uint8List>>{};

  Future<Uint8List> call(int z, int x, int y) {
    final completer = Completer<Uint8List>();
    _pending['$z/$x/$y'] = completer;
    return completer.future;
  }

  bool get hasPending => _pending.isNotEmpty;

  void deliver(int z, int x, int y, [Uint8List? bytes]) {
    final completer = _pending.remove('$z/$x/$y');
    if (completer != null && !completer.isCompleted) {
      completer.complete(bytes ?? tinyTilePng);
    }
  }

  void fail(int z, int x, int y) {
    final completer = _pending.remove('$z/$x/$y');
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
          const TileLoadException(TileFailureKind.http, 'gated failure'));
    }
  }

  void deliverZoom(int z, [Uint8List? bytes]) {
    for (final key in List<String>.of(_pending.keys)) {
      if (!key.startsWith('$z/')) continue;
      final completer = _pending.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete(bytes ?? tinyTilePng);
      }
    }
  }

  /// Delivers every still-pending request regardless of zoom.
  void deliverAllPending() {
    for (final key in List<String>.of(_pending.keys)) {
      final completer = _pending.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete(tinyTilePng);
      }
    }
  }
}

/// Lets real async work (decodes) and scheduled frames run until
/// [until] holds, with a bounded number of turns. Pumps advance no
/// clock time: fake-time timers (like the fallback settle timeout) must
/// not fire merely because loading was slow.
Future<void> _drain(WidgetTester tester,
    {bool Function()? until, int turns = 40}) async {
  for (var i = 0; i < turns; i++) {
    if (until != null && until()) return;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

TileManager _smallManager(_GatedFetcher fetcher, {int zoom = 5}) =>
    TileManager.init(
      width: 256,
      height: 256,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: zoom,
      fetcher: fetcher.call,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      maxRenderedCacheBytes: 64 * 1024 * 1024,
    );

/// Whether the first grid painter in the tree has every image loaded.
bool _gridLoaded(WidgetTester tester) {
  final painters = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((widget) => widget.painter)
      .whereType<RenderCanvasOSM>()
      .toList();
  return painters.isNotEmpty &&
      painters.first.tiles.every((tile) => tile.sourceTile != null);
}

void main() {
  testWidgets('zoom-in covers each missing cell with its parent region',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher);
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);
    expect(manager.visibleTilesReady, isTrue);

    manager.setZoom(6);
    await _drain(tester);
    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();

    // Every missing cell at z6 is covered, each reusing its z5 parent.
    expect(coverage.regionCount, manager.renderTiles.length);
    for (final tile in manager.renderTiles) {
      final sources = coverage.debugRegionSourceKeys(tile.index);
      expect(sources, contains('5/${tile.lngIndex ~/ 2}/${tile.latIndex ~/ 2}'),
          reason: 'cell ${tile.index} should reuse its parent imagery');
    }
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('regions retire independently as replacement tiles arrive',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher);
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);

    manager.setZoom(6);
    await _drain(tester);
    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();
    final total = coverage.regionCount;
    expect(total, greaterThan(1));

    final retiring = manager.renderTiles.first;
    fetcher.deliver(6, retiring.lngIndex, retiring.latIndex);
    await _drain(tester, until: () => retiring.sourceTile != null);
    coverage.reconcile();

    expect(coverage.debugRegionKeys(), isNot(contains(retiring.index)));
    expect(coverage.regionCount, total - 1);
    for (final other
        in manager.renderTiles.where((tile) => tile.index != retiring.index)) {
      expect(coverage.debugRegionKeys(), contains(other.index));
    }
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('zoom-out composes child quadrants over the missing cell',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher, zoom: 6);
    manager.calculate();
    fetcher.deliverZoom(6);
    await _drain(tester, until: () => manager.visibleTilesReady);
    expect(manager.visibleTilesReady, isTrue);

    manager.setZoom(5);
    await _drain(tester);
    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();

    // The z6 window (cells 31–32 × 31–32) straddles all four z5 cells of
    // the z5 window (15–16 × 15–16): each missing cell composes from the
    // cached child quadrant that overlaps it — geographic reuse without
    // any z4 ancestor (no base crop exists).
    final keys = coverage.debugRegionKeys()..sort();
    expect(keys, ['5/15/15', '5/15/16', '5/16/15', '5/16/16']);
    for (final key in keys) {
      final x = int.parse(key.split('/')[1]);
      final y = int.parse(key.split('/')[2]);
      // Cell 15 overlaps cached child 31; cell 16 overlaps child 32.
      final cx = x == 15 ? 31 : 32;
      final cy = y == 15 ? 31 : 32;
      expect(coverage.debugRegionSourceKeys(key), ['6/$cx/$cy']);
      expect(coverage.debugRegionDrawCount(key), 1);
    }
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('repeated zoom reversal keeps coverage from both directions',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher);
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);

    final coverage = ZoomFallbackCoverage(manager);

    // In: cells at z6 fall back to z5 parents.
    manager.setZoom(6);
    await _drain(tester);
    coverage.reconcile();
    expect(coverage.regionCount, greaterThan(0));
    expect(coverage.debugRegionSourceKeys('6/31/31'), contains('5/15/15'));

    // Back out: every z5 cell is an instantaneous cache hit, so no
    // fallback is needed at all — reversing must not leave stale regions.
    manager.setZoom(5);
    await _drain(tester);
    coverage.reconcile();
    expect(coverage.hasRegions, isFalse);
    expect(manager.visibleTilesReady, isTrue);

    // In again: the still-blocked z6 cells fall back to parents again.
    manager.setZoom(6);
    await _drain(tester);
    coverage.reconcile();
    expect(coverage.regionCount, greaterThan(0));
    expect(coverage.debugRegionSourceKeys('6/31/31'), contains('5/15/15'));
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('panning mid-transition covers newly revealed cells',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher);
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);

    manager.setZoom(6);
    await _drain(tester);
    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();
    final before = coverage.debugRegionKeys().toList()..sort();
    expect(before, isNotEmpty);

    // Pan one tile east without loading anything at z6: cells that left
    // the viewport retire, newly revealed cells get their own coverage
    // from retained parent imagery.
    manager.setCenterFromTileCoords(
        manager.centerTileLng + 1, manager.centerTileLat);
    manager.calculate();
    await _drain(tester);
    coverage.reconcile();

    final after = coverage.debugRegionKeys().toList()..sort();
    expect(after, isNotEmpty);
    expect(after, isNot(equals(before)));
    // Cells that panned out of the window retired; the newly revealed
    // column is covered.
    expect(after, isNot(contains('6/31/31')));
    expect(after, isNot(contains('6/31/32')));
    expect(after, containsAll(['6/33/31', '6/33/32']));
    // New cells reuse parent imagery at their own coordinates.
    expect(coverage.debugRegionSourceKeys('6/33/31'), contains('5/16/15'));
    expect(coverage.debugRegionSourceKeys('6/33/32'), contains('5/16/16'));
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('failed tiles keep fallback while loaded neighbours retire',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher);
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);

    manager.setZoom(6);
    await _drain(tester);
    final stuck = manager.renderTiles.first;
    fetcher.fail(6, stuck.lngIndex, stuck.latIndex);
    for (final tile
        in manager.renderTiles.where((tile) => tile.index != stuck.index)) {
      fetcher.deliver(6, tile.lngIndex, tile.latIndex);
    }
    await _drain(tester, until: () {
      final loaded = manager.renderTiles
          .where((tile) => tile.index != stuck.index)
          .every((tile) => tile.sourceTile != null);
      return loaded;
    });

    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();
    expect(coverage.regionCount, 1);
    expect(coverage.debugRegionKeys(), [stuck.index]);
    expect(coverage.debugRegionSourceKeys(stuck.index),
        contains('5/${stuck.lngIndex ~/ 2}/${stuck.latIndex ~/ 2}'));
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('region draws stay bounded under sparse retention',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher, zoom: 6);
    manager.calculate();
    // Deliver only a scattered subset at z6 so regions must compose from
    // partial quadrants without exceeding the draw cap.
    var delivered = 0;
    for (final key in List<String>.of(fetcher._pending.keys)) {
      if (delivered++ % 3 != 0) continue;
      final parts = key.split('/');
      fetcher.deliver(
          int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    }
    await _drain(tester);

    manager.setZoom(5);
    await _drain(tester);
    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();
    final keys = coverage.debugRegionKeys();
    expect(keys, isNotEmpty);
    for (final key in keys) {
      expect(coverage.debugRegionDrawCount(key),
          inInclusiveRange(1, ZoomFallbackCoverage.maxDrawsPerRegion));
    }
    expect(keys.length, lessThanOrEqualTo(manager.visibleTileCount));
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('retirement releases pins promptly under a zero budget',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = TileManager.init(
      width: 256,
      height: 256,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      fetcher: fetcher.call,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      maxRenderedCacheBytes: 0,
    );
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);
    final parentImages = manager.renderTiles
        .map((tile) => tile.sourceTile)
        .whereType<ui.Image>()
        .toList();
    expect(parentImages, isNotEmpty);

    // Zoom switches must go through the transition-pin protocol (as
    // MapView does) so a zero budget cannot evict the old imagery before
    // regions reconcile.
    final coverage = ZoomFallbackCoverage(manager);
    coverage.beginZoomTransition();
    manager.setZoom(6);
    await _drain(tester);
    coverage.reconcile();
    expect(coverage.regionCount, greaterThan(0));
    // Pinned parents survive the zero budget.
    expect(parentImages.every((image) => !image.debugDisposed), isTrue);

    fetcher.deliverZoom(6);
    await _drain(tester, until: () => manager.visibleTilesReady);
    coverage.reconcile();
    expect(coverage.regionCount, 0);
    // Every pin went away with its region; the zero budget evicts.
    expect(parentImages.every((image) => image.debugDisposed), isTrue);
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('panning under a zero budget keeps shared-ancestor coverage',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = TileManager.init(
      width: 256,
      height: 256,
      centerLatLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      fetcher: fetcher.call,
      tilePadding: 0,
      preloadAdjacentZoom: false,
      maxRenderedCacheBytes: 0,
    );
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);

    final coverage = ZoomFallbackCoverage(manager);
    coverage.beginZoomTransition();
    manager.setZoom(6);
    await _drain(tester);
    coverage.reconcile();
    expect(coverage.regionCount, greaterThan(0));

    // Pan two tiles east: the new window shares no cells with the old
    // one, but its cells' parents are pinned only by retiring regions.
    // Acquiring the replacement pins before the releases is what keeps
    // that shared imagery alive under the zero budget.
    manager.setCenterFromTileCoords(
        manager.centerTileLng + 2, manager.centerTileLat);
    manager.calculate();
    await _drain(tester);
    coverage.reconcile();

    final keys = coverage.debugRegionKeys()..sort();
    // Column 33's parent (5/16/…) survived; column 34's parent (5/17/…)
    // was never retained, so those cells keep plain checkerboards.
    expect(keys, ['6/33/31', '6/33/32']);
    expect(coverage.debugRegionSourceKeys('6/33/31'), contains('5/16/15'));
    expect(coverage.debugRegionSourceKeys('6/33/32'), contains('5/16/16'));
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('suspend drops coverage until the grid window changes',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher);
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);

    manager.setZoom(6);
    await _drain(tester);
    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();
    expect(coverage.regionCount, greaterThan(0));

    coverage.suspend();
    expect(coverage.hasRegions, isFalse);
    // Content-only changes (a late tile arriving) must not resurrect it.
    final arriving = manager.renderTiles.first;
    fetcher.deliver(6, arriving.lngIndex, arriving.latIndex);
    await _drain(tester, until: () => arriving.sourceTile != null);
    coverage.reconcile();
    expect(coverage.hasRegions, isFalse);

    // A grid membership change re-enables coverage for missing cells.
    manager.setCenterFromTileCoords(
        manager.centerTileLng + 2, manager.centerTileLat);
    manager.calculate();
    await _drain(tester);
    coverage.reconcile();
    expect(coverage.regionCount, greaterThan(0));
    coverage.dispose();
    manager.dispose();
  });

  testWidgets('widget paints fallback regions and retires with arrivals',
      (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _GatedFetcher();
    final controller = MapController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      enableFractionalZoom: true,
      controller: controller,
      tileFetcher: fetcher.call,
    ))));
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => _gridLoaded(tester));

    Finder fallbackLayer() => find.byWidgetPredicate((widget) =>
        widget is CustomPaint && widget.painter is ZoomFallbackPainter);

    expect(fallbackLayer(), findsNothing);

    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();

    // Missing cells are covered by retained z5 imagery beneath the grid.
    expect(fallbackLayer(), findsOneWidget);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ZoomFallbackPainter>()
        .single;
    final total = painter.coverage.regionCount;
    expect(total, greaterThan(0));
    // The grid above skips its own placeholder/background passes.
    final grid = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<RenderCanvasOSM>()
        .single;
    expect(grid.paintPlaceholders, isFalse);
    expect(grid.paintBackground, isFalse);

    for (var i = 0; i < 10 && fetcher.hasPending; i++) {
      fetcher.deliverAllPending();
      await _drain(tester);
    }
    expect(fetcher.hasPending, isFalse);
    await tester.pump();
    expect(fallbackLayer(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('settle timeout suspends fallback for still-missing cells',
      (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _GatedFetcher();
    final controller = MapController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      enableFractionalZoom: true,
      controller: controller,
      tileFetcher: fetcher.call,
      maxRenderedCacheBytes: 0,
    ))));
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => _gridLoaded(tester));

    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();

    final coverage = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ZoomFallbackPainter>()
        .single
        .coverage;
    expect(coverage.regionCount, greaterThan(0));

    // Nothing arrives at z6 — the settle timeout drops the coverage and
    // the zero-budget cache disposes the unpinned old imagery.
    await tester.pump(const Duration(milliseconds: 700));
    final fallbackPainters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ZoomFallbackPainter>()
        .toList();
    expect(fallbackPainters, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('programmatic instant pan settles its newly revealed fallback',
      (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _GatedFetcher();
    final controller = MapController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      enableFractionalZoom: true,
      controller: controller,
      tileFetcher: fetcher.call,
    ))));
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => _gridLoaded(tester));

    bool fallbackVisible() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ZoomFallbackPainter>()
        .isNotEmpty;

    // Zoom with z6 blocked, then consume the zoom's own settle timeout.
    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();
    expect(fallbackVisible(), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isFalse);

    // A programmatic pan reveals new cells; the window change re-enables
    // coverage, and the post-move settle must bound it with a timeout.
    // (12° ≈ two z6 tiles — the new cells' z5 parents stay cached.)
    controller.moveTo(const LatLng(latitude: 0, longitude: 12), animate: false);
    await tester.pump();
    expect(fallbackVisible(), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isFalse,
        reason: 'panned-to regions must settle, not retain imagery forever');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('animated pan settles its fallback on completion',
      (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _GatedFetcher();
    final controller = MapController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      enableFractionalZoom: true,
      controller: controller,
      tileFetcher: fetcher.call,
    ))));
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => _gridLoaded(tester));

    bool fallbackVisible() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ZoomFallbackPainter>()
        .isNotEmpty;

    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isFalse);

    // The animated pan re-enables coverage while it moves; the settle
    // that bounds it fires only after the animation completes.
    // (12° ≈ two z6 tiles — the window changes and parents stay cached.)
    controller.moveTo(const LatLng(latitude: 0, longitude: 12));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175));
    // Mid-animation: coverage follows the motion, no timeout yet.
    // Finish the 350 ms pan. The completion continuation may land on
    // either of the next frames in fake-async, so pump generously past
    // the animation and past the settle deadline.
    await tester.pump(const Duration(milliseconds: 175));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isFalse,
        reason: 'post-animation regions must settle, not persist forever');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'transparent descendant quadrants never blend over the '
      'ancestor base', (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final red = await _unitPng(tester, const ui.Color(0xFFFF0000));
    final transparent = await _unitPng(tester, null);
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher, zoom: 3);
    manager.calculate();
    for (final key in List<String>.of(fetcher._pending.keys)) {
      final parts = key.split('/');
      fetcher.deliver(
          int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]), red);
    }
    await _drain(tester, until: () => manager.visibleTilesReady);

    // z5 window (15–16)²: everything red except a transparent child at
    // 15/15 — the bottom-right quadrant of z4 cell 7/7.
    manager.setZoom(5);
    await _drain(tester);
    for (final key in List<String>.of(fetcher._pending.keys)) {
      final parts = key.split('/');
      fetcher.deliver(int.parse(parts[0]), int.parse(parts[1]),
          int.parse(parts[2]), key == '5/15/15' ? transparent : red);
    }
    await _drain(tester);

    final coverage = ZoomFallbackCoverage(manager);
    coverage.beginZoomTransition();
    manager.setZoom(4);
    await _drain(tester);
    coverage.reconcile();

    // Cell 4/7/7 = red z3 base + the transparent z5 child refinement.
    expect(coverage.debugRegionSourceKeys('4/7/7'),
        containsAll(['3/3/3', '5/15/15']));

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    ZoomFallbackPainter(coverage: coverage, manager: manager)
        .paint(canvas, const Size(256, 256));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(256, 256);
    picture.dispose();
    final data = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba));
    image.dispose();
    expect(data, isNotNull);

    // The transparent child quadrant shows the plain background, not the
    // red ancestor beneath it (cell 7/7 occupies (-128,-128)-(128,128);
    // its bottom-right quadrant is the visible (0,0)-(128,128) area).
    expect(_pixel(data!, 64, 64, 256), const ui.Color(0xFFF5F5F5));
    // Neighbouring imagery is still painted (cell 8/8's red child).
    expect(_pixel(data, 192, 192, 256), const ui.Color(0xFFFF0000));

    coverage.dispose();
    manager.dispose();
  });

  testWidgets('an earlier settle timer cannot suspend fallback mid-pan',
      (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _GatedFetcher();
    final controller = MapController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 5,
      enableFractionalZoom: true,
      controller: controller,
      tileFetcher: fetcher.call,
      // Slow animated pans, so a 600 ms settle deadline lands mid-motion.
      zoomAnimationDuration: const Duration(milliseconds: 2000),
    ))));
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => _gridLoaded(tester));

    bool fallbackVisible() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ZoomFallbackPainter>()
        .isNotEmpty;

    // Zoom with z6 blocked: coverage appears and its settle timer arms.
    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();
    expect(fallbackVisible(), isTrue);

    // A two-second pan starts. The stale zoom timer (600 ms) must not
    // suspend coverage mid-motion. 3° is sub-tile at z6, so the grid
    // window itself stays stable and cannot mask the suspension by
    // re-enabling coverage.
    controller.moveTo(const LatLng(latitude: 0, longitude: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isTrue,
        reason: 'coverage must follow pan motion, not the stale timer');

    // Finish the pan; the completion settle bounds the coverage again
    // (the completion continuation may land on a later frame, so pump
    // generously past both the motion and the re-armed deadline).
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
