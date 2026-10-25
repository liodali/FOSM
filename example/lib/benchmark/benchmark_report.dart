// Parsing for FOSM benchmark capture logs: extracts the META/RESULT
// marker lines into the structured raw-report format used under
// docs/performance. Library so tests can drive it directly; the CLI in
// tool/parse_benchmark_log.dart reads files and prints the report.
import 'dart:convert';

/// Result of parsing one capture log.
class BenchmarkLogParse {
  /// The run's `FOSM_BENCHMARK_META` line, when present.
  Map<String, dynamic>? metadata;

  /// `FOSM_BENCHMARK_RESULT` lines with `valid: true`, in order.
  final List<Map<String, dynamic>> scenarios = [];

  /// Result lines skipped because the scenario reported `valid: false`
  /// (e.g. a mistimed external resize driver) — they must not enter an
  /// exported report as if they were measurements.
  int skippedInvalid = 0;

  /// Whether the run reached its `FOSM_BENCHMARK_DONE` completion marker.
  bool hasDone = false;
}

/// Parses one capture log. Console noise (e.g. "Running build hooks...")
/// can share the first line with the first marker, so markers are matched
/// wherever they appear in a line.
BenchmarkLogParse parseBenchmarkLog(String text) {
  final parse = BenchmarkLogParse();
  for (final line in text.split('\n')) {
    var cleaned = line;
    const flutterPrefix = 'flutter: ';
    final flutterAt = cleaned.indexOf(flutterPrefix);
    if (flutterAt >= 0) {
      cleaned = cleaned.substring(flutterAt + flutterPrefix.length);
    }
    const meta = 'FOSM_BENCHMARK_META ';
    const result = 'FOSM_BENCHMARK_RESULT ';
    const done = 'FOSM_BENCHMARK_DONE ';
    if (cleaned.contains(meta)) {
      parse.metadata =
          (jsonDecode(cleaned.substring(cleaned.indexOf(meta) + meta.length))
                  as Map)
              .cast<String, dynamic>();
    } else if (cleaned.contains(result)) {
      final scenario = (jsonDecode(
                  cleaned.substring(cleaned.indexOf(result) + result.length))
              as Map)
          .cast<String, dynamic>();
      if (scenario['valid'] == false) {
        parse.skippedInvalid++;
      } else {
        parse.scenarios.add(scenario);
      }
    } else if (cleaned.contains(done)) {
      parse.hasDone = true;
    }
  }
  return parse;
}

/// Merges parsed logs into the structured report document.
///
/// The first file's metadata wins (arms differ only by dart-define, which
/// the metadata records); scenarios are appended in order. Throws when no
/// parsed log carries metadata.
String encodeBenchmarkReport(List<BenchmarkLogParse> parses,
    {required String baseCommit}) {
  final metadata = parses.firstWhere((p) => p.metadata != null).metadata;
  final scenarios = <Map<String, dynamic>>[
    for (final parse in parses) ...parse.scenarios
  ];
  final paced = metadata!['schedulerPaced'] == true;
  return const JsonEncoder.withIndent('  ').convert({
    'baseCommit': baseCommit,
    'implementation': paced
        ? 'shared scheduler (paced arm)'
        : 'fosm.unpaced=true (pre-scheduler arm)',
    'runs': parses.where((p) => p.metadata != null).length,
    'metadata': metadata,
    'scenarios': scenarios,
  });
}

/// Mean of `samples[][index]` integrated across the **complete recording
/// window** `[0, windowMs]`, weighting each sample by the elapsed time it
/// represents. Samples are `[elapsedMs, value, …]` rows taken once per
/// rendered frame, so gaps are real: a still map stops producing frames
/// long before the window ends, and frame-count or first-to-last-sample
/// averaging would drop both the initial blank time and the fully covered
/// idle tail. The series is modelled piecewise-constant with boundary
/// extension — the first sample holds from window start, the last holds
/// until window end — which is exact for a still map on both ends and
/// honest to the sampling density in between. Same-timestamp repeats
/// carry no time weight.
double? coverageMeanOverWindow(
    List<List<double>> samples, int index, double windowMs) {
  if (samples.isEmpty) return null;
  var weighted = 0.0;
  var total = 0.0;
  for (var i = 0; i + 1 < samples.length; i++) {
    final dt = samples[i + 1][0] - samples[i][0];
    if (dt <= 0) continue; // Same-frame repeats carry no time weight.
    weighted += samples[i][index] * dt;
    total += dt;
  }
  final firstAt = samples.first[0].clamp(0.0, windowMs);
  weighted += samples.first[index] * firstAt;
  total += firstAt;
  final tail = (windowMs - samples.last[0]).clamp(0.0, windowMs);
  weighted += samples.last[index] * tail;
  total += tail;
  if (total <= 0) return samples.first[index];
  return weighted / total;
}
