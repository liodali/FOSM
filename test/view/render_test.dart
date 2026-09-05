import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Size;
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
