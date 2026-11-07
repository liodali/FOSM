import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/tile_source.dart' show TileDecodeAborted;
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';

import 'mvt_builder.dart';
import 'pipeline_fixture.dart';

/// Plan-06 speculative-decode label behavior.
///
/// The manager's speculative decoder skips label preparation for tiles
/// that are still offscreen when the decode resolves; the promotion path
/// arranges preparation for cache-served tiles. These tests pin the
/// runtime side of both paths: a speculative decode that resolves while
/// its tile is relevant (the became-visible-mid-flight case, which
/// bypasses the cache-hit promotion callback), the parsed-LRU-evicted
/// promotion that must redrive labels from the manager's cached bytes,
/// and the graceful no-payload promotion.
void main() {
  testWidgets('a speculative decode that resolves while its tile is '
      'relevant schedules its labels', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-visible-labels',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => true;
    addTearDown(runtime.dispose);

    await tester.runAsync(() async {
      final image =
          await runtime.speculativeDecoder(buildTestTile(), 10, 120, 60);
      expect(image, isNotNull);
      // A speculative result that resolves into a relevant slot no longer
      // has a promotion callback coming for it: the labels must be
      // arranged here.
      final stopwatch = Stopwatch()..start();
      while (!runtime.labelOverlayPreparedTileKeys.contains('10/120/60') &&
          stopwatch.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(runtime.labelOverlayPreparedTileKeys.contains('10/120/60'), isTrue,
        reason: 'a relevant speculative completion bypasses cache '
            'promotion, so its labels must be scheduled by the decode');
  });

  testWidgets('a speculative decode for an irrelevant tile aborts and '
      'prelabels nothing', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-offscreen-labels',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => false;
    addTearDown(runtime.dispose);

    Object? observed;
    await tester.runAsync(() async {
      try {
        await runtime.speculativeDecoder(buildTestTile(), 10, 121, 61);
      } on TileDecodeAborted catch (error) {
        observed = error;
      }
    });
    await tester.pump();
    expect(observed, isA<TileDecodeAborted>(),
        reason: 'the relevance gates must abort the decode before any '
            'expensive work runs');
    expect(runtime.labelOverlayPreparedTileKeys.contains('10/121/61'),
        isFalse,
        reason: 'nothing completes for an irrelevant tile');
  });

  testWidgets('promotion arranges labels from cached bytes when the '
      'parsed LRU is evicted', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-promote-reparse',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => true;
    addTearDown(runtime.dispose);

    final bytes = buildTestTile();
    await tester.runAsync(() async {
      // Nothing was ever parsed for this tile: the promotion arrives with
      // the manager's cached bytes only.
      runtime.ensureLabelsPrepared(10, 122, 62, bytes: bytes);
      final stopwatch = Stopwatch()..start();
      while (!runtime.labelOverlayPreparedTileKeys.contains('10/122/62') &&
          stopwatch.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(runtime.labelOverlayPreparedTileKeys.contains('10/122/62'), isTrue,
        reason: 'label preparation must redrive from cached bytes instead '
            'of waiting for a full image decode');
  });

  testWidgets('promotion without any payload stays labelless gracefully',
      (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-promote-empty',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => true;
    addTearDown(runtime.dispose);

    await tester.runAsync(() async {
      runtime.ensureLabelsPrepared(10, 123, 63);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(runtime.labelOverlayPreparedTileKeys.contains('10/123/63'),
        isFalse,
        reason: 'no bytes and no parsed tile: labels return on the next '
            'full decode - this must not schedule label work');
  });
}
