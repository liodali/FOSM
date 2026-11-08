import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/tile_source.dart' show TileDecodeAborted;
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/render/vector_trace.dart';

import 'mvt_builder.dart';
import 'pipeline_fixture.dart';

/// Plan-06 speculative-decode label behavior.
///
/// The manager's speculative decoder skips label preparation for tiles
/// that are still offscreen when the decode resolves; the promotion path
/// arranges preparation for cache-served tiles (recovered, if needed,
/// from the manager's byte cache or its disk fallback). These tests pin
/// the runtime side of both paths: a speculative decode that resolves
/// while its tile is strictly visible (the became-visible-mid-flight
/// case, which bypasses the cache-hit promotion callback), the
/// admitted-but-offscreen case that must NOT prepare labels, the
/// parsed-LRU-evicted promotion that must redrive labels through the
/// shared source-parse path, and the graceful no-payload promotion.
void main() {
  testWidgets('a speculative decode that resolves into a strictly '
      'visible slot schedules its labels', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-visible-labels',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => true;
    runtime.isTileVisible = (z, x, y) => true;
    addTearDown(runtime.dispose);

    await tester.runAsync(() async {
      final image =
          await runtime.speculativeDecoder(buildTestTile(), 10, 120, 60);
      expect(image, isNotNull);
      // A speculative result that resolves into a visible slot no longer
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
        reason: 'a visible speculative completion bypasses cache '
            'promotion, so its labels must be scheduled by the decode');
  });

  testWidgets('an admitted-but-offscreen speculative completion never '
      'prepares labels', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-offscreen-relevant',
      parseOffThread: false,
    );
    // Relevance alone cannot decide label timing: admitted speculative
    // tiles are deliberately relevant while offscreen ('isTileRelevant'),
    // so only the strict-visible predicate may schedule labels.
    runtime.isTileRelevant = (z, x, y) => true;
    runtime.isTileVisible = (z, x, y) => false;
    addTearDown(runtime.dispose);

    await tester.runAsync(() async {
      final image =
          await runtime.speculativeDecoder(buildTestTile(), 10, 120, 60);
      expect(image, isNotNull,
          reason: 'the image itself still returns for the manager to cache');
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 1)) {
        if (runtime.labelOverlayPreparedTileKeys.contains('10/120/60')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(
        runtime.labelOverlayPreparedTileKeys.contains('10/120/60'), isFalse,
        reason: 'offscreen label preparation is wasted work the '
            'visibility-gated decode must not start; labels are arranged '
            'when the pre-rendered image later promotes');
  });

  testWidgets('a speculative decode for an irrelevant tile aborts and '
      'prelabels nothing', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-offscreen-labels',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => false;
    runtime.isTileVisible = (z, x, y) => false;
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

  testWidgets('promotion redrives labels for two over-zoom siblings '
      'through one shared source parse', (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-promote-dedup',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => true;
    runtime.isTileVisible = (z, x, y) => true;
    addTearDown(runtime.dispose);

    final bytes = buildTestTile();
    VectorSpanLog.enabled = true;
    VectorSpanLog.clear();
    addTearDown(() async {
      VectorSpanLog.enabled = VectorSpanLog.enabledByDefine;
      VectorSpanLog.clear();
    });
    await tester.runAsync(() async {
      // Two over-zoom siblings (source maxzoom is 12, so z13 resolves to
      // one z12 source tile) promoted at the same time: the label
      // recovery must join the shared source parse instead of parsing
      // the payload twice.
      runtime.ensureLabelsPrepared(13, 120, 60, bytes: bytes);
      runtime.ensureLabelsPrepared(13, 121, 60, bytes: bytes);
      final stopwatch = Stopwatch()..start();
      while ((runtime.labelOverlayPreparedTileKeys.contains('13/120/60') ==
                  false ||
              runtime.labelOverlayPreparedTileKeys.contains('13/121/60') ==
                  false) &&
          stopwatch.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final sharedWaits = VectorSpanLog.take()
        .where((span) => span.event == 'parseSharedWait')
        .toList();
    expect(sharedWaits, hasLength(1),
        reason: 'the second promotion must join the first parse instead '
            'of starting its own');
    for (final required in ['13/120/60', '13/121/60']) {
      expect(runtime.labelOverlayPreparedTileKeys.contains(required), isTrue,
          reason: '$required must be label-prepared after recovery');
    }
  });

  testWidgets('promotion without any payload stays labelless gracefully',
      (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'spec-promote-empty',
      parseOffThread: false,
    );
    runtime.isTileRelevant = (z, x, y) => true;
    runtime.isTileVisible = (z, x, y) => true;
    addTearDown(runtime.dispose);

    await tester.runAsync(() async {
      runtime.ensureLabelsPrepared(10, 123, 63);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(runtime.labelOverlayPreparedTileKeys.contains('10/123/63'),
        isFalse,
        reason: 'no parsed data and no payload from the byte cache or '
            'disk fallback: labels return on the tile\'s next full decode');
  });
}
