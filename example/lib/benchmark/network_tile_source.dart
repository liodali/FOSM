import 'package:fosm/fosm.dart' show TileFetcher;

// Simulated network conditions for the profile benchmark. The generated
// raster tiles resolve instantly from memory; wrapping the fetcher adds
// the latency, bandwidth and failure shape of a real uplink so cold-load
// scenarios measure the loading pipeline rather than infinite bandwidth.
//
// Each request waits independently (real networks parallelise; the tile
// manager already bounds fetch concurrency), serving the upstream bytes
// after a fixed RTT plus a size-based transfer time.

/// Wraps a [TileFetcher] with simulated network conditions and counts
/// traffic so results can attribute request volume per scenario.
class SimulatedNetwork {
  SimulatedNetwork({
    this.delayMs = 0,
    this.kbps = 0,
    this.dropEvery = 0,
  });

  /// Fixed per-request latency (RTT) in milliseconds.
  final int delayMs;

  /// Simulated bandwidth in kilobits per second; 0 disables shaping and
  /// serves at memory speed after [delayMs].
  final int kbps;

  /// When non-zero, every Nth request fails once (the error/retry path).
  final int dropEvery;

  /// Total requests served or failed since the last [reset].
  int requests = 0;
  int failures = 0;
  int bytesServed = 0;
  int _sequence = 0;

  /// True when no condition is active and wrapping is pointless.
  bool get inert => delayMs <= 0 && kbps <= 0 && dropEvery <= 0;

  void reset() {
    requests = 0;
    failures = 0;
    bytesServed = 0;
    _sequence = 0;
  }

  Map<String, Object> describe() => {
        'delayMs': delayMs,
        'kbps': kbps,
        'dropEvery': dropEvery,
      };

  Map<String, Object> stats() => {
        'requests': requests,
        'failures': failures,
        'bytesServed': bytesServed,
      };

  TileFetcher wrap(TileFetcher upstream) => inert
      ? upstream
      : (z, x, y) async {
          final sequence = ++_sequence;
          requests++;
          if (dropEvery > 0 && sequence % dropEvery == 0) {
            failures++;
            throw Exception('simulated network failure ($z/$x/$y)');
          }
          if (delayMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: delayMs));
          }
          final bytes = await upstream(z, x, y);
          if (kbps > 0) {
            // kbps → bytes per millisecond: kbps * 1000 / 8 / 1000.
            final transferMs = (bytes.length * 8 / kbps).ceil();
            if (transferMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: transferMs));
            }
          }
          bytesServed += bytes.length;
          return bytes;
        };
}
