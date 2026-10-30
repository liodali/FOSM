// Re-runs the timeline acceptance gate on a saved capture without
// re-running the app:
//
//   dart run tool/revalidate_timeline.dart FLUTTER_RUN_LOG TIMELINE_JSON
//
// Useful when the gate logic changes after a capture: the timeline file
// holds every collected event and the run log holds the scenario
// markers. Prints the per-scenario results and exits 3 on failure
// (mirroring capture_benchmark.dart).
import 'dart:convert';
import 'dart:io';

import 'package:example/benchmark/timeline_gate.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('Usage: dart run tool/revalidate_timeline.dart '
        'FLUTTER_RUN_LOG TIMELINE_JSON');
    exitCode = 64;
    return;
  }
  final scenarios = <TimelineScenarioMark>[];
  for (final line in File(arguments[0]).readAsLinesSync()) {
    if (parseScenarioMarkLine(line) case final mark?) scenarios.add(mark);
  }
  final timeline = jsonDecode(File(arguments[1]).readAsStringSync())
      as Map<String, dynamic>;
  final events = (timeline['traceEvents'] as List? ?? const [])
      .whereType<Map>()
      .map((event) => Map<String, dynamic>.from(event))
      .toList(growable: false);

  final results = validateTimelineAgainstScenarios(scenarios, events);
  for (final result in results) {
    final status = result.ok ? 'OK  ' : 'FAIL';
    stderr.writeln('$status ${result.scenario.name} '
        'window=${result.windowFound} counts=${result.counts}'
        '${result.failures.isEmpty ? '' : ' — ${result.failures.join('; ')}'}');
  }
  final failed = results.where((r) => !r.ok).length;
  stderr.writeln('${results.length - failed}/${results.length} scenarios '
      'valid');
  if (scenarios.isEmpty || failed > 0) exitCode = 3;
}
