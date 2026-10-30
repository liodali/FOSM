// Extracts FOSM_BENCHMARK_VECTOR_STAGES lines from capture logs into one
// JSON file per line, so stage reports live beside the parsed benchmark
// results without duplicating parsing logic.
//
//   dart run tool/extract_vector_stages.dart LOG_DIR OUT_DIR
//
// Each input log may hold several lines (one per scenario); outputs are
// numbered <log-stem>-<n>.json. Stage payloads ride out chunked (see
// log_lines.dart) and are reassembled here. Logs without stage lines
// are skipped.
import 'dart:convert';
import 'dart:io';

import 'package:example/benchmark/log_lines.dart';

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
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final cleaned = stripConsolePrefix(lines[i]);
      final scenarioMarker = cleaned.indexOf('FOSM_BENCHMARK_SCENARIO ');
      if (scenarioMarker >= 0) {
        final rest = cleaned
            .substring(scenarioMarker + 'FOSM_BENCHMARK_SCENARIO '.length);
        lastScenario = rest.trim().split(RegExp(r'\s+')).first;
      }
      const marker = 'FOSM_BENCHMARK_VECTOR_STAGES ';
      final markerAt = cleaned.indexOf(marker);
      if (markerAt < 0) continue;
      final collected =
          collectPayloadLines(lines, i, cleaned.substring(markerAt + marker.length));
      i += collected.linesConsumed;
      try {
        // Validate before writing: a truncated console line must not
        // become a broken JSON report.
        final decoded = jsonDecode(collected.text);
        if (decoded is Map) decoded['scenario'] = lastScenario;
        final sink = File('${out.path}/$stem-${index++}.json');
        sink.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(decoded));
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
