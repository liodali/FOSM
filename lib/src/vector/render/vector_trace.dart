import 'dart:developer' as developer;

/// Opt-in spans for DevTools/VM timeline captures. Enable in profile builds
/// with `--dart-define=fosm.traceVector=true`. Disabled calls run directly;
/// no timers, event payloads or timeline tasks are allocated.
class VectorTrace {
  static const enabled = bool.fromEnvironment('fosm.traceVector');

  static T sync<T>(String name, T Function() work) {
    if (!enabled) return work();
    return developer.Timeline.timeSync('fosm.vector.$name', work);
  }

  static Future<T> async<T>(String name, Future<T> Function() work) {
    if (!enabled) return work();
    return _tracedAsync(name, work);
  }

  static Future<T> _tracedAsync<T>(
      String name, Future<T> Function() work) async {
    final task = developer.TimelineTask()..start('fosm.vector.$name');
    try {
      return await work();
    } finally {
      task.finish();
    }
  }
}
