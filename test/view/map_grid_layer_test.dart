import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile.dart';
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
/// waits until every unheld foreground tile published.
Future<MapController> _pumpSettledMap(
  WidgetTester tester, {
  required Map<String, Completer<Uint8List>> completers,
  String? hold,
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
      watch.elapsed < const Duration(seconds: 5)) {
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
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.01),
          animate: false);
      await tester.pump();

      expect(RenderCanvasOSM.debugPaintCount, paints0,
          reason: 'sub-tile motion must move the retained layer, not repaint '
              'the grid');
      final painter1 = _gridPainter(tester);
      expect(identical(painter1, painter0), isFalse,
          reason: 'a new painter is constructed, with identical fields');
      expect(painter1.leftColumnTilesCanvasX, painter0.leftColumnTilesCanvasX,
          reason: 'the painter keeps the captured anchors');
      expect(painter1.revision, painter0.revision);
      expect(painter1.tileScale, painter0.tileScale);

      // A larger pan crosses a tile boundary and must recapture.
      controller.moveTo(
          const LatLng(latitude: 0.0005, longitude: 0.4), animate: false);
      await tester.pump();
      expect(RenderCanvasOSM.debugPaintCount, greaterThan(paints0),
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
}
