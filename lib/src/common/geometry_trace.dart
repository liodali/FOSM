import 'dart:developer' as developer;

/// Opt-in spans for DevTools/VM timeline captures. Enable in profile builds
/// with `--dart-define=fosm.traceGeometry=true`. Disabled calls run directly;
/// no timers, event payloads or timeline tasks are allocated.
///
/// Stages (the profiling split the geometry performance plan asks for):
/// - `fosm.geometry.project` — lat/lng → screen projection of route/area
///   vertices (cached world coordinates → affine screen points).
/// - `fosm.geometry.path`    — Path construction, including solid-path
///   viewport culling, dash extraction and dotted center sampling.
/// - `fosm.geometry.paint`   — Canvas draw calls (strokes, fills, circles).
/// - `fosm.geometry.hit`     — tap/long-press hit testing over routes and
///   areas (bounds rejection, segment queries, exact distance tests).
///
/// The spans are per-shape; summing each stage over a capture attributes
/// projection, path construction, painting and selection costs separately.
class GeometryTrace {
  static const enabled = bool.fromEnvironment('fosm.traceGeometry');

  static T sync<T>(String name, T Function() work) {
    if (!enabled) return work();
    return developer.Timeline.timeSync('fosm.geometry.$name', work);
  }
}
