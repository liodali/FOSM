// Line help for the printed benchmark payloads.
//
// The device console relay truncates long lines (~1 KB) and silently
// drops the rest, so kilobyte payloads are printed in chunked
// continuation lines (see `_payloadPrint` in map_vector_benchmark.dart):
//   `FOSM_BENCHMARK_RESULT {chunk}`
//   `FOSM_BENCHMARK_CHUNK {chunk}`
//   `FOSM_BENCHMARK_CHUNK_END`
// Parsers reassemble chunks and skip any line fragments the console
// may add around prints.

const _flutterPrefix = 'flutter: ';
const _chunkPrefix = 'FOSM_BENCHMARK_CHUNK ';
const _chunkEnd = 'FOSM_BENCHMARK_CHUNK_END';

/// Removes console prefixes like `flutter: `.
String stripConsolePrefix(String line) {
  final flutterAt = line.indexOf(_flutterPrefix);
  if (flutterAt >= 0) return line.substring(flutterAt + _flutterPrefix.length);
  return line;
}

/// A payload collected from one marker line plus any chunk continuations.
class PayloadCollected {
  const PayloadCollected(this.text, this.linesConsumed);

  /// Reassembled payload text.
  final String text;

  /// How many lines were consumed after the marker line at index 0.
  final int linesConsumed;
}

/// Collects the payload started on [lines] at [markerIndex]: [firstChunk]
/// is everything after the marker on the marker line, and subsequent
/// `FOSM_BENCHMARK_CHUNK` lines are absorbed until
/// `FOSM_BENCHMARK_CHUNK_END` or the first non-chunk line (older logs
/// print single-line payloads without markers).
PayloadCollected collectPayloadLines(
    List<String> lines, int markerIndex, String firstChunk) {
  final payload = StringBuffer(firstChunk);
  var index = markerIndex + 1;
  var consumed = 0;
  while (index < lines.length) {
    final stripped = stripConsolePrefix(lines[index]).trim();
    if (stripped.startsWith(_chunkPrefix)) {
      payload.write(stripped.substring(_chunkPrefix.length));
      index++;
      consumed++;
      continue;
    }
    if (stripped == _chunkEnd) {
      index++;
      consumed++;
    }
    break;
  }
  return PayloadCollected(payload.toString(), consumed);
}
