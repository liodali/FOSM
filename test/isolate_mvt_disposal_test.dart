import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/isolate/mvt_isolate_native.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';

import 'vector/vector_pipeline_test.dart'
    show buildDenseLineTile, buildLoadedStyle;

void main() {
  // Plain VM test: exercises the real persistent MVT worker, so it must
  // not run on the web stub (mirrors isolate_http_reliability_test).
  test('disposing the worker settles pending decodes as cancelled', () async {
    final worker = MvtIsolate();
    await worker.spawn();
    addTearDown(worker.dispose);

    // Heavy enough that the worker cannot drain the queue before the
    // main isolate gets to dispose: 50 lines × 500 vertices each.
    final bytes = buildDenseLineTile(count: 50, pointsPerLine: 500);
    expect(worker.isReady, isTrue);

    // Flood the worker without yielding between sends, then dispose.
    final futures = <Future<DecodedVectorTile>>[
      for (var i = 0; i < 200; i++) worker.decode(bytes),
    ];
    worker.dispose();

    final outcomes = await Future.wait(
        futures.map((future) => future.then(
              (_) => 'decoded',
              onError: (Object error) =>
                  error is VectorTileCancelled ? 'cancelled' : 'error:$error',
            )),
        eagerError: false);

    // Without the disposal fix every future pending at the kill would
    // hang forever and this await would not return.
    expect(outcomes.contains('cancelled'), isTrue,
        reason: 'decodes queued at dispose must be cancelled, not hang');
    expect(
      outcomes
          .every((outcome) => outcome == 'decoded' || outcome == 'cancelled'),
      isTrue,
      reason: 'a killed worker must not surface unrelated decode errors',
    );
    expect(worker.isReady, isFalse);
  });

  test('decode after dispose is rejected, double dispose is safe', () async {
    final worker = MvtIsolate();
    await worker.spawn();
    worker.dispose();
    worker.dispose();
    expect(worker.isReady, isFalse);
    expect(
      () => worker.decode(buildDenseLineTile()),
      throwsStateError,
    );
  });

  test('runtime with native parsing unwinds decodes at dispose', () async {
    // parseOffThread spawns the persistent worker — the native parse
    // path production vector maps use.
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'native-dispose',
      parseOffThread: true,
    );
    final bytes = buildDenseLineTile(count: 30, pointsPerLine: 300);

    // Start several decodes without awaiting, then dispose the runtime
    // while parses are outstanding.
    final decodes = <Future<Object>>[
      for (final coord in [(12, 3, 2), (12, 4, 2), (12, 5, 2)])
        runtime.decoder(bytes, coord.$1, coord.$2, coord.$3),
    ];
    await runtime.spriteReady;
    runtime.dispose();

    final outcomes = await Future.wait(
        decodes.map((future) => future.then(
              (_) => 'image',
              onError: (Object error) => '$error',
            )),
        eagerError: false);

    // Every decode settles promptly — none may hang — and stale-work
    // aborts (TileDecodeAborted / StateError from the disposed runtime)
    // are the expected outcomes.
    expect(
      outcomes.every((outcome) =>
          outcome == 'image' ||
          outcome.contains('TileDecodeAborted') ||
          outcome.contains('StateError')),
      isTrue,
      reason: 'unexpected decode failure: $outcomes',
    );
  });
}
