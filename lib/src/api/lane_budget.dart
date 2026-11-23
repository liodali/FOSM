import 'dart:collection';
import 'dart:math' as math;

/// Sizes the network load lanes from what the link actually delivers.
///
/// A fixed lane width cannot suit every link. With spare bandwidth a wide lane
/// hides round trips (a cold pinch fetches its new cells in one wave instead
/// of several). When bandwidth is the limit, concurrent requests split the
/// rate, so a wide lane delivers every tile late and together and the extra
/// bytes of idle work compete with the tiles the user is waiting for (Galaxy
/// A33 at 2 and 8 Mbit/s: 12 wide lanes were 20 to 100 % slower to clear the
/// stale area than 6 and 2 wide ones).
///
/// The width worth running is the link's bandwidth-delay product measured in
/// tiles, `C * L / s`: the bytes that fit in the pipe while one request waits
/// for its first byte, divided by the size of a tile. Anything wider only
/// queues. The budget estimates the three inputs from finished fetches:
///
/// * `C`, the delivery rate: bytes completed over a trailing window of the
///   current busy period, kept as a windowed maximum so a lull in demand does
///   not read as a slow link;
/// * `L`, the latency to the first byte, as a windowed minimum. Measured to
///   the response headers, so the body's transfer time (which grows with the
///   number of requests sharing the link) does not inflate it;
/// * `s`, the mean size of non-empty tiles.
///
/// The total width asked for is `gain * C * L / s + 1`. A gain above one keeps
/// probing: if more requests deliver more bytes, `C` rises and the width
/// follows, so a latency bound link climbs to the configured maximum within a
/// few round trips while a bandwidth bound link settles at two to four.
///
/// The link belongs to the process, not to one map, so every vector map shares
/// one budget (`MapView`): a map opened after another starts with what the
/// link already showed instead of re-learning it from a cold first wave.
///
/// Pure arithmetic over caller supplied microsecond timestamps, so it is
/// deterministic to test and owns no timers.
class LaneBudget {
  LaneBudget({
    this.foregroundMax = 12,
    this.backgroundMax = 12,
    this.minimumWidth = 3,
    this.initialWidth = 6,
    this.initialBackgroundWidth = 2,
    this.gain = 1.5,
    this.rateWindowUs = 8000000,
    this.filterWindowUs = 60000000,
    this.minimumRateSpanUs = 200000,
  })  : assert(minimumWidth >= 1),
        assert(foregroundMax >= minimumWidth),
        assert(backgroundMax >= 1),
        assert(gain > 1);

  /// Upper bound of the foreground lane.
  final int foregroundMax;

  /// Upper bound of the background lane.
  final int backgroundMax;

  /// Foreground lane floor: below this a lane stops being a pipeline.
  final int minimumWidth;

  /// Width used while there is nothing to estimate from (the first fetches of
  /// a process, or a quiet minute): the fixed width this replaces, so a cold
  /// start is never worse than before. A first wave on a slow link shares the
  /// link until it completes (about four seconds at 8 requests and 2 Mbit/s),
  /// and the estimate cannot improve before then, so this stays low and the
  /// gain probes upward.
  final int initialWidth;

  /// Background width until the link has been measured: the fixed width this
  /// replaces. Idle prefetch only widens once the estimate shows spare
  /// capacity, so a cold start never has a dozen speculative requests sharing
  /// the link with the first tiles the user asked for (Galaxy A33 at
  /// 2 Mbit/s: a cold zoom step ran 27 % behind the old lanes with a
  /// background width of 6).
  final int initialBackgroundWidth;

  /// Probing factor over the measured bandwidth-delay product.
  final double gain;

  /// Trailing window of the delivery-rate sample, in microseconds.
  final int rateWindowUs;

  /// Window of the maximum-rate and minimum-latency filters, in microseconds.
  final int filterWindowUs;

  /// A rate sample needs at least this much elapsed time to mean anything.
  final int minimumRateSpanUs;

  /// Test and measurement hook: receives one line per finished fetch with
  /// what the budget currently believes. Null in production.
  static void Function(String line)? debugSink;

  int _inFlight = 0;
  int _busyStartUs = 0;
  int _lastUs = 0;
  double? _meanBytes;
  final Queue<(int, int)> _finished = Queue(); // (end time, bytes)
  final Queue<(int, double)> _rates = Queue(); // (time, bytes per microsecond)
  final Queue<(int, int)> _latencies = Queue(); // (time, first byte delay)

  /// Requests currently counted as in flight.
  int get inFlight => _inFlight;

  /// Records that a network request started at [nowUs].
  void fetchStarted(int nowUs) {
    nowUs = _monotonic(nowUs);
    if (_inFlight == 0) _busyStartUs = nowUs;
    _inFlight++;
  }

  /// Every caller must share one clock. A timestamp that goes backwards would
  /// shrink a time span and inflate the rate, so it is held at the latest one
  /// seen instead.
  int _monotonic(int nowUs) {
    if (nowUs < _lastUs) return _lastUs;
    return _lastUs = nowUs;
  }

  /// Records a request that ended without a usable response (error, timeout,
  /// cancellation). It says nothing about the link.
  void fetchAbandoned() {
    if (_inFlight > 0) _inFlight--;
  }

  /// Records a completed request: [bytes] delivered by [nowUs], whose first
  /// byte (response headers) arrived [firstByteUs] after the request started.
  void fetchFinished(int nowUs, {required int bytes, int? firstByteUs}) {
    nowUs = _monotonic(nowUs);
    if (_inFlight > 0) _inFlight--;
    _finished.addLast((nowUs, bytes));
    if (bytes > 0) {
      final mean = _meanBytes;
      _meanBytes = mean == null ? bytes.toDouble() : mean * 0.8 + bytes * 0.2;
    }
    if (firstByteUs != null && firstByteUs > 0) {
      _latencies.addLast((nowUs, firstByteUs));
    }
    _prune(nowUs);
    // Rate over the trailing window, clipped to the current busy period so an
    // idle gap does not dilute it and a ramp up is not over counted.
    final windowStart = math.max(nowUs - rateWindowUs, _busyStartUs);
    final span = nowUs - windowStart;
    if (span < minimumRateSpanUs) return;
    var sum = 0;
    for (final (end, size) in _finished) {
      if (end > windowStart) sum += size;
    }
    _rates.addLast((nowUs, sum / span));
    final sink = debugSink;
    if (sink != null) sink(debugSnapshot(nowUs, bytes, firstByteUs));
  }

  /// One line describing the current estimate, for [debugSink].
  String debugSnapshot(int nowUs, int bytes, int? firstByteUs) {
    var rate = 0.0;
    for (final (_, r) in _rates) {
      if (r > rate) rate = r;
    }
    int? latency;
    for (final (_, l) in _latencies) {
      if (latency == null || l < latency) latency = l;
    }
    return 't=${(nowUs / 1000).round()}ms inflight=$_inFlight '
        'bytes=$bytes ttfb=${firstByteUs == null ? '-' : (firstByteUs / 1000).round()}ms '
        'C=${(rate * 1000).round()}KB/s L=${latency == null ? '-' : (latency / 1000).round()}ms '
        's=${((_meanBytes ?? 0) / 1000).round()}KB total=$totalWidth '
        'fg=$foregroundLimit';
  }

  void _prune(int nowUs) {
    final floor = nowUs - filterWindowUs;
    while (_finished.isNotEmpty && _finished.first.$1 <= floor) {
      _finished.removeFirst();
    }
    while (_rates.isNotEmpty && _rates.first.$1 <= floor) {
      _rates.removeFirst();
    }
    while (_latencies.isNotEmpty && _latencies.first.$1 <= floor) {
      _latencies.removeFirst();
    }
  }

  /// Whether the link has been measured (enough finished fetches to estimate
  /// the delivery rate, the first-byte latency and the tile size).
  bool get hasEstimate {
    if (_meanBytes == null || _rates.isEmpty || _latencies.isEmpty) return false;
    return _meanBytes! > 0;
  }

  /// Total requests the link can usefully keep in flight, or [initialWidth]
  /// while there is not enough history to say.
  int get totalWidth {
    var rate = 0.0;
    for (final (_, r) in _rates) {
      if (r > rate) rate = r;
    }
    int? latency;
    for (final (_, l) in _latencies) {
      if (latency == null || l < latency) latency = l;
    }
    final size = _meanBytes;
    if (rate <= 0 || latency == null || size == null || size <= 0) {
      return initialWidth;
    }
    final tiles = rate * latency / size;
    return (gain * tiles).ceil() + 1;
  }

  /// Foreground lane width.
  int get foregroundLimit => totalWidth.clamp(minimumWidth, foregroundMax);

  /// Background lane width given [activeForeground] foreground requests in
  /// flight: idle work uses the whole pipe, but while visible tiles are loading
  /// it only gets what they leave (at least one request, so a gesture's
  /// prefetch is never starved).
  int backgroundLimit({required int activeForeground}) {
    if (!hasEstimate) return initialBackgroundWidth.clamp(1, backgroundMax);
    final room = activeForeground <= 0
        ? totalWidth
        : math.max(1, totalWidth - activeForeground);
    return room.clamp(1, backgroundMax);
  }
}
