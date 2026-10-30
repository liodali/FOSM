import 'package:flutter_test/flutter_test.dart';

import 'package:example/benchmark/timeline_gate.dart';

Map<String, dynamic> _event(String name, int ts) => {'name': name, 'ts': ts};

void main() {
  test('timeline dedup preserves phases, async ids and correlation', () {
    final event = <String, dynamic>{
      'name': 'record',
      'ts': 1,
      'tid': 2,
      'pid': 3,
      'ph': 'b',
      'id': 'a',
      'args': {'attempt': 'r1.0'}
    };
    final variants = [
      event,
      {...event, 'ph': 'e'},
      {...event, 'id': 'b'},
      {...event, 'pid': 4},
      {
        ...event,
        'id2': {'local': 'x'}
      },
      {
        ...event,
        'args': {'attempt': 'r1.1'}
      }
    ];
    expect(variants.map(timelineEventSignature).toSet(), hasLength(6));
    expect(
        timelineEventSignature({
          'ts': 1,
          'name': 'record',
          'args': {'b': 2, 'a': 1}
        }),
        timelineEventSignature({
          'args': {'a': 1, 'b': 2},
          'name': 'record',
          'ts': 1
        }));
  });

  group('parseScenarioMarkLine', () {
    test('extracts name, cache state, source and style switch', () {
      final mark = parseScenarioMarkLine(
          'flutter: FOSM_BENCHMARK_SCENARIO vector_cold_static motion=none '
          'cacheState=coldBytes source=vector startZoom=10 '
          'styleSwitch=false settled=true');
      expect(mark, isNotNull);
      expect(mark!.name, 'vector_cold_static');
      expect(mark.cacheState, 'coldBytes');
      expect(mark.source, 'vector');
      expect(mark.styleSwitch, isFalse);
    });

    test('non-marker lines return null', () {
      expect(parseScenarioMarkLine('FOSM_BENCHMARK_RESULT {…}'), isNull);
      expect(parseScenarioMarkLine('plain noise'), isNull);
    });

    test('required events follow the cache state', () {
      TimelineScenarioMark mark(String cacheState,
              {bool styleSwitch = false, String source = 'vector'}) =>
          TimelineScenarioMark(
              name: 's',
              cacheState: cacheState,
              source: source,
              styleSwitch: styleSwitch);

      expect(mark('coldBytes').requiredEvents,
          containsAll(['parse', 'parseWait', 'record', 'toImage']));
      expect(mark('warmBytesColdParsed').requiredEvents, contains('parse'));
      // A style switch reloads the runtime: parses must appear.
      expect(mark('warmRendered', styleSwitch: true).requiredEvents,
          contains('parse'));
      // Warm-parsed re-renders may be served by retention and fallback
      // pins, so no pipeline events are required.
      expect(mark('warmParsedColdImages').requiredEvents,
          unorderedEquals(['record', 'toImage']));
      // Fully warm and raster scenarios have no required pipeline events.
      expect(mark('warmRendered').requiredEvents, isEmpty);
      expect(mark('coldBytes', source: 'raster').requiredEvents, isEmpty);
    });
  });

  group('validateTimelineAgainstScenarios', () {
    test('accepts a cold scenario with the full critical path in-window', () {
      final results = validateTimelineAgainstScenarios([
        const TimelineScenarioMark(
            name: 'cold',
            cacheState: 'coldBytes',
            source: 'vector',
            styleSwitch: false),
      ], [
        _event('fosm.benchmark.sampleStart.cold', 1000),
        _event('fosm.vector.parseWait', 1100),
        _event('fosm.vector.parse', 1200),
        _event('fosm.vector.record', 1500),
        _event('fosm.vector.toImage', 1800),
        _event('fosm.benchmark.sampleEnd.cold', 2000),
      ]);
      expect(results.single.ok, isTrue);
      expect(results.single.counts['parse'], 1);
    });

    test('rejects required events that fall outside the window', () {
      final results = validateTimelineAgainstScenarios([
        const TimelineScenarioMark(
            name: 'cold',
            cacheState: 'coldBytes',
            source: 'vector',
            styleSwitch: false),
        const TimelineScenarioMark(
            name: 'warm',
            cacheState: 'warmRendered',
            source: 'vector',
            styleSwitch: false),
      ], [
        // An earlier scenario's parse does not count for 'cold'.
        _event('fosm.benchmark.sampleStart.cold', 1000),
        _event('fosm.vector.parse', 900),
        _event('fosm.vector.parseWait', 950),
        _event('fosm.vector.record', 960),
        _event('fosm.vector.toImage', 970),
        _event('fosm.benchmark.sampleEnd.cold', 2000),
        // The warm scenario has no required events — boundaries suffice.
        _event('fosm.benchmark.sampleStart.warm', 2100),
        _event('fosm.benchmark.sampleEnd.warm', 3000),
      ]);
      final cold = results.first;
      expect(cold.ok, isFalse);
      expect(cold.failures, everyElement(contains('inside the window')));
      expect(results.last.ok, isTrue,
          reason: 'warm scenarios may legitimately skip the pipeline');
    });

    test('fails scenarios without capture boundaries', () {
      final results = validateTimelineAgainstScenarios([
        const TimelineScenarioMark(
            name: 'missing',
            cacheState: 'coldBytes',
            source: 'vector',
            styleSwitch: false),
      ], [
        _event('fosm.benchmark.sampleStart.missing', 1000),
        // No sampleEnd: the recorder stopped early.
        _event('fosm.vector.parse', 1100),
      ]);
      expect(results.single.ok, isFalse);
      expect(results.single.windowFound, isFalse);
      expect(results.single.failures.single, contains('sampleEnd'));
    });

    test('warm-parsed scenarios reject retained imagery without rendering', () {
      final results = validateTimelineAgainstScenarios([
        const TimelineScenarioMark(
            name: 'wp',
            cacheState: 'warmParsedColdImages',
            source: 'vector',
            styleSwitch: false),
      ], [
        _event('fosm.benchmark.sampleStart.wp', 100),
        _event('fosm.benchmark.sampleEnd.wp', 400),
      ]);
      expect(results.single.ok, isFalse);
      expect(results.single.failures, hasLength(2));
    });

    test('warm-parsed requires rendering and rejects fresh parses', () {
      const scenario = TimelineScenarioMark(
          name: 'wp',
          cacheState: 'warmParsedColdImages',
          source: 'vector',
          styleSwitch: false);
      final events = [
        _event('fosm.benchmark.sampleStart.wp', 100),
        _event('fosm.vector.record', 200),
        _event('fosm.vector.toImage', 300),
        _event('fosm.benchmark.sampleEnd.wp', 400),
      ];
      expect(validateTimelineAgainstScenarios([scenario], events).single.ok,
          isTrue);
      final cold = validateTimelineAgainstScenarios(
          [scenario], [...events, _event('fosm.vector.parse', 150)]).single;
      expect(cold.ok, isFalse);
      expect(cold.failures.single, contains('fresh parses'));
    });

    test('style-switch scenarios require the reload parse', () {
      final results = validateTimelineAgainstScenarios([
        const TimelineScenarioMark(
            name: 'sw',
            cacheState: 'warmRendered',
            source: 'vector',
            styleSwitch: true),
      ], [
        _event('fosm.benchmark.sampleStart.sw', 100),
        _event('fosm.vector.record', 200),
        _event('fosm.vector.toImage', 300),
        _event('fosm.benchmark.sampleEnd.sw', 400),
      ]);
      expect(results.single.ok, isFalse,
          reason: 'the style reload must parse; only rendering appeared');
    });
  });
}
