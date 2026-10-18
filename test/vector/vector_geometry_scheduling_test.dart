import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

VectorTileRenderer renderer(List<num> dash) => VectorTileRenderer(
      LoadedVectorStyle(
        style: parseStyleJson(jsonEncode({
          'version': 8,
          'sources': <String, dynamic>{},
          'layers': [
            {
              'id': 'roads',
              'type': 'line',
              'source-layer': 'roads',
              'paint': {
                'line-color': '#0000ff',
                'line-width': 2,
                'line-opacity': 0.5,
                'line-dasharray': dash,
              },
            },
          ],
        })),
        sources: const {},
      ),
    );

DecodedVectorTile tile(List<Float32List> parts) => DecodedVectorTile([
      DecodedLayer(name: 'roads', extent: 4096, features: [
        DecodedFeature(
          id: 1,
          geomType: MvtGeomType.lineString,
          properties: const {},
          geometry: parts,
        ),
      ]),
    ]);

Future<Uint8List> pixels(ui.Picture picture) async {
  final image = await picture.toImage(256, 256);
  try {
    return (await image.toByteData())!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('off-tile bounds scans yield and can be cancelled before path building',
      () async {
    final decoded = tile([
      Float32List.fromList(List<double>.generate(20000, (_) => 8000)),
    ]);
    var checkpoints = 0;
    await expectLater(
      renderer([2, 1]).renderAsync(
        decoded: decoded,
        srcZ: 12,
        z: 12,
        x: 0,
        y: 0,
        yieldBudget: Duration.zero,
        yieldControl: () async {
          checkpoints++;
        },
        isRelevant: () => checkpoints < 3,
      ),
      throwsA(isA<VectorTileCancelled>()),
    );
    expect(checkpoints, 3);
  });

  test('dash extraction yields within a single two-point contour', () async {
    final decoded = tile([
      Float32List.fromList([0, 2048, 4096, 2048])
    ]);
    var checkpoints = 0;
    await expectLater(
      renderer([0.01, 0.01]).renderAsync(
        decoded: decoded,
        srcZ: 12,
        z: 12,
        x: 0,
        y: 0,
        yieldBudget: Duration.zero,
        yieldControl: () async {
          checkpoints++;
        },
        isRelevant: () => checkpoints < 4,
      ),
      throwsA(isA<VectorTileCancelled>()),
    );
    expect(checkpoints, 4);
  });

  for (final (z, tileX) in [(12, 0), (13, 0), (13, 1)]) {
    test(
        'dash phase, opacity and overzoom pixels match reference at $z/$tileX/0',
        () async {
      // Second contour starts at a different x: phase must restart there.
      final decoded = tile([
        Float32List.fromList([0, 512, 4096, 512]),
        Float32List.fromList([48, 1024, 4096, 1024]),
      ]);
      final subject = renderer([2, 1]);
      final sync = await pixels(subject.render(
        decoded: decoded,
        srcZ: 12,
        z: z,
        x: tileX,
        y: 0,
      ));
      var checkpoints = 0;
      final async = await pixels(await subject.renderAsync(
        decoded: decoded,
        srcZ: 12,
        z: z,
        x: tileX,
        y: 0,
        yieldBudget: Duration.zero,
        yieldControl: () async {
          checkpoints++;
        },
      ));
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..color = const ui.Color(0xFF0000FF).withValues(alpha: 0.5)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2;
      final scale = z == 12 ? 1.0 : 2.0;
      for (final (start, y) in [(0.0, 32.0), (3.0, 64.0)]) {
        for (var x = start * scale - tileX * 256;
            x < 256 * scale - tileX * 256;
            x += 6) {
          canvas.drawPath(
            ui.Path()
              ..moveTo(x, y * scale)
              ..lineTo(
                  (x + 4).clamp(-512, 256 * scale - tileX * 256), y * scale),
            paint,
          );
        }
      }
      final reference = await pixels(recorder.endRecording());
      expect(sync, reference);
      expect(async, reference);
      expect(checkpoints, greaterThan(3));
    });
  }
}
