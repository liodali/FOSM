// Parse FOSM_BENCHMARK capture logs into the structured JSON format used
// by docs/performance raw reports. No packages.
//
//   dart run tool/parse_benchmark_log.dart LOG [LOG...] > report.json
//
// Invalid scenarios (valid:false, e.g. a mistimed external resize driver)
// are skipped with a warning, never exported. A log without its DONE
// marker (truncated run) warns and sets exit code 2.
import 'dart:io';

import 'package:example/benchmark/benchmark_report.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr
        .writeln('Usage: dart run tool/parse_benchmark_log.dart LOG [LOG...]');
    exitCode = 64;
    return;
  }
  final parses = <BenchmarkLogParse>[];
  var incomplete = 0;
  for (final argument in arguments) {
    final parse = parseBenchmarkLog(File(argument).readAsStringSync());
    if (parse.metadata == null) {
      stderr.writeln('warning: $argument contains no META line');
    }
    if (parse.skippedInvalid > 0) {
      stderr.writeln('skipped ${parse.skippedInvalid} invalid result(s) '
          'from $argument');
    }
    if (!parse.hasDone) {
      stderr.writeln('incomplete: $argument has no DONE marker');
      incomplete++;
    }
    parses.add(parse);
  }
  if (parses.every((p) => p.metadata == null)) {
    stderr.writeln('error: no FOSM_BENCHMARK_META line in any input');
    exitCode = 65;
    return;
  }
  final head = await Process.run('git', ['rev-parse', 'HEAD']);
  stdout.writeln(encodeBenchmarkReport(parses,
      baseCommit: (head.stdout as String).trim()));
  if (incomplete > 0) exitCode = 2;
}
