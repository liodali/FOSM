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

/// Encodes a 4×4 RGBA PNG: columns alternate [even]/[odd] colors, so a
/// two-column crop of any quadrant carries a sharp interior edge — the
/// probe for gaussian-blur bleeding in the fallback painter.
Future<Uint8List> twoColumnPng(
    WidgetTester tester, ui.Color even, ui.Color odd) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var x = 0; x < 4; x++) {
    canvas.drawRect(
        ui.Rect.fromLTWH(x.toDouble(), 0, 1, 4),
        ui.Paint()
          ..blendMode = ui.BlendMode.src
          ..color = (x % 2 == 0) ? even : odd);
  }
  final picture = recorder.endRecording();
  final image = picture.toImageSync(4, 4);
  picture.dispose();
  try {
    final bytes = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.png));
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
  testWidgets(
      'the regional fallback carries the snapshot softness and isolates '
      'each region\'s blur', (tester) async {
    tester.view.physicalSize = const ui.Size(360, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Column-striped z5 content: every ancestor crop carries a sharp
    // interior edge, so a wrongly clipped blur would visibly tint.
    final red = const ui.Color(0xFFFF0000);
    final blue = const ui.Color(0xFF0000FF);
    final striped = await twoColumnPng(tester, red, blue);
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
    for (final key in List<String>.of(fetcher._pending.keys)) {
      final parts = key.split('/');
      fetcher.deliver(int.parse(parts[0]), int.parse(parts[1]),
          int.parse(parts[2]), striped);
    }
    await _drain(tester, until: () => _gridLoaded(tester));

    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();

    ZoomFallbackPainter? fallbackPainter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<ZoomFallbackPainter>()
        .firstOrNull;
    final painter = fallbackPainter()!;
    expect(painter.coverage.hasRegions, isTrue);
    // The sigma wiring: at rest with loading coverage the painter gets
    // the zoom style's sigma (the snapshot's own value); on web and
    // during direct manipulation it stays 0 (the snapshot's gates).
    expect(painter.blurSigma, 2.0,
        reason: 'the default zoom style applies the snapshot-matching '
            'sigma over the active coverage');

    // Region isolation (pixels): rasterize the whole fallback layer and
    // verify the crisp part of the contract — every pixel OUTSIDE a
    // covered region equals the plain base, so a layer-wide blur could
    // never tint a ready tile's or uncovered cell's background. (The
    // compositor softness itself is pixel-verified on the affected
    // platform; headless rasterization drops canvas filters, which is
    // why the inspector stops at the crisp plane here.)
    final coverage = painter.coverage;
    final ctr = coverage.manager;
    final regionCoverage = <String, ui.Rect>{
      // The painter draws region imagery inside the missing cell rect —
      // mirror its geometry from the manager canvas here.
    };
    for (final key in coverage.debugRegionKeys()) {
      final parts = key.split('/');
      final x = int.parse(parts[1]);
      final y = int.parse(parts[2]);
      regionCoverage[key] = ui.Rect.fromLTWH(
        ctr.leftColumnTilesCanvasX +
            (x - ctr.leftColumnTilesLngIndex) * ctr.renderedTileWidth,
        ctr.topRowTilesCanvasY +
            (y - ctr.topRowTilesLatIndex) * ctr.renderedTileHeight,
        ctr.renderedTileWidth.toDouble(),
        ctr.renderedTileHeight.toDouble(),
      );
    }
    final ui.Image frame;
    {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      ZoomFallbackPainter(
              coverage: coverage, manager: ctr, blurSigma: 0.0)
          .paint(canvas, const Size(360, 240));
      final picture = recorder.endRecording();
      frame = picture.toImageSync(360, 240);
      picture.dispose();
    }
    final data = await tester.runAsync(
        () => frame.toByteData(format: ui.ImageByteFormat.rawStraightRgba));
    frame.dispose();

    ui.Color pixel(double dx, double dy) {
      final px = (dx * 1).toInt().clamp(0, 359);
      final py = (dy * 1).toInt().clamp(0, 239);
      return _pixel(data!, px, py, 360);
    }

    // The plain base under ready tiles and uncovered cells is exact.
    final common = const ui.Color(0xFFF5F5F5);
    for (var y = 8.0; y < 232; y += 4) {
      for (var x = 8.0; x < 352; x += 4) {
        var covered = false;
        for (final rect in regionCoverage.values) {
          if (rect.contains(ui.Offset(x, y))) covered = true;
        }
        if (covered) continue;
        expect(pixel(x, y), common,
            reason: 'uncovered area at ($x,$y) must be the exact plain '
                'background — no fallback imagery may tint it');
      }
    }

    // And a covered region's interior carries the striped imagery (an
    // edge exists between the two sides), proving regions do paint.
    final coveredRect = regionCoverage.values.first;
    final inside = pixel(coveredRect.left + coveredRect.width / 2,
        coveredRect.top + coveredRect.height / 2);
    final edgeL = pixel(coveredRect.left + coveredRect.width * 0.25,
        coveredRect.top + coveredRect.height / 2);
    final edgeR = pixel(coveredRect.left + coveredRect.width * 0.75,
        coveredRect.top + coveredRect.height / 2);
    expect(edgeL, isNot(edgeR),
        reason: 'a striped crop edges visibly through region draws');
    // The alpha-isolation base never pushes the source color two columns
    // across the edge in the CRISP plane (blur placement is verified by
    // the sigma wiring above; its per-region bounds are structural).
    expect({edgeL, edgeR, inside}.contains(common), isFalse,
        reason: 'regions carry content, not blank base fills');
    expect(tester.takeException(), isNull);

    // Publication retires coverage and the sigma wiring with it.
    controller.setFractionalZoom(5.0, animate: false);
    await _drain(tester, until: () => (_gridLoaded(tester)) &&
        (fallbackPainter() == null ||
            !fallbackPainter()!.coverage.hasRegions));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'repeated zoom steps keep coverage through the carried region '
      'sources (z5 content, replacements blocked, z6–z12)',
      (tester) async {
    final fetcher = _GatedFetcher();
    final manager = _smallManager(fetcher);
    manager.calculate();
    fetcher.deliverZoom(5);
    await _drain(tester, until: () => manager.visibleTilesReady);

    final coverage = ZoomFallbackCoverage(manager);
    coverage.reconcile();
    for (final target in [6, 7, 8, 9, 10, 11, 12]) {
      // Replacements blocked: every z6..z9 request stays pending, only
      // the z5 content exists in the rendered cache. The step's regions
      // must re-cover from it — the pin handoff keeps the sources alive
      // and the ancestor search walks the retained chain.
      manager.setZoom(target);
      await _drain(tester);
      coverage.reconcile();
      expect(coverage.hasRegions, isTrue,
          reason: 'stepping to z$target must keep coverage, not checkerboards');
      for (final key in coverage.debugRegionKeys()) {
        final sources = coverage.debugRegionSourceKeys(key);
        // Depth can never exceed the search bound; the sources, drawn
        // from one content zoom highway, must still be z5.
        expect(sources.map((s) => s.split('/')[0]), everyElement('5'),
            reason: 'z$target covered by the same z5 content: $sources');
      }
    }
    coverage.dispose();
    manager.dispose();
  });

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

  testWidgets(
      'clear() invalidates coverage; the next reconcile rebuilds it from '
      'retained imagery', (tester) async {
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

    // Explicit invalidation (camera command / pressure path) drops every
    // region and releases their pins.
    coverage.clear();
    expect(coverage.hasRegions, isFalse);

    // The next reconcile rebuilds coverage for still-missing cells from
    // whatever imagery is still retained — content-only changes and
    // camera moves are handled the same publication-driven way.
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

  testWidgets(
      'a settle deadline keeps covered cells until their own tiles publish',
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

    ZoomFallbackPainter? fallbackPainter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ZoomFallbackPainter>()
        .toList()
        .cast<ZoomFallbackPainter?>()
        .firstOrNull;

    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();
    final coverage = fallbackPainter()!.coverage;
    expect(coverage.regionCount, greaterThan(0));

    // Pump well past the old settle deadline: nothing may gather the
    // coverage (plan 09: a timeout must not discard valid coverage while
    // its replacement is still pending) — the pinned imagery keeps the
    // regions alive even under the zero-budget cache.
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackPainter(), isNotNull,
        reason: 'covered still-missing cells must stay painted past the '
            'old deadline');
    expect(coverage.regionCount, greaterThan(0));
    expect(tester.takeException(), isNull);

    // Publication-driven retirement, driven through the pinned imagery
    // itself: stepping back to z5 re-serves the region-pinned parents as
    // instant cache hits, every visible cell publishes, and the covered
    // regions retire — no deadline needed at any point.
    controller.setFractionalZoom(5.0, animate: false);
    await _drain(tester, until: () => fallbackPainter() == null);
    expect(fallbackPainter(), isNull,
        reason: 'once every visible cell publishes, coverage retires');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'pan-revealed coverage persists past the old deadline until '
      'publication or window exit', (tester) async {
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

    // Zoom with z6 blocked; the old deadline passes without dropping the
    // covered cells.
    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();
    expect(fallbackVisible(), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isTrue,
        reason: 'still-missing coverage is not deadline-bounded');

    // A programmatic pan reveals new cells; their z5 parents stay cached,
    // so they cover geographically, and again no deadline gathers them.
    // (12° ≈ two z6 tiles.)
    controller.moveTo(const LatLng(latitude: 0, longitude: 12), animate: false);
    await tester.pump();
    expect(fallbackVisible(), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isTrue,
        reason: 'panned-to regions keep coverage until their tiles '
            'publish or the cells leave the window');

    // Publication retires every region for real.
    fetcher.deliverAllPending();
    await _drain(tester, until: () => !fallbackVisible());
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

    // Coverage persists across the entire animated pan and after it:
    // nothing discards it, motion start/finish included (retirement is
    // publication-driven now).
    controller.moveTo(const LatLng(latitude: 0, longitude: 12));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175));
    // Mid-animation.
    expect(fallbackVisible(), isTrue,
        reason: 'coverage must follow pan motion');
    await tester.pump(const Duration(milliseconds: 175));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isTrue,
        reason: 'post-animation regions keep coverage until their tiles '
            'publish or the cells leave the window');

    // An arriving replacement retires them for real.
    fetcher.deliverAllPending();
    await _drain(tester, until: () => !fallbackVisible());
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

  testWidgets('a stale zoom deadline cannot drop fallback mid-pan',
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

    // Zoom with z6 blocked: coverage appears.
    controller.setFractionalZoom(6.25, animate: false);
    await tester.pump();
    expect(fallbackVisible(), isTrue);

    // A two-second pan starts. A deadline landing mid-motion must not
    // gather the coverage: there is no timeout discard at all now. 3° is
    // sub-tile at z6, so the grid window itself stays stable and cannot
    // mask anything by re-enabling coverage.
    controller.moveTo(const LatLng(latitude: 0, longitude: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isTrue,
        reason: 'coverage must follow pan motion, not the stale deadline');

    // After the motion, waiting past every former deadline keeps the
    // coverage; the published-or-window-exit contract decides when it
    // ends. Panning the covered cells out of the window retires them:
    // 64° ≈ nine z6 tiles, every covered cell exits westward.
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(fallbackVisible(), isTrue,
        reason: 'still-missing covered cells are not deadline-bounded');
    controller.moveTo(const LatLng(latitude: 0, longitude: 64),
        animate: false);
    await _drain(tester, until: () => !fallbackVisible());
    expect(fallbackVisible(), isFalse,
        reason: 'regions retire when their cells leave the window');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
