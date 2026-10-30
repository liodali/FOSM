import 'dart:developer' as developer;

/// One recorded vector-pipeline span, or a zero-duration marker event.
///
/// Synchronous spans measure the wall time of a synchronous closure
/// (CPU-attributable work). Asynchronous spans measure elapsed time that
/// includes waits and scheduler queues, and may overlap other spans —
/// they must never be summed as CPU time.
///
/// Identity: [tile] is the logical `z/x/y` being produced, but coordinates
/// alone do not identify an attempt — return pans, retries and style
/// switches reuse them. [attempt] carries the runtime instance id plus a
/// per-decode sequence (`r3a17`: runtime #3, attempt #17) so every stage
/// of one rendering attempt can be grouped, and [source] carries the
/// resolved source tile (`z/x/y` after over-zoom) so shared parses and
/// downloads serving multiple logical tiles stay correlatable. Both are
/// `null` for spans/markers whose stage does not know them.
class VectorSpan {
  const VectorSpan(this.event, this.tile, this.startUs, this.durationUs,
      {this.attempt, this.source});

  /// Stage name without the `fosm.vector.` prefix (`parseWait`, `record`,
  /// `recordChunk.<layer>`, `geometry`, `dash`, `style`, `fetch`,
  /// `queueWait`, …), or a marker event name (`staleAbort`,
  /// `payloadInvalid`, `publish`).
  final String event;

  /// Logical tile `z/x/y` when the stage knows its tile; `null` for
  /// viewport-level stages (`labels.paint`) and worker-side spans.
  final String? tile;

  /// Rendering attempt id (`<runtimeId>a<n>`), or `null` when the stage
  /// predates attempt assignment (for example the fetch stage, which the
  /// tile manager runs per job before any decode starts).
  final String? attempt;

  /// Resolved source tile `z/x/y` (after over-zoom), for stages that know
  /// which source tile feeds the work (`fetch`, `parseWait`, …).
  final String? source;

  /// Microseconds on the recorder's monotonic clock, which starts at first
  /// use and is only meaningful within one process lifetime.
  final int startUs;

  final int durationUs;

  @override
  String toString() =>
      'VectorSpan($event${tile == null ? '' : ' @$tile'},'
      '${attempt == null ? '' : ' attempt=$attempt'}'
      '${source == null ? '' : ' src=$source'}'
      ' $durationUsµs @+$startUsµs)';
}

/// Opt-in in-process record of vector-pipeline spans, enabled with
/// `--dart-define=fosm.vectorSpans=true`.
///
/// Unlike [VectorTrace]'s Timeline events (DevTools captures, worker
/// isolates included), the span log stays on the main isolate and can be
/// drained per scenario by workload harnesses: `clear()` when a window is
/// armed, [take] when it ends. Bounds memory to [capacity] spans; once
/// full, the oldest half is dropped and counted in [dropped].
///
/// Span timing includes the Timeline instrumentation itself when
/// `fosm.traceVector` is also enabled — user-visible frame comparisons
/// must be captured with both defines off.
class VectorSpanLog {
  VectorSpanLog._();

  /// Compile-time value of the environment define. `fromEnvironment`
  /// constructors only see `--dart-define` values inside const contexts,
  /// so the define is captured here and the mutable flag initializes from
  /// it (tests and the MVT worker override the flag at runtime).
  static const bool enabledByDefine = bool.fromEnvironment('fosm.vectorSpans');

  /// Whether spans are recorded: the compile-time define, mutable so tests
  /// can exercise the recorder and the MVT worker can disable its own
  /// undrained copy.
  static bool enabled = enabledByDefine;

  /// Maximum retained spans; the log trims its oldest half beyond this.
  static const int capacity = 200000;

  static final List<VectorSpan> _spans = <VectorSpan>[];
  static int _dropped = 0;

  static final Stopwatch _clock = Stopwatch()..start();

  /// Spans currently retained.
  static int get length => _spans.length;

  /// Spans dropped by the capacity bound.
  static int get dropped => _dropped;

  /// Microseconds on the log's monotonic clock.
  static int nowUs() => _clock.elapsedMicroseconds;

  /// Removes every span (and the drop count and pending attempt notes) —
  /// call when arming a measurement window.
  static void clear() {
    _spans.clear();
    _dropped = 0;
    _decodeAttempts.clear();
  }

  /// Snapshot of the retained spans. The log keeps its contents.
  static List<VectorSpan> take() => List<VectorSpan>.of(_spans);

  /// Records a span that ran for [durationUs] starting at [startUs]
  /// (both on the [nowUs] clock); a no-op when disabled.
  static void record(String event, String? tile, int startUs, int durationUs,
      {String? attempt, String? source}) {
    if (!enabled) return;
    if (_spans.length >= capacity) {
      final removed = _spans.length >> 1;
      _spans.removeRange(0, removed);
      _dropped += removed;
    }
    _spans.add(VectorSpan(event, tile, startUs, durationUs,
        attempt: attempt, source: source));
  }

  /// Records a zero-duration marker (for example `staleAbort`, `publish`)
  /// so its timestamp can be correlated with neighbouring spans.
  static void mark(String event,
      {String? tile, String? attempt, String? source}) {
    if (!enabled) return;
    record(event, tile, _clock.elapsedMicroseconds, 0,
        attempt: attempt, source: source);
  }

  // ── Attempt ↔ publication correlation ─────────────────────────────
  //
  // The vector runtime assigns attempt ids, but publication happens in
  // the tile manager after the decode future resolves — across an API
  // boundary that cannot carry the id. The runtime notes the attempt of
  // each completed decode keyed by logical tile; the tile manager claims
  // it when the same tile is published into the grid. Jobs are unique per
  // tile key, so a second decode for the same tile overwrites its note
  // before that tile can publish again — the claimed attempt is always
  // the decode whose image is being placed.

  static final Map<String, String> _decodeAttempts = {};

  /// Records [attempt] as the most recent completed decode of [tile].
  static void noteDecodeAttempt(String tile, String attempt) {
    if (!enabled) return;
    if (_decodeAttempts.length >= 4096) {
      _decodeAttempts.remove(_decodeAttempts.keys.first);
    }
    _decodeAttempts[tile] = attempt;
  }

  /// Removes and returns the most recent completed decode attempt of
  /// [tile], or `null` when none was noted (raster tiles, or a decode
  /// that never reached publication).
  static String? claimDecodeAttempt(String tile) =>
      _decodeAttempts.remove(tile);
}

/// Opt-in spans for DevTools/VM timeline captures. Enable in profile builds
/// with `--dart-define=fosm.traceVector=true`. Disabled calls run directly;
/// no timers, event payloads or timeline tasks are allocated.
///
/// When [VectorSpanLog.enabled] is set, spans additionally land in the
/// in-process span log, tagged with the logical tile, rendering attempt
/// and resolved source tile when the call site knows them, so per-stage
/// work can be correlated per attempt by workload harnesses.
class VectorTrace {
  static const enabled = bool.fromEnvironment('fosm.traceVector');

  /// Whether any instrumentation (Timeline events or the span log) is
  /// active — guards at call sites that would otherwise skip wrapping.
  static bool get tracing => enabled || VectorSpanLog.enabled;

  /// Whether fine-grained sync spans (`recordChunk.*`, `style`,
  /// `geometry`, `dash`) are recorded. They flood the VM timeline ring at
  /// tens of thousands of events per run, which can evict coarse stages
  /// from long captures — the trace arm disables them
  /// (`fosm.vectorTraceChunks=false`) and reads fine-grained CPU from the
  /// profiler instead; the spans arm keeps them.
  static const chunks =
      bool.fromEnvironment('fosm.vectorTraceChunks', defaultValue: true);

  /// Whether synchronous stage spans should be emitted at all.
  static bool get syncSpans => tracing && chunks;

  static T sync<T>(String name, T Function() work,
      {String? tile, String? attempt, String? source}) {
    final record = VectorSpanLog.enabled;
    if (!record) {
      return enabled
          ? developer.Timeline.timeSync('fosm.vector.$name', work,
              arguments: _arguments(tile: tile, attempt: attempt, source: source))
          : work();
    }
    final clock = Stopwatch()..start();
    try {
      return enabled
          ? developer.Timeline.timeSync('fosm.vector.$name', work,
              arguments: _arguments(tile: tile, attempt: attempt, source: source))
          : work();
    } finally {
      VectorSpanLog.record(
          name, tile, VectorSpanLog.nowUs() - clock.elapsedMicroseconds,
          clock.elapsedMicroseconds,
          attempt: attempt, source: source);
    }
  }

  static Future<T> async<T>(String name, Future<T> Function() work,
      {String? tile, String? attempt, String? source}) {
    final record = VectorSpanLog.enabled;
    if (!record && !enabled) return work();
    return _tracedAsync(name, work,
        tile: tile, attempt: attempt, source: source, record: record);
  }

  static Future<T> _tracedAsync<T>(String name, Future<T> Function() work,
      {String? tile,
      String? attempt,
      String? source,
      required bool record}) async {
    final startUs = VectorSpanLog.nowUs();
    if (!enabled) {
      try {
        return await work();
      } finally {
        if (record) {
          VectorSpanLog.record(name, tile, startUs, VectorSpanLog.nowUs() - startUs,
              attempt: attempt, source: source);
        }
      }
    }
    final task = developer.TimelineTask()
      ..start('fosm.vector.$name',
          arguments: _arguments(
              tile: tile, attempt: attempt, source: source));
    try {
      return await work();
    } finally {
      task.finish();
      if (record) {
        VectorSpanLog.record(name, tile, startUs, VectorSpanLog.nowUs() - startUs,
            attempt: attempt, source: source);
      }
    }
  }

  /// Timeline event arguments carrying the correlation identity (tile,
  /// attempt, source) so DevTools captures correlate exactly like the
  /// span log. `null` when nothing is known — no empty argument maps.
  static Map<String, String>? _arguments(
      {String? tile, String? attempt, String? source}) {
    if (tile == null && attempt == null && source == null) return null;
    return {
      if (tile != null) 'tile': tile,
      if (attempt != null) 'attempt': attempt,
      if (source != null) 'source': source,
    };
  }
}
