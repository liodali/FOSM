import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/view/render.dart';

void main() {
  group('RenderCanvasOSM checkerboard placeholder', () {
    testWidgets('paints without throwing for an all-missing grid',
        (tester) async {
      // An all-missing 3×2 grid (no tile images) used to issue ~3×2×512
      // rect draws. The reusable picture path must paint without error.
      final painter = RenderCanvasOSM(
        horizontalTileCount: 3,
        verticalTileCount: 2,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        tiles: const [],
        revision: 1,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      painter.paint(canvas, const Size(256 * 3, 256 * 2));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
      picture.dispose();
    });

    testWidgets('draws loaded tile images and missing placeholders together',
        (tester) async {
      // Build a 1×1 image to stand in for a loaded tile.
      final image = await tester.runAsync(() => Tile.decodeImage(fakeTilePng));
      expect(image, isNotNull);
      final tiles = [
        Tile(image!, '0/0/0', 0, 0),
      ];

      final painter = RenderCanvasOSM(
        horizontalTileCount: 2,
        verticalTileCount: 1,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        tiles: tiles,
        revision: 2,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      painter.paint(canvas, const Size(256 * 2, 256));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
      picture.dispose();
      image.dispose();
    });

    test('shouldRepaint only on revision change', () {
      final a = RenderCanvasOSM(
        horizontalTileCount: 1,
        verticalTileCount: 1,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        tiles: const [],
        revision: 1,
      );
      final b = RenderCanvasOSM(
        horizontalTileCount: 1,
        verticalTileCount: 1,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        tiles: const [],
        revision: 1,
      );
      final c = RenderCanvasOSM(
        horizontalTileCount: 1,
        verticalTileCount: 1,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        tiles: const [],
        revision: 2,
      );
      expect(a.shouldRepaint(b), isFalse);
      expect(a.shouldRepaint(c), isTrue);
    });

    test('shouldRepaint when fitImagesToTile flips at equal fields', () {
      RenderCanvasOSM painter({required bool fit}) => RenderCanvasOSM(
            horizontalTileCount: 1,
            verticalTileCount: 1,
            leftColumnTilesLngIndex: 0,
            topRowTilesLatIndex: 0,
            leftColumnTilesCanvasX: 0,
            topRowTilesCanvasY: 0,
            tiles: const [],
            revision: 1,
            fitImagesToTile: fit,
          );
      // The flag changes image sizing, so it must be part of the repaint
      // contract: flipping it at otherwise-equal fields must repaint, and
      // keeping it equal must not (regression: the flag was omitted and a
      // payload flip could retain the wrong image sizing).
      expect(painter(fit: true).shouldRepaint(painter(fit: false)), isTrue);
      expect(painter(fit: false).shouldRepaint(painter(fit: true)), isTrue);
      expect(painter(fit: true).shouldRepaint(painter(fit: true)), isFalse);
      expect(painter(fit: false).shouldRepaint(painter(fit: false)), isFalse);
    });
  });

  group('RenderCanvasOSM tile-image resolution scoping', () {
    // A 512×512 capture whose left half is opaque black and right half
    // opaque white: the horizontal colour split localizes the drawing
    // path — natural-size drawing puts the split at 256 device px (the
    // white right half overflows the 256 px cell), fitted drawing puts it
    // at 128 px inside the cell.
    ui.Image buildHalfHalfCapture() {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 256, 512),
          ui.Paint()..color = const ui.Color(0xFF000000));
      canvas.drawRect(
          const ui.Rect.fromLTWH(256, 0, 256, 512),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      return recorder.endRecording().toImageSync(512, 512);
    }

    Future<ui.Image> rasterizePainting(
        WidgetTester tester, RenderCanvasOSM painter, Size size) async {
      // Picture rasterization and byte extraction complete via real engine
      // callbacks — run inside a real-async window.
      final captured = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        painter.paint(canvas, size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(size.width.toInt(), size.height.toInt());
        picture.dispose();
        return image;
      });
      return captured!;
    }

    /// Straight RGBA at (x, y) of [image], read inside a real-async window.
    Future<(int, int, int, int)> pixel(
        WidgetTester tester, ui.Image image, int x, int y) async {
      final bytes = await tester.runAsync(() => image
          .toByteData(format: ui.ImageByteFormat.rawStraightRgba));
      final pixels = bytes!.buffer.asUint8List();
      final i = (y * image.width + x) * 4;
      return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]);
    }

    testWidgets('raster imagery keeps the natural-size draw (overflow)',
        (tester) async {
      final capture = buildHalfHalfCapture();
      addTearDown(capture.dispose);
      final tiles = [Tile(capture, '0/0/0', 0, 0)];
      final painter = RenderCanvasOSM(
        horizontalTileCount: 1,
        verticalTileCount: 1,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        tiles: tiles,
        revision: 1,
        paintBackground: false,
        // fitImagesToTile defaults to false: raster payloads keep the
        // historical natural-size path regardless of source resolution.
      );

      // Rasterize 512 wide so the overflowing right half is observable.
      final rendered =
          await rasterizePainting(tester, painter, const Size(512, 256));
      addTearDown(rendered.dispose);
      expect(await pixel(tester, rendered, 192, 128), (0, 0, 0, 255),
          reason: "the capture's left half covers the cell 1:1");
      expect(await pixel(tester, rendered, 320, 128), (255, 255, 255, 255),
          reason: 'natural-size drawing lets the white right half overflow '
              'past the 256 px cell — the historical raster output');
    });

    testWidgets('vector captures above the tile resolution fit the cell',
        (tester) async {
      final capture = buildHalfHalfCapture();
      addTearDown(capture.dispose);
      final tiles = [Tile(capture, '0/0/0', 0, 0)];
      final painter = RenderCanvasOSM(
        horizontalTileCount: 1,
        verticalTileCount: 1,
        leftColumnTilesLngIndex: 0,
        topRowTilesLatIndex: 0,
        leftColumnTilesCanvasX: 0,
        topRowTilesCanvasY: 0,
        tiles: tiles,
        revision: 1,
        paintBackground: false,
        fitImagesToTile: true,
      );

      final rendered =
          await rasterizePainting(tester, painter, const Size(256, 256));
      addTearDown(rendered.dispose);
      expect(await pixel(tester, rendered, 64, 128), (0, 0, 0, 255),
          reason: 'the fitted left half covers 0..128');
      expect(await pixel(tester, rendered, 192, 128), (255, 255, 255, 255),
          reason: 'the fitted right half covers 128..256 — nothing leaks '
              'past the cell');
    });
  });
}

/// Minimal valid 1×1 RGBA PNG reused for the painter tests.
final fakeTilePng = Uint8List.fromList([
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
