/// Opt-in accounting for dashed-line preparation. Timings include stopwatch
/// overhead and should only be compared within instrumented diagnostic runs.
class VectorDashDiagnostics {
  VectorDashDiagnostics._();

  static const bool enabled =
      bool.fromEnvironment('fosm.vectorDashDiagnostics');
  static const int capacity = 4096;
  static final Map<(String?, String?, String), VectorDashStats> _rows = {};
  static int _dropped = 0;

  /// Clear at the start of a measurement window.
  static void clear() {
    _rows.clear();
    _dropped = 0;
  }

  /// Returns mutable counters for a render attempt, or null when full.
  static VectorDashStats? row(String? tile, String? attempt, String layer) {
    if (!enabled) return null;
    final key = (tile, attempt, layer);
    final existing = _rows[key];
    if (existing != null) return existing;
    if (_rows.length >= capacity) {
      _dropped++;
      return null;
    }
    return _rows[key] = VectorDashStats(tile, attempt, layer);
  }

  /// Snapshot of rows, including incomplete or cancelled work performed in
  /// the window. A nonzero dropped count makes the report incomplete; it
  /// counts rejected counter updates, not necessarily distinct rows.
  static Map<String, Object> snapshot() => {
        'droppedUpdates': _dropped,
        'rows': [for (final row in _rows.values) row.toJson()],
      };
}

class VectorDashStats {
  VectorDashStats(this.tile, this.attempt, this.layer);

  static final int _frequency = Stopwatch().frequency;

  final String? tile;
  final String? attempt;
  final String layer;
  int contours = 0;
  int patternSteps = 0;
  int extractions = 0;
  int culledExtractions = 0;
  int culledUnproven = 0;
  int offscreenExtractions = 0;
  int unknownBounds = 0;
  int extractionTicks = 0;
  int drawDispatchTicks = 0;
  int solidFallbacks = 0;

  Map<String, Object?> toJson() => {
        'tile': tile,
        'attempt': attempt,
        'layer': layer,
        'contours': contours,
        'patternSteps': patternSteps,
        'extractions': extractions,
        'culledExtractions': culledExtractions,
        'culledUnproven': culledUnproven,
        'offscreenExtractions': offscreenExtractions,
        'unknownBounds': unknownBounds,
        'extractionUs': extractionTicks * 1000000 / _frequency,
        'drawDispatchUs': drawDispatchTicks * 1000000 / _frequency,
        'solidFallbacks': solidFallbacks,
      };
}
