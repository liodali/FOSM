import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart'
    show lat2TileY, lon2TileX;
import 'package:fosm/src/common/utils.dart' show tileHeight, tileWidth;
import 'package:fosm/src/view/render.dart';

/// Minimal valid 1×1 RGBA PNG — decodable by Flutter's image codec.
final Uint8List _tinyPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

/// Solid 256×256 images so tile placement is visible in raster comparisons.
Future<ui.Image> _solidImage(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 256, 256), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(256, 256);
  picture.dispose();
  return image;
}

/// Encodable solid-color tile bytes so MapView-level tests can assert on
/// composited pixels. Full 256×256: at tileScale 1 the painter's fast
/// path draws the image unscaled, so smaller images leave most of the
/// tile as background.
Future<Uint8List> _solidTilePng(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 256, 256), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(256, 256);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// Rasterizes the [key]'s boundary and returns the raw RGBA bytes plus
/// dimensions of the image.
Future<(Uint8List, int, int)> _rasterize(
  WidgetTester tester,
  GlobalKey key,
) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  final boundary = key.currentContext!.findRenderObject()
      as RenderRepaintBoundary;
  late final ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage();
  });
  final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba));
  final bytes = data!.buffer.asUint8List();
  final result = (bytes, image.width, image.height);
  image.dispose();
  return result;
}

/// Waits until the grid painter's captured tiles all hold images —
/// real async work (PNG decode, publication) that pumpAndSettle alone
/// never advances in the test binding.
Future<void> _waitForTilesPublished(WidgetTester tester) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 10)) {
    await tester.runAsync(() async {
      final turn = Stopwatch()..start();
      while (turn.elapsed < const Duration(milliseconds: 20)) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump(const Duration(milliseconds: 16));
    final painters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<RenderCanvasOSM>()
        .toList();
    if (painters.isNotEmpty &&
        painters.first.tiles.isNotEmpty &&
        painters.first.tiles.every((tile) => tile.sourceTile != null)) {
      return;
    }
  }
  fail('tile imagery never published');
}

/// Fraction of pixels in a 4-physical-px edge band that match [rgb]
/// within a small tolerance (solid-color tiles survive the PNG
/// round-trip and compositor filtering exactly, so a real miss is
/// unambiguous).
double _edgeCoverage(
  Uint8List rgba,
  int width,
  int height,
  bool rightEdge,
  List<int> rgb,
) {
  var matches = 0;
  var total = 0;
  for (var y = 0; y < height; y += 8) {
    for (var dx = 0; dx < 4; dx++) {
      final x = rightEdge ? width - 1 - dx : dx;
      final i = (y * width + x) * 4;
      final near = (rgba[i] - rgb[0]).abs() <= 8 &&
          (rgba[i + 1] - rgb[1]).abs() <= 8 &&
          (rgba[i + 2] - rgb[2]).abs() <= 8;
      if (near) matches++;
      total++;
    }
  }
  return matches / total;
}

RenderCanvasOSM _gridPainter(WidgetTester tester) {
  final painters = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .whereType<RenderCanvasOSM>()
      .toList();
  expect(painters, hasLength(1), reason: 'exactly one grid painter exists');
  return painters.single;
}

/// Pumps a map whose fetchers resolve through [completers] (completed on
/// first request unless [hold] names a key that must stay pending) and
/// waits until every unheld foreground tile published. [settleBudget]
/// bounds the wait; large test surfaces admit hundreds of tiles and the
/// publish pipeline needs longer than the default under suite load.
Future<MapController> _pumpSettledMap(
  WidgetTester tester, {
  required Map<String, Completer<Uint8List>> completers,
  String? hold,
  Duration settleBudget = const Duration(seconds: 5),
}) async {
  final controller = MapController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MapView(
          controller: controller,
          latLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 10,
          tileFetcher: (z, x, y) {
            final key = '$z/$x/$y';
            return completers.putIfAbsent(key, () {
              final completer = Completer<Uint8List>();
              if (hold == null || key != hold) {
                completer.complete(_tinyPng);
              }
              return completer;
            }).future;
          },
          showZoomControls: false,
          animateZoom: false,
        ),
      ),
    ),
  );
  await tester.pump();

  int loadedCount() => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .whereType<RenderCanvasOSM>()
      .single
      .tiles
      .where((tile) => tile.sourceTile != null)
      .length;

  final target = completers.length - (hold == null ? 0 : 1);
  final watch = Stopwatch()..start();
  while (loadedCount() < target &&
      watch.elapsed < settleBudget) {
    await tester.runAsync(() async {
      final turn = Stopwatch()..start();
      while (loadedCount() < target &&
          turn.elapsed < const Duration(milliseconds: 20)) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(loadedCount(), target,
      reason: 'all unheld requested tiles must publish during settle');
  await tester.pumpAndSettle(const Duration(seconds: 1));
  return controller;
}

void main() {
  setUp(() {
    RenderCanvasOSM.debugPaintCount = 0;
  });

  tearDown(() {
    MapView.gridLayerEnabled = MapView.gridLayerByDefine;
  });

  group('retained grid layer geometry', () {
    testWidgets(
        'painter output with captured anchors plus translation equals '
        'live-anchor painting', (tester) async {
      final blue = (await tester.runAsync(
              () => _solidImage(const Color(0xFF3366AA)))) ??
          (throw StateError('image failed'));
      final amber = (await tester.runAsync(
              () => _solidImage(const Color(0xFFCC9922)))) ??
          (throw StateError('image failed'));
      final tiles = <Tile>[
        Tile(blue, '10/5/3', 3, 5),
        Tile(amber, '10/6/3', 3, 6),
        Tile(null, '10/7/3', 3, 7), // placeholder parity exercise
        Tile(blue, '10/5/4', 4, 5),
        Tile(amber, '10/6/4', 4, 6),
        Tile(null, '10/7/4', 4, 7),
      ];
      const size = Size(500, 400);
      const live = Offset(-100.4, -30.75);
      const captured = Offset(-150.9, -77.25);
      final delta = live - captured;

      RenderCanvasOSM painterAt(Offset anchor) => RenderCanvasOSM(
            horizontalTileCount: 3,
            verticalTileCount: 2,
            leftColumnTilesLngIndex: 5,
            topRowTilesLatIndex: 3,
            leftColumnTilesCanvasX: anchor.dx,
            topRowTilesCanvasY: anchor.dy,
            tiles: tiles,
            revision: 7,
            paintBackground: false,
          );

      Future<ui.Image> raster(bool translated) {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        if (translated) canvas.translate(delta.dx, delta.dy);
        painterAt(translated ? captured : live).paint(canvas, size);
        final picture = recorder.endRecording();
        return picture.toImage(500, 400);
      }

      final direct =
          (await tester.runAsync(() => raster(false))) ?? (throw StateError('raster failed'));
      final layered =
          (await tester.runAsync(() => raster(true))) ?? (throw StateError('raster failed'));
      final directBytes =
          (await tester.runAsync(() => direct.toByteData())) ??
          (throw StateError('byteData failed'));
      final layeredBytes =
          (await tester.runAsync(() => layered.toByteData())) ??
          (throw StateError('byteData failed'));
      expect(directBytes.lengthInBytes, layeredBytes.lengthInBytes);
      expect(
        layeredBytes.buffer.asUint8List(),
        directBytes.buffer.asUint8List(),
        reason: 'painting captured anchors on a translated canvas must '
            'produce the same raster as painting live anchors directly',
      );
      blue.dispose();
      amber.dispose();
      direct.dispose();
      layered.dispose();
    });
  });

  group('retained grid layer invalidation', () {
    testWidgets('sub-tile pan moves the layer without repainting the grid',
        (tester) async {
      MapView.gridLayerEnabled = true;
      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester, completers: completers);

      final paints0 = RenderCanvasOSM.debugPaintCount;
      final painter0 = _gridPainter(tester);

      // Sub-tile pan at z10: one tile is 360/1024 ≈ 0.3516° of longitude.
      // Sequential per-frame pans: every frame rebuilds and changes the
      // transform offset only; the retained layer moves without repaints.
      // A repaint is legitimate exactly when the capture identity changes
      // (membership window, revision or scale) — count those separately.
      var paints = paints0;
      var panLng = 0.01;
      var prev = painter0;
      var recaptures = 0;
      for (var i = 0; i < 15; i++) {
        panLng += 0.01;
        controller.moveTo(
            LatLng(latitude: 0.0005, longitude: panLng), animate: false);
        await tester.pump();
        final cur = _gridPainter(tester);
        final identityChanged = cur.revision != prev.revision ||
            cur.tileScale != prev.tileScale ||
            cur.leftColumnTilesLngIndex != prev.leftColumnTilesLngIndex ||
            cur.topRowTilesLatIndex != prev.topRowTilesLatIndex ||
            cur.horizontalTileCount != prev.horizontalTileCount ||
            cur.verticalTileCount != prev.verticalTileCount ||
            cur.paintBackground != prev.paintBackground ||
            cur.paintPlaceholders != prev.paintPlaceholders;
        if (identityChanged) {
          recaptures++;
          expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints),
              reason: 'frame $i: an identity change must repaint the grid');
        } else {
          expect(RenderCanvasOSM.debugPaintCount, paints,
              reason: 'frame $i: sub-tile motion must move the retained '
                  'layer, not repaint the grid (identity unchanged)');
        }
        // While identity is unchanged the painter keeps its captured
        // anchors; a recapture legitimately re-anchors.
        if (!identityChanged) {
          expect(cur.leftColumnTilesCanvasX, prev.leftColumnTilesCanvasX,
              reason: 'frame $i: the painter keeps the captured anchors');
          expect(cur.topRowTilesCanvasY, prev.topRowTilesCanvasY);
        }
        paints = RenderCanvasOSM.debugPaintCount;
        prev = cur;
      }
      expect(recaptures, lessThan(15),
          reason: 'sub-tile pans must be retention-dominated');

      // A larger pan crosses a tile boundary and must recapture.
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.4), animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints),
          reason: 'crossing a tile boundary must recapture the layer');
    });

    testWidgets('tile arrivals repaint the retained layer', (tester) async {
      MapView.gridLayerEnabled = true;
      final completers = <String, Completer<Uint8List>>{};
      final controller =
          await _pumpSettledMap(tester, completers: completers, hold: '10/512/511');

      final held = completers['10/512/511']!;
      final paints0 = RenderCanvasOSM.debugPaintCount;

      // Sub-tile pan first: no repaint while imagery is unchanged.
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.01), animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, paints0);

      held.complete(_tinyPng);
      final watch = Stopwatch()..start();
      while (RenderCanvasOSM.debugPaintCount == paints0 &&
          watch.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints0),
          reason: 'publishing an image must recapture the layer');
    });

    testWidgets('fractional zoom repaints the grid every frame',
        (tester) async {
      MapView.gridLayerEnabled = true;
      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester, completers: completers);

      final paints0 = RenderCanvasOSM.debugPaintCount;
      controller.setFractionalZoom(10.3, animate: false);
      await tester.pump();
      final paints1 = RenderCanvasOSM.debugPaintCount;
      expect(paints1, greaterThan(paints0),
          reason: 'a tile-scale change must repaint the grid');
      expect(_gridPainter(tester).tileScale,
          closeTo(math.pow(2, 0.3).toDouble(), 1e-9));

      controller.setFractionalZoom(10.3, animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, paints1,
          reason: 'an identical camera must keep the layer retained');
    });

    testWidgets('recapture counters classify scale, content and membership',
        (tester) async {
      MapView.gridLayerEnabled = true;
      final completers = <String, Completer<Uint8List>>{};
      final controller =
          await _pumpSettledMap(tester, completers: completers, hold: '10/512/511');

      // Fractional zoom: scale-driven recapture (Phase B's target — the
      // counters make the per-frame recapture cost visible).
      var recaptures = MapView.debugGridRecaptures.total;
      controller.setFractionalZoom(10.25, animate: false);
      await tester.pump();
      expect(MapView.debugGridRecaptures.total - recaptures, 1,
          reason: 'one fractional zoom step, one recapture');

      // Sub-tile pan: no recapture at all.
      recaptures = MapView.debugGridRecaptures.total;
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.01), animate: false);
      await tester.pump();
      expect(MapView.debugGridRecaptures.total - recaptures, 0,
          reason: 'sub-tile motion must keep the retained layer');

      // Tile arrival: content-driven recapture.
      final content0 = MapView.debugGridRecaptures.content;
      completers['10/512/511']!.complete(_tinyPng);
      final watch = Stopwatch()..start();
      while (MapView.debugGridRecaptures.content == content0 &&
          watch.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(MapView.debugGridRecaptures.content, greaterThan(content0),
          reason: 'publishing an image must count a content recapture');

      // Boundary-crossing pan: membership-driven recapture, and — the
      // plan-13 review fix — a membership change alone must NOT count as
      // a tile arrival even though the combined revision moves.
      final membership0 = MapView.debugGridRecaptures.membership;
      final contentBeforePan = MapView.debugGridRecaptures.content;
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.4), animate: false);
      await tester.pump();
      expect(MapView.debugGridRecaptures.membership, greaterThan(membership0),
          reason: 'crossing a tile boundary must count a membership change');
      // Give any pending tile completions a chance to land; the held and
      // pending fetchers never complete, so no imagery can arrive here.
      await tester.pump(const Duration(milliseconds: 100));
      expect(MapView.debugGridRecaptures.content, contentBeforePan,
          reason: 'a membership rebuild without new imagery must not '
              'count as a content (tile-arrival) recapture');
    });

    testWidgets('define-off keeps the historical repaint-per-frame painter',
        (tester) async {
      MapView.gridLayerEnabled = false;
      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester, completers: completers);

      final paints0 = RenderCanvasOSM.debugPaintCount;
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.01), animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints0),
          reason: 'without the candidate every camera frame repaints');
    });
  });

  group('retained-scale grid (plan-13 Phase B)', () {
    setUp(() {
      MapView.gridLayerEnabled = true;
      MapView.gridRetainedScaleEnabled = true;
    });

    tearDown(() {
      MapView.gridRetainedScaleEnabled = MapView.gridRetainedScaleByDefine;
      MapView.gridLayerEnabled = MapView.gridLayerByDefine;
    });

    /// Logical viewport size of the test surface.
    Size viewSize(WidgetTester tester) => Size(
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        );

    /// The camera Transform applied outside the grid repaint boundary.
    Transform gridTransform(WidgetTester tester) {
      final grid = find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter is RenderCanvasOSM);
      final transforms = tester.widgetList<Transform>(
          find.ancestor(of: grid.first, matching: find.byType(Transform)));
      expect(transforms, hasLength(1),
          reason: 'the grid layer sits under exactly one outer transform '
              '(no zoom-snapshot overlay in these tests)');
      return transforms.single;
    }

    testWidgets(
        'fractional zoom within one source zoom keeps the layer retained',
        (tester) async {
      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester, completers: completers);

      final painter0 = _gridPainter(tester);
      final paints0 = RenderCanvasOSM.debugPaintCount;

      // A pinch sweep inside zoom 10: every frame rebuilds the widget and
      // changes the outer transform only; the captured raster must never
      // repaint, and the painter keeps its captured identity (tileScale,
      // anchors, tile snapshot) — the fractional scale lives entirely in
      // the outer transform.
      for (final zoom in const [10.15, 10.3, 10.42, 10.49]) {
        controller.setFractionalZoom(zoom, animate: false);
        await tester.pump();
        expect(RenderCanvasOSM.debugPaintCount, paints0,
            reason: 'zoom $zoom: retained scale must recomposite the layer '
                'without repainting the grid');
        final painter = _gridPainter(tester);
        expect(painter.tileScale, painter0.tileScale,
            reason: 'zoom $zoom: the painter keeps the captured tile scale');
        expect(painter.leftColumnTilesCanvasX, painter0.leftColumnTilesCanvasX,
            reason: 'zoom $zoom: the painter keeps the captured anchors');
        expect(painter.topRowTilesCanvasY, painter0.topRowTilesCanvasY);
        expect(painter.tiles, same(painter0.tiles),
            reason: 'zoom $zoom: the painter keeps the captured tile '
                'snapshot');
      }
    });

    testWidgets(
        'the outer transform matches the manager camera mapping '
        '(focal and center preservation)', (tester) async {
      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester, completers: completers);

      // Pan first so the camera center is not tile-aligned; the captured
      // grid then sits at a non-integer anchor and the check exercises
      // both the scale and the translation terms.
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.01), animate: false);
      await tester.pump();
      final painter0 = _gridPainter(tester);

      final leftLng = painter0.leftColumnTilesLngIndex;
      final topLat = painter0.topRowTilesLatIndex;
      final anchorBoxX = painter0.leftColumnTilesCanvasX;
      final anchorBoxY = painter0.topRowTilesCanvasY;
      final tileScaleCaptured = painter0.tileScale;
      final twCaptured = tileWidth * tileScaleCaptured;
      final thCaptured = tileHeight * tileScaleCaptured;

      const zoomLive = 10.3;
      controller.setFractionalZoom(zoomLive, animate: false);
      await tester.pump();
      final transform = gridTransform(tester).transform;
      final ratio =
          math.pow(2, zoomLive - 10).toDouble(); // 2^(live − captured at 10.0)

      // Independent expectation: the manager maps a zoom-10 tile
      // coordinate t to screen centerCanvas + (t − centerTile) · TW_live.
      // A non-focal fractional zoom keeps the geographic center fixed at
      // the moved-to lat/lng, so centerTile is its z10 projection.
      const center = LatLng(latitude: 0.0005, longitude: 0.01);
      final centerLngTile = lon2TileX(center.longitude, 10);
      final centerLatTile = lat2TileY(center.latitude, 10);
      final twLive = twCaptured * ratio;
      final thLive = thCaptured * ratio;
      final size = viewSize(tester);
      Offset expectedScreen(double tileX, double tileY) => Offset(
            size.width / 2 + (tileX - centerLngTile) * twLive,
            size.height / 2 + (tileY - centerLatTile) * thLive,
          );

      // Actual: box origin (−tw_c, −th_c) plus the transform applied to
      // the captured painter's box coordinates. Two probes: the first
      // window tile's top-left corner and its bottom-right corner.
      final m = transform.storage;
      Offset actualScreen(Offset boxPoint) => Offset(
            -twCaptured + m[0] * boxPoint.dx + m[12],
            -thCaptured + m[5] * boxPoint.dy + m[13],
          );

      final topLeft = actualScreen(Offset(anchorBoxX, anchorBoxY));
      final expectedTopLeft = expectedScreen(
          leftLng.toDouble(), topLat.toDouble());
      expect(topLeft.dx, closeTo(expectedTopLeft.dx, 0.01),
          reason: 'the transformed captured content must land exactly '
              'where the manager camera projects it (x)');
      expect(topLeft.dy, closeTo(expectedTopLeft.dy, 0.01),
          reason: 'the transformed captured content must land exactly '
              'where the manager camera projects it (y)');

      final bottomRight = actualScreen(Offset(
        anchorBoxX + twCaptured,
        anchorBoxY + thCaptured,
      ));
      final expectedBottomRight = expectedScreen(
          (leftLng + 1).toDouble(), (topLat + 1).toDouble());
      expect(bottomRight.dx, closeTo(expectedBottomRight.dx, 0.01),
          reason: 'the scale ratio must be exactly 2^(live − captured)');
      expect(bottomRight.dy, closeTo(expectedBottomRight.dy, 0.01));
    });

    testWidgets('integer source-zoom switch recaptures the grid',
        (tester) async {
      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester, completers: completers);

      final paints0 = RenderCanvasOSM.debugPaintCount;
      controller.setFractionalZoom(10.6, animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints0),
          reason: 'crossing the .5 boundary switches the source zoom and '
              'must recapture (content invalidation)');

      // Let any zoom-snapshot overlay retire, then confirm the new
      // capture paints at the live pose: source zoom 11 with cameraZoom
      // 10.6 → tileScale 2^−0.4 (the fractional pose is preserved by the
      // recapture; the legacy path would recapture identically here).
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<RenderCanvasOSM>()
          .last;
      expect(painter.tileScale,
          closeTo(math.pow(2, 10.6 - 11).toDouble(), 1e-9),
          reason: 'the recapture paints at the new source zoom and the '
              'live fractional pose');
    });

    testWidgets('zooming out past the captured window recaptures and keeps '
        'the viewport covered', (tester) async {
      // A phone-sized viewport never exhausts the captured pad inside a
      // ±0.5 band: the surface pad is one rendered tile per side, more
      // than the √2 worst-case extent growth unless the half-extent
      // exceeds ~2.4 tiles. At 4000 logical px (half-extent 7.8) the
      // gate fires during the sweep, and after every frame the live
      // viewport stays inside the captured surface.
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = const Size(12000, 9000);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester,
          completers: completers, settleBudget: const Duration(seconds: 30));

      var paints = RenderCanvasOSM.debugPaintCount;
      var recaptures = 0;
      var prevTileScale = _gridPainter(tester).tileScale;

      // A fractional zoom-out sweep: the live viewport's tile extent
      // grows; once it outgrows the captured painted window the capture
      // must be rebuilt (and stays rebuilt around the live camera), so
      // after every frame the live viewport stays inside the captured
      // coverage.
      for (final zoom in const [
        9.95, 9.9, 9.85, 9.8, 9.75, 9.7, 9.65, 9.6, 9.55,
      ]) {
        controller.setFractionalZoom(zoom, animate: false);
        await tester.pump();
        final painter = _gridPainter(tester);
        if (RenderCanvasOSM.debugPaintCount > paints ||
            painter.tileScale != prevTileScale) {
          recaptures++;
          paints = RenderCanvasOSM.debugPaintCount;
          prevTileScale = painter.tileScale;
        }
        // Coverage invariant, checked against the captured painter.
        final size = viewSize(tester);
        final twLive = tileWidth * math.pow(2, zoom - 10).toDouble();
        final thLive = tileHeight * math.pow(2, zoom - 10).toDouble();
        final centerLngTile = lon2TileX(0.0, 10);
        final centerLatTile = lat2TileY(0.0, 10);
        final halfW = size.width / (2 * twLive);
        final halfH = size.height / (2 * thLive);
        expect(
            centerLngTile - halfW,
            greaterThanOrEqualTo(painter.leftColumnTilesLngIndex - 1e-6),
            reason: 'zoom $zoom: the live viewport must stay inside the '
                'captured painted window (left)');
        expect(
            centerLngTile + halfW,
            lessThanOrEqualTo(painter.leftColumnTilesLngIndex +
                painter.horizontalTileCount +
                1e-6),
            reason: 'zoom $zoom: captured window covers the viewport (right)');
        expect(
            centerLatTile - halfH,
            greaterThanOrEqualTo(painter.topRowTilesLatIndex - 1e-6),
            reason: 'zoom $zoom: captured window covers the viewport (top)');
        expect(
            centerLatTile + halfH,
            lessThanOrEqualTo(painter.topRowTilesLatIndex +
                painter.verticalTileCount +
                1e-6),
            reason: 'zoom $zoom: captured window covers the viewport '
                '(bottom)');
      }
      expect(recaptures, greaterThanOrEqualTo(1),
          reason: 'a fractional zoom-out must recapture once the viewport '
              'outgrows the captured coverage');
    });

    testWidgets('an imagery arrival during a fractional zoom recaptures',
        (tester) async {
      final completers = <String, Completer<Uint8List>>{};
      final controller =
          await _pumpSettledMap(tester, completers: completers, hold: '10/512/511');

      final held = completers['10/512/511']!;
      final paints0 = RenderCanvasOSM.debugPaintCount;

      // Fractional zoom first: the layer stays retained (imagery stale
      // but unchanged).
      controller.setFractionalZoom(10.25, animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, paints0);

      // The arrival publishes → contentRevision → recapture.
      held.complete(_tinyPng);
      final watch = Stopwatch()..start();
      while (RenderCanvasOSM.debugPaintCount == paints0 &&
          watch.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints0),
          reason: 'an arrival must recapture promptly, also mid-gesture');
    });

    testWidgets('an accepted pan keeps the viewport covered to the raster '
        'edge (pixel output)', (tester) async {
      final blue = await tester.runAsync(
              () => _solidTilePng(const Color(0xFF3366AA))) ??
          (throw StateError('tile png failed'));
      final key = GlobalKey();
      final controller = MapController();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            home: Scaffold(
              body: MapView(
                controller: controller,
                latLng: const LatLng(latitude: 0, longitude: 0),
                zoom: 10,
                tileFetcher: (z, x, y) async => blue,
                showZoomControls: false,
                animateZoom: false,
              ),
            ),
          ),
        ),
      );
      await _waitForTilesPublished(tester);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Pan right by 0.85 tile (0.3° at z10 = 0.853): inside the
      // one-tile surface pad, so the capture is retained and only the
      // outer translation moves content.
      final paints0 = RenderCanvasOSM.debugPaintCount;
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.3), animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, paints0,
          reason: 'a pan inside the surface pad must keep the layer '
              'retained');

      // The composited output must be tile imagery at both viewport
      // edges — checking the padded window instead of the surface would
      // let the bare raster edge slide into view as a background strip.
      final (rgba, width, height) = await _rasterize(tester, key);
      const blueRgb = [0x33, 0x66, 0xAA];
      expect(_edgeCoverage(rgba, width, height, true, blueRgb),
          greaterThan(0.9),
          reason: 'the right viewport edge must show tile imagery');
      expect(_edgeCoverage(rgba, width, height, false, blueRgb),
          greaterThan(0.9),
          reason: 'the left viewport edge must show tile imagery');
    });

    testWidgets('panning past the surface pad recaptures and stays covered '
        '(pixel output)', (tester) async {
      final blue = await tester.runAsync(
              () => _solidTilePng(const Color(0xFF3366AA))) ??
          (throw StateError('tile png failed'));
      final key = GlobalKey();
      final controller = MapController();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            home: Scaffold(
              body: MapView(
                controller: controller,
                latLng: const LatLng(latitude: 0, longitude: 0),
                zoom: 10,
                tileFetcher: (z, x, y) async => blue,
                showZoomControls: false,
                animateZoom: false,
              ),
            ),
          ),
        ),
      );
      await _waitForTilesPublished(tester);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Pan right by 1.14 tile (0.4° at z10): past the raster pad — the
      // capture must rebuild around the live camera instead of sliding
      // bare raster edge into the viewport.
      final paints0 = RenderCanvasOSM.debugPaintCount;
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.4), animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints0),
          reason: 'a pan past the surface pad must recapture');

      final (rgba, width, height) = await _rasterize(tester, key);
      const blueRgb = [0x33, 0x66, 0xAA];
      expect(_edgeCoverage(rgba, width, height, true, blueRgb),
          greaterThan(0.9),
          reason: 'the rebuilt capture covers the right viewport edge');
      expect(_edgeCoverage(rgba, width, height, false, blueRgb),
          greaterThan(0.9),
          reason: 'the rebuilt capture covers the left viewport edge');
    });

    testWidgets('workload reload releases the capture pin and recaptures',
        (tester) async {
      final completers = <String, Completer<Uint8List>>{};
      final controller = await _pumpSettledMap(tester, completers: completers);
      final paints0 = RenderCanvasOSM.debugPaintCount;

      // The retained-scale capture pins its tile snapshot; the visible
      // -image reload must release and invalidate the capture instead of
      // tripping 'Release image pins before a workload reload'.
      controller.dropRebuildableCaches(includeVisibleImages: true);
      await tester.pump();

      // Wait for the invalidated capture to rebuild and for the reloaded
      // imagery to publish back into it.
      final watch = Stopwatch()..start();
      var loaded = 0;
      while (watch.elapsed < const Duration(seconds: 10)) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 16));
        final tiles = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((paint) => paint.painter)
            .whereType<RenderCanvasOSM>();
        if (tiles.isNotEmpty) {
          loaded = tiles.fold(
              0,
              (count, painter) =>
                  count +
                  painter.tiles.where((tile) => tile.sourceTile != null).length);
          if (RenderCanvasOSM.debugPaintCount > paints0 && loaded > 0) break;
        }
      }
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints0),
          reason: 'after the reset the invalidated capture must be rebuilt');
      expect(loaded, greaterThan(0),
          reason: 'the rebuilt capture must paint reloaded imagery, not '
              'placeholders');
    });
  });
}
