import 'dart:developer' as developer;

/// Opt-in spans for DevTools/VM timeline captures. Enable in profile builds
/// with `--dart-define=fosm.traceMarkers=true`. Disabled calls run directly;
/// no timers, event payloads or timeline tasks are allocated.
///
/// Stages (mirrors the profiling split the performance plan asks for):
/// - `fosm.markers.build`   — whole marker-layer build (widget build).
/// - `fosm.markers.query`   — collection scan: viewport rect → index query.
/// - `fosm.markers.project` — world → screen projection of query results.
/// - `fosm.markers.cluster` — clustering engine run (zoom/mutation misses).
///
/// Widget layout and hit testing happen inside Flutter's pipeline after
/// `build`; measure them from the surrounding frame span.
class MarkerTrace {
  static const enabled = bool.fromEnvironment('fosm.traceMarkers');

  static T sync<T>(String name, T Function() work) {
    if (!enabled) return work();
    return developer.Timeline.timeSync('fosm.markers.$name', work);
  }
}
