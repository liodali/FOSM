import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';
import 'package:fosm/src/vector/render/vector_dash_diagnostics.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

VectorTileRenderer renderer(List<num> dash,
        {String cap = 'butt', String join = 'miter'}) =>
    VectorTileRenderer(
      LoadedVectorStyle(
        style: parseStyleJson(jsonEncode({
          'version': 8,
          'sources': <String, dynamic>{},
          'layers': [
            {
              'id': 'roads',
              'type': 'line',
              'source-layer': 'roads',
              'layout': {'line-cap': cap, 'line-join': join},
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
    VectorDashDiagnostics.clear();
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
    if (VectorDashDiagnostics.enabled) {
      final rows = VectorDashDiagnostics.snapshot()['rows'] as List;
      expect(rows, hasLength(1));
      final row = rows.single as Map<String, Object?>;
      expect(row['contours'], 1);
      expect(row['patternSteps'], 128);
      expect(row['extractions'], 64);
    }
  });

  test('offscreen dash skipping remains cancellable', () async {
    VectorDashDiagnostics.clear();
    var checkpoints = 0;
    await expectLater(
      renderer([0.01, 0.01]).renderAsync(
        decoded: tile([
          Float32List.fromList([-50000, 2048, 4096, 2048])
        ]),
        srcZ: 12,
        z: 12,
        x: 0,
        y: 0,
        yieldBudget: Duration.zero,
        yieldControl: () async => checkpoints++,
        isRelevant: () => checkpoints < 4,
      ),
      throwsA(isA<VectorTileCancelled>()),
    );
    if (VectorDashDiagnostics.enabled &&
        const bool.fromEnvironment('fosm.vectorDashCull')) {
      final rows = VectorDashDiagnostics.snapshot()['rows'] as List;
      expect((rows.single as Map<String, Object?>)['culledExtractions'],
          greaterThan(0));
    }
  });

  test('dash diagnostics count contours, steps and extraction for each layer',
      () {
    VectorDashDiagnostics.clear();
    final picture = renderer([2, 1]).render(
      decoded: tile([
        Float32List.fromList([0, 512, 160, 512]),
        Float32List.fromList([0, 1024, 160, 1024]),
      ]),
      srcZ: 12,
      z: 12,
      x: 0,
      y: 0,
    );
    picture.dispose();
    final report = VectorDashDiagnostics.snapshot();
    final rows = report['rows'] as List;
    expect(report['droppedUpdates'], 0);
    expect(rows, hasLength(1));
    final row = rows.single as Map<String, Object?>;
    expect(row['layer'], 'roads');
    expect(row['tile'], '12/0/0');
    expect(row['contours'], 2);
    expect(row['patternSteps'], 6);
    expect(row['extractions'], 4);
    expect(row['offscreenExtractions'], 0);
    expect(row['unknownBounds'], 0);
    VectorDashDiagnostics.clear();
    expect(VectorDashDiagnostics.snapshot()['rows'], isEmpty);
  }, skip: !VectorDashDiagnostics.enabled);

  test('dash diagnostics count offscreen dashes with stroke margin', () {
    VectorDashDiagnostics.clear();
    final picture = renderer([2, 1]).render(
      decoded: tile([
        Float32List.fromList([-3200, 2048, 4800, 2048]),
      ]),
      srcZ: 12,
      z: 12,
      x: 0,
      y: 0,
    );
    picture.dispose();
    final rows = VectorDashDiagnostics.snapshot()['rows'] as List;
    final row = rows.single as Map<String, Object?>;
    if (const bool.fromEnvironment('fosm.vectorDashCull')) {
      expect(row['culledExtractions'], greaterThan(0));
      expect(row['culledUnproven'], 0);
    } else {
      expect(row['offscreenExtractions'], greaterThan(0));
      expect(row['offscreenExtractions'], lessThan(row['extractions'] as int));
    }
    expect(row['unknownBounds'], 0);
  }, skip: !VectorDashDiagnostics.enabled);

  test('combining overlapping translucent dashes changes their pixels',
      () async {
    ui.Picture draw({required bool combined}) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..color = const ui.Color(0x800000ff)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = ui.StrokeCap.round;
      final horizontal = ui.Path()
        ..moveTo(30, 50)
        ..lineTo(70, 50);
      final vertical = ui.Path()
        ..moveTo(50, 30)
        ..lineTo(50, 70);
      if (combined) {
        canvas.drawPath(horizontal..addPath(vertical, ui.Offset.zero), paint);
      } else {
        canvas.drawPath(horizontal, paint);
        canvas.drawPath(vertical, paint);
      }
      return recorder.endRecording();
    }

    final separate = await pixels(draw(combined: false));
    final combined = await pixels(draw(combined: true));
    expect(separate, isNot(equals(combined)));
  });

  for (final pattern in <List<num>>[
    [0, 0],
    [0.3, 1.7, 2],
    [0, 1],
    [120, 1],
  ]) {
    test('unusual dash pattern $pattern matches independent reference',
        () async {
      final part = Float32List.fromList([-2048, 2048, 6144, 2048]);
      final actual = await pixels(renderer(pattern).render(
        decoded: tile([part]),
        srcZ: 12,
        z: 12,
        x: 0,
        y: 0,
      ));
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..color = const ui.Color(0xff0000ff).withValues(alpha: 0.5)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2;
      final path = ui.Path()
        ..moveTo(-128, 128)
        ..lineTo(384, 128);
      if (pattern.every((v) => v <= 0)) {
        canvas.drawPath(path, paint);
      } else {
        for (final metric in path.computeMetrics()) {
          var distance = 0.0;
          var step = 0;
          while (distance < metric.length) {
            final length = pattern[step % pattern.length] * 2;
            final next = (distance + length).clamp(0.0, metric.length);
            if (step.isEven && length > 0) {
              canvas.drawPath(metric.extractPath(distance, next), paint);
            }
            distance = next;
            step++;
            if (length <= 0 && step > pattern.length * 2) break;
          }
        }
      }
      expect(actual, await pixels(recorder.endRecording()));
    });
  }

  for (final (z, tileX, cap, join) in [
    (12, 0, 'butt', 'miter'),
    (13, 0, 'round', 'round'),
    (13, 1, 'square', 'bevel'),
  ]) {
    test(
        'dashed bends and edge bleed match uncropped reference: $z/$tileX $cap',
        () async {
      final parts = [
        Float32List.fromList([-2000, 96, 800, 96, 1600, 1900, 5000, 1900]),
        Float32List.fromList([-1000, 2100, 2500, 2100, 5200, 4000]),
        Float32List.fromList([0, -16, 4096, -16]),
      ];
      final actual = await pixels(renderer([2, 1], cap: cap, join: join).render(
        decoded: tile(parts),
        srcZ: 12,
        z: z,
        x: tileX,
        y: 0,
      ));

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..color = const ui.Color(0xff0000ff).withValues(alpha: 0.5)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = switch (cap) {
          'round' => ui.StrokeCap.round,
          'square' => ui.StrokeCap.square,
          _ => ui.StrokeCap.butt,
        }
        ..strokeJoin = switch (join) {
          'round' => ui.StrokeJoin.round,
          'bevel' => ui.StrokeJoin.bevel,
          _ => ui.StrokeJoin.miter,
        };
      final transform =
          TileTransform.forLayer(z: z, x: tileX, y: 0, srcZ: 12, extent: 4096);
      for (final part in parts) {
        final path = ui.Path()
          ..moveTo(transform.x(part[0]), transform.y(part[1]));
        for (var i = 2; i + 1 < part.length; i += 2) {
          path.lineTo(transform.x(part[i]), transform.y(part[i + 1]));
        }
        for (final metric in path.computeMetrics()) {
          var distance = 0.0;
          var step = 0;
          while (distance < metric.length) {
            final next =
                (distance + (step.isEven ? 4 : 2)).clamp(0.0, metric.length);
            if (step.isEven) {
              canvas.drawPath(metric.extractPath(distance, next), paint);
            }
            distance = next;
            step++;
          }
        }
      }
      expect(actual, await pixels(recorder.endRecording()));
    });
  }

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
