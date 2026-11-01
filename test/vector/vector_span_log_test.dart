import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/render/vector_trace.dart';

import 'mvt_builder.dart';
import 'pipeline_fixture.dart';

void main() {
  tearDown(() {
    VectorSpanLog.clear();
    VectorSpanLog.enabled = false;
  });

  group('VectorSpanLog', () {
    test('disabled by default records nothing', () {
      VectorSpanLog.enabled = false;
      final result = VectorTrace.sync('style', () => 42, tile: '10/1/1');
      expect(result, 42);
      expect(VectorSpanLog.length, 0);
    });

    test('sync spans record duration, tile, attempt and source', () {
      VectorSpanLog.enabled = true;
      VectorTrace.sync('style', () {},
          tile: '10/1/1', attempt: 'r1.0', source: '10/1/1');
      final spans = VectorSpanLog.take();
      expect(spans, hasLength(1));
      expect(spans.single.event, 'style');
      expect(spans.single.tile, '10/1/1');
      expect(spans.single.attempt, 'r1.0');
      expect(spans.single.source, '10/1/1');
      expect(spans.single.durationUs, greaterThanOrEqualTo(0));
      expect(spans.single.startUs, lessThanOrEqualTo(VectorSpanLog.nowUs()));
    });

    test('async spans record elapsed time', () async {
      VectorSpanLog.enabled = true;
      await VectorTrace.async('parseWait', () async {}, tile: '10/1/2');
      final spans = VectorSpanLog.take();
      expect(spans, hasLength(1));
      expect(spans.single.event, 'parseWait');
      expect(spans.single.tile, '10/1/2');
    });

    test('async spans still record when timeline tracing is off', () async {
      // fosm.traceVector is a compile-time const and false in tests; the
      // spans-only arm must record regardless.
      VectorSpanLog.enabled = true;
      await VectorTrace.async('fetch', () async {}, tile: '10/1/3');
      expect(VectorSpanLog.take().single.event, 'fetch');
    });

    test('markers record zero-duration events with identity', () {
      VectorSpanLog.enabled = true;
      VectorSpanLog.mark('staleAbort', tile: '10/1/4', attempt: 'r2.7');
      final spans = VectorSpanLog.take();
      expect(spans, hasLength(1));
      expect(spans.single.event, 'staleAbort');
      expect(spans.single.durationUs, 0);
      expect(spans.single.attempt, 'r2.7');
    });

    test('clear resets spans and the drop counter', () {
      VectorSpanLog.enabled = true;
      VectorTrace.sync('style', () {});
      VectorSpanLog.clear();
      expect(VectorSpanLog.length, 0);
      expect(VectorSpanLog.dropped, 0);
    });
  });

  group('vector pipeline spans are tile-correlated', () {
    testWidgets('decode emits per-tile stage spans', (tester) async {
      VectorSpanLog.enabled = true;
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'span-attribution',
        parseOffThread: false,
      );
      addTearDown(runtime.dispose);

      final image = await tester
          .runAsync(() => runtime.decoder(buildTestTile(), 12, 6, 4));
      expect(image, isNotNull);
      image!.dispose();

      final spans = VectorSpanLog.take();
      final events = spans.map((span) => span.event).toSet();
      final tile = '12/6/4';

      // Critical-path stages must all be present and correlated by tile.
      expect(
          events,
          containsAll(
              ['queueWait', 'parseWait', 'record', 'imageWait', 'toImage']));
      for (final stage in [
        'queueWait',
        'parseWait',
        'record',
        'imageWait',
        'toImage'
      ]) {
        expect(
          spans.where((span) => span.event == stage).single.tile,
          tile,
          reason: '$stage span must carry the logical tile',
        );
      }
      // Synchronous recording slices carry the tile too.
      expect(
        spans.any((span) =>
            span.event.startsWith('recordChunk.') && span.tile == tile),
        isTrue,
        reason: 'recordChunk spans must carry the logical tile',
      );
      // Geometry chunks are nested inside recording and tile-tagged.
      expect(
        spans.where((span) => span.event == 'geometry').single.tile,
        tile,
      );
    });

    testWidgets('one rendering attempt shares its id across all stages',
        (tester) async {
      VectorSpanLog.enabled = true;
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'span-attempt',
        parseOffThread: false,
      );
      addTearDown(runtime.dispose);

      final image = await tester
          .runAsync(() => runtime.decoder(buildTestTile(), 12, 6, 4));
      image?.dispose();

      final spans = VectorSpanLog.take();
      final attempts =
          spans.map((span) => span.attempt).whereType<String>().toSet();
      expect(attempts, hasLength(1),
          reason: 'every stage of one decode shares one attempt id');
      final attempt = attempts.single;
      expect(RegExp(r'^r\d+\.\d+$').hasMatch(attempt), isTrue,
          reason: 'attempt ids are <runtimeId>.<sequence>: $attempt');

      // The resolved source tile (z12 == source maxzoom → itself) rides
      // along the parse-path stages.
      for (final stage in ['parseWait', 'record']) {
        final span = spans.singleWhere((span) => span.event == stage);
        expect(span.attempt, attempt);
        expect(span.source, '12/6/4',
            reason: '$stage must name the resolved source tile');
      }
      // Nested recording slices carry the same attempt.
      expect(
        spans
            .where((span) => span.event.startsWith('recordChunk.'))
            .every((span) => span.attempt == attempt),
        isTrue,
      );
    });

    testWidgets('a retry of the same tile gets a fresh attempt id',
        (tester) async {
      VectorSpanLog.enabled = true;
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'span-retry',
        parseOffThread: false,
      );
      addTearDown(runtime.dispose);

      final first = await tester
          .runAsync(() => runtime.decoder(buildTestTile(), 12, 6, 4));
      first?.dispose();
      // Evict the parsed tile so the second decode re-parses: two full
      // attempts for one tile coordinate.
      runtime.handleMemoryPressure();
      final second = await tester
          .runAsync(() => runtime.decoder(buildTestTile(), 12, 6, 4));
      second?.dispose();

      final attempts = VectorSpanLog.take()
          .where((span) => span.event == 'parseWait')
          .map((span) => span.attempt)
          .toSet();
      expect(attempts, hasLength(2),
          reason: 'tile coordinates repeat across retries; attempts do not');
    });

    testWidgets(
        'over-zoom siblings join a shared parse; the worker piggyback '
        'reports queue hold and CPU', (tester) async {
      VectorSpanLog.enabled = true;
      final previousOverride =
          VectorTileRuntime.debugMaxConcurrentDecodesOverride;
      VectorTileRuntime.debugMaxConcurrentDecodesOverride = 4;
      addTearDown(() {
        VectorTileRuntime.debugMaxConcurrentDecodesOverride = previousOverride;
      });

      // The whole worker-path decode must live inside one real-async
      // envelope: testWidgets' fake zone cannot groom microtasks while
      // `runAsync` is parked, and a real isolate reply delivers outside
      // it — an await chain that crosses the reply would stall forever.
      await tester.runAsync(() async {
        final runtime = VectorTileRuntime(
          loaded: buildLoadedStyle(),
          namespace: 'span-shared-parse',
          parseOffThread: true,
        );
        addTearDown(runtime.dispose);
        // Real-async time for the constructor-started spawn handshake.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Two z13 tiles both resolve to source 12/3/2 (fixture maxZoom
        // is 12): the second decode joins the first's in-flight parse.
        // The trigger is parked in its worker reply await when the
        // sibling starts, so the join is deterministic.
        final trigger = runtime.decoder(buildTestTile(), 13, 6, 4);
        unawaited(trigger);
        final joiner = runtime.decoder(buildTestTile(), 13, 7, 4);
        final first = await trigger.timeout(const Duration(seconds: 20));
        final second = await joiner.timeout(const Duration(seconds: 20));
        first.dispose();
        second.dispose();
      });

      final spans = VectorSpanLog.take();
      // Attempt ids come out in assignment order: the trigger is rX.0.
      final triggerAttempt =
          spans.firstWhere((span) => span.event == 'queueWait').attempt!;
      final joins = spans.where((span) => span.event == 'parseSharedWait');
      expect(joins, hasLength(1),
          reason: 'the sibling joining an in-flight parse is a joiner');
      expect(joins.single.attempt, isNot(triggerAttempt),
          reason: 'the joiner carries its own attempt id');
      expect(joins.single.source, '12/3/2',
          reason: 'the join names the shared source tile, not its logical one');
      expect(spans.where((span) => span.event == 'parseWait'), hasLength(2),
          reason: 'the outer parseWait still wraps trigger and joiner');

      // Worker-side stats exist on the persistent-worker path (parse
      // CPU and the port-queue hold, both keyed to the *triggering*
      // attempt — the sibling's join never touches them).
      final queueWaits =
          spans.where((span) => span.event == 'parseQueueWait').toList();
      expect(queueWaits, hasLength(1),
          reason: "the trigger's dispatch is measured entry-to-send");
      expect(queueWaits.single.attempt, triggerAttempt);
      expect(queueWaits.single.source, '12/3/2');
      final cpu = spans
          .where((span) => span.event == 'parse' && span.attempt != null);
      expect(cpu, isNotEmpty,
          reason: 'worker parse CPU is piggybacked per triggering attempt');
      expect(cpu.single.attempt, triggerAttempt);
      expect(cpu.single.source, '12/3/2');
      for (final hold in spans.where((span) => span.event == 'parseHold')) {
        expect(hold.attempt, triggerAttempt);
        expect(hold.source, '12/3/2');
      }
    });

    testWidgets('publish marks the end of the critical path', (tester) async {
      VectorSpanLog.enabled = true;
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'span-publish',
        parseOffThread: false,
      );
      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) async => buildTestTile(),
        decoder: runtime.decoder,
        resourceKeyBuilder: (z, x, y) =>
            runtime.vectorSource.resolve(z, x, y).toString(),
        cacheNamespace: runtime.namespace,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );
      addTearDown(manager.dispose);
      addTearDown(runtime.dispose);

      await tester.runAsync(() async {
        manager.calculate();
        final timeout = Stopwatch()..start();
        while (!manager.visibleTilesReady &&
            timeout.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(manager.visibleTilesReady, isTrue);

      final publishes =
          VectorSpanLog.take().where((span) => span.event == 'publish');
      expect(publishes, isNotEmpty,
          reason: 'the tile manager must mark grid publication');
      expect(publishes.every((span) => span.durationUs == 0), isTrue);
      expect(
        publishes.any((span) => span.tile == '12/2048/2048'),
        isTrue,
        reason: 'publish marks carry the logical tile (z12 at 0,0)',
      );
      expect(
        publishes.every((span) => span.attempt != null),
        isTrue,
        reason: 'vector publishes must carry the decode attempt whose '
            'image is being placed',
      );
      // The claimed attempt is the one the decode spans recorded.
      final attempt = publishes.first.attempt!;
      expect(
        VectorSpanLog.take()
            .any((span) => span.event == 'toImage' && span.attempt == attempt),
        isTrue,
        reason: 'the publish attempt must match a real decode attempt',
      );
    });

    testWidgets(
        'visible image reload records again without parsing or fetching',
        (tester) async {
      VectorSpanLog.enabled = true;
      final runtime = VectorTileRuntime(
          loaded: buildLoadedStyle(),
          namespace: 'warm-parsed-reload',
          parseOffThread: false);
      var downloads = 0;
      final manager = TileManager.init(
          width: 256,
          height: 256,
          centerLatLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 12,
          fetcher: (z, x, y) async {
            downloads++;
            return buildTestTile();
          },
          decoder: runtime.decoder,
          resourceKeyBuilder: (z, x, y) => 'shared',
          cacheNamespace: runtime.namespace,
          tilePadding: 0,
          preloadAdjacentZoom: false);
      addTearDown(manager.dispose);
      addTearDown(runtime.dispose);
      Future<void> settle() async {
        final timeout = Stopwatch()..start();
        while ((!manager.visibleTilesReady ||
                manager.pendingPresentationCount > 0) &&
            timeout.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      await tester.runAsync(() async {
        manager.calculate();
        await settle();
      });
      expect(manager.visibleTilesReady, isTrue);
      final fetches = VectorSpanLog.take().where((s) => s.event == 'fetch');
      expect(downloads, 1);
      expect(fetches, hasLength(1), reason: 'trace the shared download once');
      expect(fetches.single.source, 'warm-parsed-reload|shared');
      final parsedBefore = runtime.parsedTileCount;
      final release = manager.retainSnapshot(manager.renderTiles);
      expect(manager.reloadRenderedImagesForWorkload, throwsStateError);
      expect(manager.visibleTilesReady, isTrue,
          reason: 'a rejected pinned reload must leave the live grid intact');
      release();
      VectorSpanLog.clear();
      await tester.runAsync(() async {
        manager.reloadRenderedImagesForWorkload();
        expect(manager.visibleTilesReady, isFalse);
        await settle();
      });
      expect(manager.visibleTilesReady, isTrue);
      expect(runtime.parsedTileCount, parsedBefore);
      expect(downloads, 1);
      final spans = VectorSpanLog.take();
      expect(spans.where((s) => s.event == 'record'), isNotEmpty);
      expect(spans.where((s) => s.event == 'toImage'), isNotEmpty);
      expect(spans.where((s) => s.event == 'parseWait' || s.event == 'fetch'),
          isEmpty);
    });

    testWidgets('labels spans carry the tile', (tester) async {
      VectorSpanLog.enabled = true;
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'span-labels',
        parseOffThread: false,
      );
      addTearDown(runtime.dispose);

      await tester.runAsync(() => runtime.decoder(buildTestTile(), 12, 6, 4));
      // Label preparation runs on a deferred single-lane queue after the
      // base image publishes; poll with real delays for it to land.
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (runtime.labelOverlayPreparedTiles == 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(runtime.labelOverlayPreparedTiles, greaterThan(0),
          reason: 'labels must prepare after the base image publishes');

      final spans = VectorSpanLog.take();
      final labelSpans =
          spans.where((span) => span.event.startsWith('labels.')).toList();
      expect(
        labelSpans.any((span) => span.tile == '12/6/4'),
        isTrue,
        reason: 'label spans must carry the logical tile',
      );
      expect(
        labelSpans.every((span) => span.attempt != null),
        isTrue,
        reason: 'label spans must correlate with the publishing attempt',
      );
    });
  });
}
