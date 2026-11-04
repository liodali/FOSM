import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart' show VectorSpan;

import 'package:example/benchmark/vector_stage_report.dart';

void main() {
  group('buildVectorStageReport', () {
    test('aggregates per-event distributions with sync/async kinds', () {
      final report = buildVectorStageReport(const [
        VectorSpan('style', '10/1/1', 0, 100),
        VectorSpan('style', '10/1/2', 1000, 300),
        VectorSpan('parseWait', '10/1/1', 0, 5000),
      ]);

      final events = report['events'] as Map<String, dynamic>;
      final style = events['style'] as Map<String, dynamic>;
      expect(style['kind'], 'sync');
      expect(style['n'], 2);
      expect(style['totalUs'], 400);
      expect(style['maxUs'], 300);
      expect(style['p50Us'], 100);

      final parseWait = events['parseWait'] as Map<String, dynamic>;
      expect(parseWait['kind'], 'async');
      expect(parseWait['n'], 1);
    });

    test('groups recordChunk slices by full layer event name', () {
      final report = buildVectorStageReport(const [
        VectorSpan('recordChunk.road-major', '10/1/1', 0, 700),
        VectorSpan('recordChunk.road-major', '10/1/1', 800, 900),
        VectorSpan('recordChunk.water', '10/1/1', 0, 50),
      ]);
      final events = report['events'] as Map<String, dynamic>;
      expect(events['recordChunk.road-major']!['n'], 2);
      expect(events['recordChunk.road-major']!['totalUs'], 1600);
      expect(events['recordChunk.water']!['totalUs'], 50);
    });

    test('counts snapshot and lane discards as markers and per tile', () {
      final report = buildVectorStageReport(const [
        VectorSpan('staleAbort', '10/1/1', 0, 0, attempt: 'r1.0'),
        VectorSpan('snapshotDiscard', '10/1/1', 10, 0, attempt: 'r1.0'),
        VectorSpan('snapshotDiscard', '10/1/2', 20, 0, attempt: 'r2.0'),
        VectorSpan('laneDiscard', '10/1/3', 30, 0, attempt: 'r2.0'),
      ]);
      final markers = report['markers'] as Map<String, dynamic>;
      expect(markers['staleAbort'], 1);
      expect(markers['snapshotDiscard'], 2);
      expect(markers['laneDiscard'], 1);
      final tiles = report['tiles'] as Map<String, dynamic>;
      // Attempt-carrying spans accumulate on their attempt row.
      Map<String, dynamic> attemptOf(String tile, String attempt) =>
          ((tiles[tile] as Map<String, dynamic>)['attempts']
              as Map<String, dynamic>)[attempt] as Map<String, dynamic>;
      expect(attemptOf('10/1/1', 'r1.0')['staleAborts'], 1);
      expect(attemptOf('10/1/1', 'r1.0')['snapshotDiscards'], 1);
      expect(attemptOf('10/1/2', 'r2.0')['snapshotDiscards'], 1);
      expect(attemptOf('10/1/3', 'r2.0')['laneDiscards'], 1);
    });

    test('keeps stage sums and timestamps per rendering attempt', () {
      final report = buildVectorStageReport(const [
        // First attempt of 10/5/5.
        VectorSpan('fetch', '10/5/5', 0, 1000, source: '10/5/5'),
        VectorSpan('queueWait', '10/5/5', 1000, 200, attempt: 'r1.0'),
        VectorSpan('parseWait', '10/5/5', 1000, 2000,
            attempt: 'r1.0', source: '10/5/5'),
        VectorSpan('record', '10/5/5', 3000, 1500, attempt: 'r1.0'),
        VectorSpan('recordChunk.water', '10/5/5', 3000, 400, attempt: 'r1.0'),
        VectorSpan('geometry', '10/5/5', 3000, 350, attempt: 'r1.0'),
        VectorSpan('imageWait', '10/5/5', 5000, 800, attempt: 'r1.0'),
        VectorSpan('toImage', '10/5/5', 5100, 700, attempt: 'r1.0'),
        VectorSpan('labels.build', '10/5/5', 6000, 300, attempt: 'r1.0'),
        VectorSpan('publish', '10/5/5', 7100, 0, attempt: 'r1.0'),
        // A retry of the same coordinate: a second, separate attempt.
        VectorSpan('queueWait', '10/5/5', 9000, 150, attempt: 'r2.4'),
        VectorSpan('parseWait', '10/5/5', 9200, 300,
            attempt: 'r2.4', source: '10/5/5'),
        VectorSpan('record', '10/5/5', 9600, 900, attempt: 'r2.4'),
        VectorSpan('staleAbort', '10/5/5', 10600, 0, attempt: 'r2.4'),
        // Another tile's fetch (attempt-less, per manager job).
        VectorSpan('fetch', '10/6/6', 0, 900),
      ]);

      final tiles = report['tiles'] as Map<String, dynamic>;
      final tile = tiles['10/5/5'] as Map<String, dynamic>;

      // Attempt-less fetches aggregate per tile with their source tiles.
      final fetch = tile['fetch'] as Map<String, dynamic>;
      expect(fetch['n'], 1);
      expect(fetch['totalUs'], 1000);
      expect(fetch['sources'], ['10/5/5']);

      final attempts = tile['attempts'] as Map<String, dynamic>;
      expect(attempts.keys, unorderedEquals(<String>['r1.0', 'r2.4']),
          reason: 'retries of one coordinate must stay separate attempts');

      final first = attempts['r1.0'] as Map<String, dynamic>;
      expect(first['queueWaitUs'], 200);
      expect(first['parseWaitUs'], 2000);
      expect(first['parseN'], 1);
      expect(first['recordUs'], 1500);
      expect(first['recordChunkUs'], 400);
      expect(first['geometryUs'], 350);
      expect(first['imageWaitUs'], 800);
      expect(first['toImageUs'], 700);
      expect(first['labelsBuildUs'], 300);
      expect(first['published'], 1,
          reason: 'the publish marker attaches to its attempt');
      // Timestamps survive: the attempt's wall-clock window is the
      // min-start/max-end over its spans.
      expect(first['startUs'], 1000);
      expect(first['endUs'], 7100);
      // Per-stage windows and sources survive: queue gaps and shared
      // parses can be reconstructed from the stages map.
      expect(first['sourceTiles'], ['10/5/5']);
      final stages = first['stages'] as Map<String, dynamic>;
      final parseWait = stages['parseWait'] as Map<String, dynamic>;
      expect(parseWait['startUs'], 1000);
      expect(parseWait['endUs'], 3000);
      expect(parseWait['totalUs'], 2000);
      expect(parseWait['n'], 1);
      expect(parseWait['sources'], ['10/5/5'],
          reason: 'the resolved source tile rides the parse stage');
      // The queue gap: queueWait ends at 1200, parseWait starts at 1000
      // (both recorded) — reconstructable.
      final queueWait = stages['queueWait'] as Map<String, dynamic>;
      expect(queueWait['startUs'], 1000);
      expect(queueWait['endUs'], 1200);
      final toImage = stages['toImage'] as Map<String, dynamic>;
      expect(toImage['startUs'], 5100);
      expect(toImage['endUs'], 5800);
      // recordChunk slices group under one stage.
      final recordChunk = stages['recordChunk'] as Map<String, dynamic>;
      expect(recordChunk['n'], 1);
      expect(recordChunk['totalUs'], 400);
      // The publish marker keeps its timestamp inside the attempt.
      final publish = stages['publish'] as Map<String, dynamic>;
      expect(publish['startUs'], 7100);
      expect(publish['endUs'], 7100);

      final retry = attempts['r2.4'] as Map<String, dynamic>;
      expect(retry['recordUs'], 900,
          reason: 'the retry has its own stage sums');
      expect(retry['staleAborts'], 1);
      expect(retry.containsKey('published'), isFalse);
      expect(retry['startUs'], 9000);
      expect(retry['endUs'], 10600);
      // Shared parses are reconstructable: both attempts of 10/5/5 name
      // the same resolved source tile.
      expect(retry['sourceTiles'], ['10/5/5']);
      final retryParse = (retry['stages'] as Map<String, dynamic>)['parseWait']
          as Map<String, dynamic>;
      expect(retryParse['sources'], ['10/5/5']);

      final markers = report['markers'] as Map<String, dynamic>;
      expect(markers['publish'], 1);
      expect(markers['staleAbort'], 1);
    });

    test('viewport-level spans stay outside the per-tile table', () {
      final report = buildVectorStageReport(const [
        VectorSpan('labels.paint', null, 0, 120),
      ]);
      expect(report['tiles'], isEmpty);
      expect((report['events'] as Map)['labels.paint']!['n'], 1);
    });

    test('caps per-tile rows and reports the truncation', () {
      final spans = <VectorSpan>[
        for (var i = 0; i < 6; i++)
          VectorSpan('fetch', '10/$i/0', 0, 10 + i),
      ];
      final report = buildVectorStageReport(spans, maxTiles: 4);
      final tiles = report['tiles'] as Map<String, dynamic>;
      expect(tiles.length, 4);
      expect(report['tilesTruncated'], 2);
      // Event distributions still cover every span, capped tiles included.
      expect((report['events'] as Map)['fetch']!['n'], 6);
    });

    test('reports span count and dropped spans', () {
      final report = buildVectorStageReport(const [
        VectorSpan('style', null, 0, 5),
      ], dropped: 7);
      expect(report['spanCount'], 1);
      expect(report['droppedSpans'], 7);
    });

    test('queueWait is classified as async elapsed time', () {
      final report = buildVectorStageReport(const [
        VectorSpan('queueWait', '10/1/1', 0, 50),
      ]);
      expect((report['events'] as Map)['queueWait']!['kind'], 'async');
    });

    test('queue/backlog stages attribute the shared-parse bimodality', () {
      // A realistic over-zoom flow around one shared source parse:
      // the trigger pays dispatch + worker backlog + CPU (the reply
      // piggyback), the sibling joiner waits on the shared future, and
      // the manager-side stages carry no attempt id.
      final report = buildVectorStageReport(const [
        // Manager-side, attempt-less: presentation-lane queue and the
        // finished image's publication hop.
        VectorSpan('presentationQueueWait', '10/5/3', 0, 400),
        VectorSpan('publishWait', '10/5/3', 9800, 30),
        // Trigger r1.0: gate → main-lane dispatch wait → worker port
        // backlog → worker CPU → the outer parseWait total wraps all of it.
        VectorSpan('queueWait', '10/5/3', 400, 120, attempt: 'r1.0'),
        VectorSpan('parseQueueWait', '10/5/3', 520, 40,
            attempt: 'r1.0', source: '12/2/1'),
        VectorSpan('parseHold', '10/5/3', 560, 3000,
            attempt: 'r1.0', source: '12/2/1'),
        VectorSpan('parse', '10/5/3', 3560, 250,
            attempt: 'r1.0', source: '12/2/1'),
        VectorSpan('parseWait', '10/5/3', 520, 3390,
            attempt: 'r1.0', source: '12/2/1'),
        // Joiner r1.1: joins the in-flight shared parse.
        VectorSpan('queueWait', '10/5/4', 400, 130, attempt: 'r1.1'),
        VectorSpan('parseSharedWait', '10/5/4', 530, 3480,
            attempt: 'r1.1', source: '12/2/1'),
        VectorSpan('parseWait', '10/5/4', 530, 3480,
            attempt: 'r1.1', source: '12/2/1'),
      ]);

      final events = report['events'] as Map<String, dynamic>;
      for (final name in [
        'parseSharedWait',
        'parseHold',
        'parseQueueWait',
        'presentationQueueWait',
        'publishWait',
      ]) {
        expect(events[name]!['kind'], 'async',
            reason: '$name is elapsed time including waits');
      }
      expect(events['parse']!['kind'], 'sync',
          reason: 'worker-reported parse CPU is CPU-attributable');

      final tiles = report['tiles'] as Map<String, dynamic>;
      // The trigger attempt carries worker stats next to its total wait;
      // the sums must add up: dispatch 40 + backlog 3000 + CPU 250 ≈ the
      // outer parseWait total (3400 ≈ 3390 ± reply hop).
      final trigger = (tiles['10/5/3'] as Map)['attempts']['r1.0'];
      expect(trigger['parseWaitUs'], 3390);
      expect(trigger['parseQueueWaitUs'], 40);
      expect(trigger['parseHoldUs'], 3000);
      expect(trigger['parseCpuUs'], 250);
      expect(trigger['parseCpuN'], 1);
      final stages = trigger['stages'] as Map<String, dynamic>;
      expect((stages['parseHold'] as Map)['totalUs'], 3000);
      expect((stages['parseHold'] as Map)['sources'], ['12/2/1']);
      expect((stages['parse'] as Map)['totalUs'], 250);

      // The joiner is visibly a joiner: a separate counter from the
      // trigger-side parseWait, naming the shared source.
      final joiner = (tiles['10/5/4'] as Map)['attempts']['r1.1'];
      expect(joiner['parseSharedWaitUs'], 3480);
      expect(joiner['parseSharedN'], 1);
      expect(joiner.containsKey('parseCpuUs'), isFalse,
          reason: 'the shared CPU lands on the triggering attempt only');
      expect(joiner['sourceTiles'], ['12/2/1']);

      // Manager-side stages stay attempt-less at tile level.
      final tile3 = tiles['10/5/3'] as Map<String, dynamic>;
      final lane = tile3['presentationQueue'] as Map<String, dynamic>;
      expect(lane['n'], 1);
      expect(lane['totalUs'], 400);
      final publish = tile3['publishWait'] as Map<String, dynamic>;
      expect(publish['n'], 1);
      expect(publish['totalUs'], 30);
    });
  });
}
