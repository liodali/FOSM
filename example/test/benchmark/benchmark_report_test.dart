import 'package:example/benchmark/benchmark_report.dart';
import 'package:flutter_test/flutter_test.dart';

String _meta([String extra = '']) =>
    'FOSM_BENCHMARK_META {"label":"x","schedulerPaced":true$extra}';

String _result(String scenario, {Object? valid}) => 'FOSM_BENCHMARK_RESULT '
    '{"label":"x","scenario":"$scenario"${valid == null ? '' : ',"valid":$valid'}}';

void main() {
  test('coverage thresholds use exact first crossings and preserve misses', () {
    expect(
        coverageThresholdTimings([
          [0, 0, 0],
          [7, 0.95, 0.1],
          [9, 0.5, 0.05],
          [11, 1, 0.95],
          [12, 1, 1],
        ]),
        {'firstSharpMs': 7, 'covered95Ms': 7, 'sharp95Ms': 11});
    expect(
        coverageThresholdTimings([
          [0, 0, 0],
          [8, 0.9, 0.2]
        ]),
        {'firstSharpMs': 8, 'covered95Ms': null, 'sharp95Ms': null});
    expect(coverageThresholdTimings([]),
        {'firstSharpMs': null, 'covered95Ms': null, 'sharp95Ms': null});
  });

  test('parses metadata and results across lines', () {
    final parse = parseBenchmarkLog([
      'Launching…',
      'flutter: ${_meta()}',
      'flutter: FOSM_BENCHMARK_SCENARIO a warmupSeconds=2',
      'flutter: ${_result('a')}',
      'flutter: FOSM_BENCHMARK_DONE x',
    ].join('\n'));
    expect(parse.metadata, isNotNull);
    expect(parse.metadata!['schedulerPaced'], isTrue);
    expect(parse.scenarios, hasLength(1));
    expect(parse.scenarios.single['scenario'], 'a');
    expect(parse.hasDone, isTrue);
    expect(parse.skippedInvalid, 0);
  });

  test('console noise sharing the first marker line still parses', () {
    final parse = parseBenchmarkLog(
        'Running build hooks...Running build hooks...${_meta()}');
    expect(parse.metadata, isNotNull);
    expect(parse.metadata!['label'], 'x');
  });

  test('invalid results are skipped, valid ones kept', () {
    final parse = parseBenchmarkLog([
      _meta(),
      _result('good'),
      _result('resize_idle', valid: false),
      _result('good2'),
      'FOSM_BENCHMARK_DONE x',
    ].join('\n'));
    expect(parse.scenarios.map((s) => s['scenario']), ['good', 'good2']);
    expect(parse.skippedInvalid, 1);
    expect(parse.hasDone, isTrue);
  });

  test('missing DONE marker is detectable per file', () {
    final parse = parseBenchmarkLog([_meta(), _result('a')].join('\n'));
    expect(parse.hasDone, isFalse);
    expect(parse.scenarios, hasLength(1));
  });

  test('report encoding merges runs and labels the arm', () {
    final a = parseBenchmarkLog([
      _meta(',"refreshHz":60.0'),
      _result('a'),
      'FOSM_BENCHMARK_DONE x'
    ].join('\n'));
    final b = parseBenchmarkLog([
      'FOSM_BENCHMARK_META {"label":"y","schedulerPaced":false}',
      _result('b'),
      'FOSM_BENCHMARK_DONE y'
    ].join('\n'));
    final report = encodeBenchmarkReport([a, b], baseCommit: 'deadbeef');
    final decoded = report.replaceAll(RegExp(r'\s'), '');
    expect(decoded, contains('"baseCommit":"deadbeef"'));
    expect(decoded, contains('"implementation":"sharedscheduler(pacedarm)"'));
    expect(decoded, contains('"runs":2'));
    expect(decoded, contains('"schedulerPaced":true')); // first metadata wins
    expect(decoded, contains('"scenario":"a"'));
    expect(decoded, contains('"scenario":"b"'));

    final unpacedReport = encodeBenchmarkReport([b], baseCommit: 'deadbeef');
    expect(unpacedReport, contains('fosm.unpaced=true (pre-scheduler arm)'));
  });

  test('encoding throws when no log carried metadata', () {
    final parse = parseBenchmarkLog(_result('a'));
    expect(() => encodeBenchmarkReport([parse], baseCommit: 'x'),
        throwsA(isA<StateError>()));
  });

  group('coverageMeanOverWindow', () {
    test('integrates across the full window with boundary extension', () {
      // Blank until 1000 ms, covered for the rest of a 12000 ms window:
      // the still map stops producing frames after 2000 ms, so the
      // samples span only 1000–2000 ms of the window.
      final samples = [
        [1000.0, 0.0],
        [2000.0, 1.0],
      ];
      final mean = coverageMeanOverWindow(samples, 1, 12000)!;
      // Head: 1000 ms at 0.0; between: 1000 ms at 0.0; tail: 10000 ms at 1.0.
      expect(mean, closeTo(10000 / 12000, 1e-9));
    });

    test('first-sample value holds from window start', () {
      // Warm start: the first sample (already covered) extends back to 0.
      final samples = [
        [500.0, 1.0],
        [1500.0, 0.5],
      ];
      final mean = coverageMeanOverWindow(samples, 1, 2000)!;
      // 0–500 at 1.0, 500–1500 at 1.0, 1500–2000 at 0.5.
      expect(mean, closeTo(1500 / 2000 + 250 / 2000, 1e-9));
    });

    test('same-frame repeats carry no weight', () {
      final samples = [
        [0.0, 0.0],
        [0.0, 1.0], // Same-frame duplicate.
        [1000.0, 1.0],
      ];
      final mean = coverageMeanOverWindow(samples, 1, 1000)!;
      expect(mean, 1.0);
    });

    test('single sample spans the window', () {
      expect(
          coverageMeanOverWindow([
            [300.0, 0.25]
          ], 1, 1000),
          0.25);
      expect(coverageMeanOverWindow(const [], 1, 1000), isNull);
    });

    test('degenerate zero window falls back to the first sample', () {
      expect(
          coverageMeanOverWindow([
            [0.0, 0.5]
          ], 1, 0),
          0.5);
    });
  });
}
