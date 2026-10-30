import 'dart:convert';

// Validates a saved VM timeline against the benchmark's scenario
// markers, so a capture gate can prove *per-scenario* coverage instead
// of a global duration that any late tail of events satisfies.
//
// The benchmark app emits zero-work timeline markers
// (`fosm.benchmark.sampleStart.<scenario>` / `sampleEnd.<scenario>`) at
// its recording boundaries — same clock as the pipeline events, so no
// wall-clock alignment is needed — and prints a
// `FOSM_BENCHMARK_SCENARIO <name> motion=… cacheState=… source=…` line
// per scenario. This library parses those log lines and checks each
// scenario's timeline window for the events its cache state requires:
//
// - vector + `coldBytes`/`warmBytesColdParsed`: the full critical path
//   (`parse`, `parseWait`, `record`, `toImage`) must appear — a fresh
//   runtime always parses.
// - vector + `styleSwitch`: same as cold — the mid-window style reload
//   is a fresh runtime over the same payloads.
// - vector + `warmParsedColdImages`: `record` + `toImage` must appear;
//   parsing may legitimately be skipped (parsed-tile cache hits).
// - vector + `warmRendered` (no switch) and every raster scenario: no
//   required pipeline events — everything may be served warm — but the
//   capture boundaries must still exist.

/// One scenario parsed from a benchmark log's SCENARIO marker line.
class TimelineScenarioMark {
  const TimelineScenarioMark({
    required this.name,
    required this.cacheState,
    required this.source,
    required this.styleSwitch,
  });

  final String name;

  /// `coldBytes` | `warmBytesColdParsed` | `warmParsedColdImages` |
  /// `warmRendered`.
  final String cacheState;

  /// `vector` | `raster`.
  final String source;
  final bool styleSwitch;

  /// Pipeline events (without the `fosm.vector.` prefix) that must appear
  /// inside this scenario's timeline window; empty when every stage may
  /// legitimately be served warm.
  List<String> get requiredEvents {
    if (source != 'vector') return const [];
    final coldLike = cacheState == 'coldBytes' ||
        cacheState == 'warmBytesColdParsed' ||
        styleSwitch;
    if (coldLike) return const ['parse', 'parseWait', 'record', 'toImage'];
    if (cacheState == 'warmParsedColdImages') {
      return const ['record', 'toImage'];
    }
    return const [];
  }
}

/// Validation outcome for one scenario.
class ScenarioGateResult {
  const ScenarioGateResult({
    required this.scenario,
    required this.windowFound,
    required this.counts,
    required this.failures,
  });

  final TimelineScenarioMark scenario;

  /// Whether both `sampleStart`/`sampleEnd` boundary events exist in the
  /// timeline. Without boundaries the window cannot be validated at all.
  final bool windowFound;

  /// Required events counted inside the scenario window.
  final Map<String, int> counts;

  final List<String> failures;

  bool get ok => failures.isEmpty;
}

/// Parses a `FOSM_BENCHMARK_SCENARIO` line (`NAME motion=…
/// cacheState=… source=… styleSwitch=…`); `null` when the line is not a
/// scenario marker.
TimelineScenarioMark? parseScenarioMarkLine(String line) {
  final marker = line.indexOf('FOSM_BENCHMARK_SCENARIO ');
  if (marker < 0) return null;
  final rest = line.substring(marker + 'FOSM_BENCHMARK_SCENARIO '.length);
  final parts = rest.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts[0].isEmpty) return null;
  String? flag(String key) {
    for (final part in parts.skip(1)) {
      if (part.startsWith('$key=')) return part.substring(key.length + 1);
    }
    return null;
  }

  return TimelineScenarioMark(
    name: parts[0],
    cacheState: flag('cacheState') ?? 'warmRendered',
    source: flag('source') ?? 'vector',
    styleSwitch: flag('styleSwitch') == 'true',
  );
}

/// Validates raw timeline [events] (maps with `name` and `ts`) against
/// the scenario marks parsed from the log. Every scenario must have both
/// boundary markers, and each required pipeline event must occur inside
/// its window. Requirements: vector `coldBytes`/`warmBytesColdParsed`
/// and style-switch scenarios need the full critical path including
/// worker `parse`; `warmParsedColdImages` requires recording and image creation; fully-warm
/// and raster scenarios require only boundaries.
List<ScenarioGateResult> validateTimelineAgainstScenarios(
  List<TimelineScenarioMark> scenarios,
  List<Map<String, dynamic>> events,
) {
  int? markerTs(String prefix, String name) {
    for (final event in events) {
      if (event['name'] == 'fosm.benchmark.$prefix.$name') {
        final ts = event['ts'];
        if (ts is num) return ts.toInt();
      }
    }
    return null;
  }

  final results = <ScenarioGateResult>[];
  for (final scenario in scenarios) {
    final startTs = markerTs('sampleStart', scenario.name);
    final endTs = markerTs('sampleEnd', scenario.name);
    final failures = <String>[];
    final counts = <String, int>{};

    if (startTs == null || endTs == null) {
      failures.add(startTs == null
          ? 'missing sampleStart boundary in timeline'
          : 'missing sampleEnd boundary in timeline');
      results.add(ScenarioGateResult(
        scenario: scenario,
        windowFound: false,
        counts: counts,
        failures: failures,
      ));
      continue;
    }

    final from = startTs <= endTs ? startTs : endTs;
    final to = startTs <= endTs ? endTs : startTs;
    for (final required in scenario.requiredEvents) {
      var count = 0;
      for (final event in events) {
        if (event['name'] != 'fosm.vector.$required') continue;
        final ts = event['ts'];
        if (ts is! num) continue;
        final us = ts.toInt();
        if (us >= from && us <= to) count++;
      }
      counts[required] = count;
      if (count == 0) {
        failures.add('no fosm.vector.$required events inside the window');
      }
    }
    if (scenario.source == 'vector' &&
        scenario.cacheState == 'warmParsedColdImages') {
      final parses = events
          .where((event) =>
              event['name'] == 'fosm.vector.parse' &&
              event['ts'] is num &&
              (event['ts'] as num) >= from &&
              (event['ts'] as num) <= to)
          .length;
      counts['parse'] = parses;
      if (parses > 0) {
        failures.add('warm-parsed scenario performed fresh parses');
      }
    }
    results.add(ScenarioGateResult(
      scenario: scenario,
      windowFound: true,
      counts: counts,
      failures: failures,
    ));
  }
  return results;
}

/// Stable identity for repeated VM timeline snapshots. Preserve all event
/// fields (including phase, async id/id2, scope and correlation arguments).
/// Canonical map order makes equivalent JSON snapshots deduplicate.
String timelineEventSignature(Map<String, dynamic> event) {
  Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  return jsonEncode(canonical(event));
}
