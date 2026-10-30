// Extracts FOSM_BENCHMARK_VECTOR_STAGES lines from capture logs into one
// JSON file per line, so stage reports live beside the parsed benchmark
// results without a parser dependency.
//
//   dart run tool/extract_vector_stages.dart LOG_DIR OUT_DIR
//
// Each input log may hold several lines (one per scenario); outputs are
// numbered <log-stem>-<n>.json. Logs without stage lines are skipped.
// No packages.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
        'Usage: dart run tool/extract_vector_stages.dart LOG_DIR OUT_DIR');
    exitCode = 64;
    return;
  }
  final logs = Directory(arguments[0]);
  final out = Directory(arguments[1])..createSync(recursive: true);
  if (!logs.existsSync()) {
    stderr.writeln('No such log directory: ${logs.path}');
    exitCode = 66;
    return;
  }

  var extracted = 0;
  final files = logs
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.log'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final stem = file.uri.pathSegments.last.replaceAll(RegExp(r'\.log$'), '');
    var index = 0;
    var lastScenario = 'unknown';
    for (final line in file.readAsLinesSync()) {
      final scenarioMarker = line.indexOf('FOSM_BENCHMARK_SCENARIO ');
      if (scenarioMarker >= 0) {
        final rest = line.substring(scenarioMarker + 'FOSM_BENCHMARK_SCENARIO '.length);
        lastScenario = rest.trim().split(RegExp(r'\s+')).first;
      }
      final marker = line.indexOf('FOSM_BENCHMARK_VECTOR_STAGES ');
      if (marker < 0) continue;
      final payload = line.substring(marker + 'FOSM_BENCHMARK_VECTOR_STAGES '.length);
      try {
        // Validate before writing: a truncated console line must not
        // become a broken JSON report.
        final decoded = jsonDecode(payload);
        if (decoded is Map) decoded['scenario'] = lastScenario;
        final sink = File('${out.path}/$stem-${index++}.json');
        sink.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(decoded));
        extracted++;
        stdout.writeln(sink.path);
      } on FormatException {
        stderr.writeln('skipping malformed stage line in ${file.path}');
      }
    }
  }
  stdout.writeln('extracted $extracted stage reports to ${out.path}');
  if (extracted == 0) exitCode = 1;
}
