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
  });
}
