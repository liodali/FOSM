// Aggregates `VectorSpanLog` spans into the per-scenario stage report
// printed by the vector benchmark harness. Importable so tests can verify
// the aggregation.
//
// Semantics (docs/performance/vector-processing.md):
// - Sync spans (`recordChunk.*`, `style`, `geometry`, `dash`,
//   `parseDispatch`, `parseReply`, `labels.paint`) wrap synchronous
//   closures: their durations are CPU-attributable per slice and safe to
//   sum within an event.
// - Async spans (`fetch`, `queueWait`, `parseWait`, `record`, `imageWait`,
//   `toImage`, `labels.build`, `labels.layout`) measure elapsed time
//   including waits and scheduler queues; they may overlap and must never
//   be summed as CPU.
// - Markers (`staleAbort`, `payloadInvalid`, `publish`) are zero-duration
//   events.
//
// Identity: rows are keyed by tile coordinate but stage detail is kept
// **per rendering attempt** — tile coordinates alone cannot identify an
// attempt (return pans, retries and style switches reuse them). Each
// attempt row carries its wall-clock window (`startUs`/`endUs`), its
// resolved source tiles, and a `stages` map with every stage's
// `startUs`/`endUs`/`totalUs`/`n` — so queue gaps (for example
// `queueWait.endUs → parseWait.startUs`) and shared parses (several
// attempts naming the same source tile) can be reconstructed. `fetch`
// spans run per tile-manager job before attempts exist, so they
// aggregate per tile (with their source tiles listed); per-attempt sums
// are critical-path lengths for that attempt, not global CPU totals.

import 'package:fosm/fosm.dart' show VectorSpan;

// "No sample yet" sentinel for stage windows: a large-but-dart2js-safe
// power of two (the full int64 maximum is not exactly representable as a
// JavaScript number and fails web compilation).
const _beforeAnySampleUs = 1 << 62;

const List<String> _asyncEvents = [
  'fetch',
  'queueWait',
  'parseWait',
  'record',
  'imageWait',
  'toImage',
  'labels.build',
  'labels.layout',
];

/// Builds the stage report for one measurement window's spans.
///
/// [dropped] is `VectorSpanLog.dropped` at window end (spans removed by
/// the capacity bound); tiles beyond [maxTiles] are omitted (the report
/// notes the truncation in `tilesTruncated`).
Map<String, Object?> buildVectorStageReport(
  List<VectorSpan> spans, {
  int? dropped,
  int maxTiles = 512,
}) {
  final events = <String, Map<String, Object?>>{};
  final tiles = <String, Map<String, Object?>>{};
  final truncatedTiles = <String>{};

  void aggregateEvent(String name, int durationUs) {
    final stats = events.putIfAbsent(
      name,
      () => <String, Object?>{
        'kind': _asyncEvents.contains(name) ? 'async' : 'sync',
        '_n': <int>[],
      },
    );
    (stats['_n'] as List<int>).add(durationUs);
  }

  for (final span in spans) {
    final name = span.event;
    aggregateEvent(name, span.durationUs);

    if (durationIsMarker(name)) {
      // Counted globally below via the events table.
    }
    final tile = span.tile;
    if (tile == null) continue;

    final known = tiles.containsKey(tile);
    if (!known && tiles.length >= maxTiles) {
      truncatedTiles.add(tile);
      continue;
    }
    final row = tiles.putIfAbsent(
        tile, () => <String, Object?>{'tile': tile});
    _accumulate(row, span);
  }

  return {
    'spanCount': spans.length,
    'droppedSpans': dropped ?? 0,
    'markers': {
      for (final entry in _markerCounts(spans).entries)
        entry.key: entry.value,
    },
    'events': {
      for (final entry in events.entries)
        entry.key: _finishEventStats(entry.value),
    },
    'tiles': tiles,
    if (truncatedTiles.isNotEmpty) 'tilesTruncated': truncatedTiles.length,
  };
}

Map<String, int> _markerCounts(List<VectorSpan> spans) {
  final counts = <String, int>{};
  for (final span in spans) {
    if (durationIsMarker(span.event)) {
      counts[span.event] = (counts[span.event] ?? 0) + 1;
    }
  }
  return counts;
}

Map<String, Object?> _finishEventStats(Map<String, Object?> stats) {
  final durations = (stats['_n'] as List<int>)..sort();
  int p(double q) => durations[
      ((durations.length - 1) * q).floor().clamp(0, durations.length - 1)];
  stats
    ..remove('_n')
    ..['n'] = durations.length
    ..['totalUs'] = durations.fold<int>(0, (a, b) => a + b)
    ..['p50Us'] = p(0.5)
    ..['p95Us'] = p(0.95)
    ..['p99Us'] = p(0.99)
    ..['maxUs'] = durations.last;
  return stats;
}

bool durationIsMarker(String name) =>
    name == 'staleAbort' || name == 'payloadInvalid' || name == 'publish';

Map<String, Object?> _attemptRow(
    Map<String, Object?> tileRow, String attempt) {
  final attempts =
      tileRow.putIfAbsent('attempts', () => <String, Object?>{})
          as Map<String, Object?>;
  final existing = attempts[attempt];
  if (existing is Map<String, Object?>) return existing;
  final created = <String, Object?>{
    'attempt': attempt,
    'startUs': _beforeAnySampleUs,
    'endUs': 0,
  };
  attempts[attempt] = created;
  return created;
}

void _widenWindow(Map<String, Object?> row, int startUs, int durationUs) {
  if (startUs < (row['startUs'] as int)) row['startUs'] = startUs;
  final end = startUs + durationUs;
  if (end > (row['endUs'] as int)) row['endUs'] = end;
}

void _accumulate(Map<String, Object?> row, VectorSpan span) {
  final name = span.event;
  final attempt = span.attempt;
  if (attempt != null) {
    final attemptRow = _attemptRow(row, attempt);
    _widenWindow(attemptRow, span.startUs, span.durationUs);
    if (span.source != null) {
      _addUnique(attemptRow, 'sourceTiles', span.source!);
    }
    _accumulateAttempt(attemptRow, span);
    return;
  }
  // Attempt-less stages: fetches run per tile-manager job (before any
  // decode attempt exists); worker hand-offs are not per-tile costs.
  switch (name) {
    case 'fetch':
      final fetch = row.putIfAbsent(
          'fetch', () => <String, Object?>{}) as Map<String, Object?>;
      fetch['totalUs'] = ((fetch['totalUs'] as int?) ?? 0) + span.durationUs;
      fetch['n'] = ((fetch['n'] as int?) ?? 0) + 1;
      final source = span.source;
      if (source != null) {
        _addUnique(fetch, 'sources', source);
      }
    case 'publish':
      row['publishN'] = ((row['publishN'] as int?) ?? 0) + 1;
  }
}

/// Adds [value] to the string list under [key], creating it on first use
/// and skipping duplicates (insertion order kept).
void _addUnique(Map<String, Object?> target, String key, String value) {
  final list = target[key] as List<String>?;
  if (list == null) {
    target[key] = [value];
  } else if (!list.contains(value)) {
    list.add(value);
  }
}

void _accumulateAttempt(Map<String, Object?> row, VectorSpan span) {
  // Per-stage window + totals: `recordChunk.<layer>` slices group under
  // `recordChunk` (per-layer distributions live in the global events
  // table); zero-duration markers get their timestamp as the window.
  final name = span.event;
  final group = name.startsWith('recordChunk.') ? 'recordChunk' : name;
  final stages =
      row.putIfAbsent('stages', () => <String, Object?>{}) as Map<String, Object?>;
  final existingStage = stages[group];
  final stage = existingStage is Map<String, Object?>
      ? existingStage
      : stages[group] = <String, Object?>{
          'startUs': _beforeAnySampleUs,
          'endUs': 0,
          'totalUs': 0,
          'n': 0,
        };
  if (span.startUs < (stage['startUs'] as int)) {
    stage['startUs'] = span.startUs;
  }
  final end = span.startUs + span.durationUs;
  if (end > (stage['endUs'] as int)) {
    stage['endUs'] = end;
  }
  stage['totalUs'] = (stage['totalUs'] as int) + span.durationUs;
  stage['n'] = (stage['n'] as int) + 1;
  final source = span.source;
  if (source != null) {
    _addUnique(stage, 'sources', source);
  }

  // Flat convenience counters (also kept per attempt).
  switch (name) {
    case 'queueWait':
      row['queueWaitUs'] = ((row['queueWaitUs'] as int?) ?? 0) + span.durationUs;
    case 'parseWait':
      row['parseWaitUs'] = ((row['parseWaitUs'] as int?) ?? 0) + span.durationUs;
      row['parseN'] = ((row['parseN'] as int?) ?? 0) + 1;
    case 'record':
      row['recordUs'] = ((row['recordUs'] as int?) ?? 0) + span.durationUs;
    case 'imageWait':
      row['imageWaitUs'] = ((row['imageWaitUs'] as int?) ?? 0) + span.durationUs;
    case 'toImage':
      row['toImageUs'] = ((row['toImageUs'] as int?) ?? 0) + span.durationUs;
    case 'labels.build':
      row['labelsBuildUs'] = ((row['labelsBuildUs'] as int?) ?? 0) + span.durationUs;
    case 'labels.layout':
      row['labelsLayoutUs'] =
          ((row['labelsLayoutUs'] as int?) ?? 0) + span.durationUs;
    case 'style':
      row['styleUs'] = ((row['styleUs'] as int?) ?? 0) + span.durationUs;
    case 'geometry':
      row['geometryUs'] = ((row['geometryUs'] as int?) ?? 0) + span.durationUs;
    case 'dash':
      row['dashUs'] = ((row['dashUs'] as int?) ?? 0) + span.durationUs;
    case 'staleAbort':
      row['staleAborts'] = ((row['staleAborts'] as int?) ?? 0) + 1;
    case 'payloadInvalid':
      row['payloadInvalid'] = ((row['payloadInvalid'] as int?) ?? 0) + 1;
    case 'publish':
      row['published'] = 1;
    default:
      if (name.startsWith('recordChunk.')) {
        row['recordChunkUs'] =
            ((row['recordChunkUs'] as int?) ?? 0) + span.durationUs;
      }
  }
}
