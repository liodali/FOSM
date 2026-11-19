// Vector-render baseline benchmark (plan-01 baseline & attribution).
// See .plan/vector_render_improvement/01_baseline_and_attribution.md and
// docs/performance/vector-render-improvement/README.md.
//
// Serves nothing itself: start tool/vector_payload_server.dart first and
// pass its base URL via BENCHMARK_VECTOR_BASE. Profile mode only:
//
//   flutter run --profile -t lib/benchmark/map_vector_benchmark.dart \
//     --dart-define=BENCHMARK_VECTOR_BASE=http://<server>:8787
//
// Scenarios fix payload (deterministic synthetic MVT), style, viewport,
// device and camera path; cache states are established explicitly:
//
//   coldBytes             unmount map → clear disk cache → arm → remount.
//                         First load frame is the first measured frame.
//   warmBytesColdParsed   unmount → arm → remount (no disk clear): fresh
//                         runtime (empty parsed/rendered caches), tiles
//                         re-read from disk bytes.
//   warmParsedColdImages  mounted, settled → arm → evict all rendered
//                        images including fallback/snapshot pins → reload
//                        the same viewport; parsed data/bytes stay warm.
//   warmRendered          mounted, settled (all caches warm) → arm.
//
// A raster control pair runs the same camera path through the raster
// pipeline against the same server so provider/transport differences are
// not attributed to vector rendering.
//
// Attribution: run with --dart-define=fosm.vectorSpans=true to emit
// FOSM_BENCHMARK_VECTOR_STAGES per scenario (per-event distributions and
// per-tile stage sums). Add fosm.traceVector=true for the DevTools
// timeline arm (worker isolate included); final user-visible numbers must
// come from a clean arm with both defines off.
//
// Payload markers go through print(), not debugPrint(): debugPrint
// word-wraps at ~1 KB, which splits kilobyte JSON payloads mid-string and
// breaks the line-oriented log parsers. print() is never wrapped.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fosm/fosm.dart';

import 'host_identity.dart';
import 'payload_out.dart';
import 'process_memory.dart';
import 'vector_payloads.dart';
import 'vector_stage_report.dart';
import 'benchmark_report.dart'
    show coverageMeanOverWindow, coverageThresholdTimings;

const _encodedRunLabel =
    String.fromEnvironment('BENCHMARK_LABEL', defaultValue: '');

/// Run label: the dart-define on native runs, or the `?label=` query
/// parameter on the web build (one build serves several reps by URL).
final String _runLabel = _encodedRunLabel.isNotEmpty
    ? _encodedRunLabel
    : (Uri.base.queryParameters['label'] ?? 'web-baseline');

/// Base URL of the payload server (scheme + host + port only; never a
/// credential-bearing URL — the trace/report payloads exclude it too).
const _base = String.fromEnvironment('BENCHMARK_VECTOR_BASE',
    defaultValue: 'http://127.0.0.1:8787');

const _profileName = String.fromEnvironment('BENCHMARK_VECTOR_PROFILE',
    defaultValue: 'denseCity');

const _seed = int.fromEnvironment('BENCHMARK_VECTOR_SEED',
    defaultValue: BenchPayloads.defaultSeed);

const _payloadIdentity = String.fromEnvironment('BENCHMARK_PAYLOAD_IDENTITY',
    defaultValue: BenchPayloads.identity);

const _sampleSeconds =
    int.fromEnvironment('BENCHMARK_SAMPLE_SECONDS', defaultValue: 10);

/// Optional exact scenario name for short, paired candidate captures.
const _scenarioFilter = String.fromEnvironment('BENCHMARK_SCENARIO');

/// `BENCHMARK_SCENARIO` may list several exact names, comma-separated.
final _scenarioFilterNames =
    _scenarioFilter.isEmpty ? const <String>[] : _scenarioFilter.split(',');

/// Upper bound for the settle phase that establishes warm cache states.
const _settleSeconds =
    int.fromEnvironment('BENCHMARK_SETTLE_SECONDS', defaultValue: 25);

final _center = LatLng(
  latitude: double.parse(
      const String.fromEnvironment('BENCHMARK_LATITUDE', defaultValue: '47')),
  longitude: double.parse(
      const String.fromEnvironment('BENCHMARK_LONGITUDE', defaultValue: '8')),
);

/// Camera-motion family used while sampling.
enum _Motion { none, fling, pinch, pinchPan, returnPan, returnFrom }

/// How each scenario's cache state is established (see file comment).
enum _CacheState {
  coldBytes,
  warmBytesColdParsed,
  warmParsedColdImages,
  warmRendered
}

enum _Source { vector, raster }

class _Scenario {
  final String name;
  final _Motion motion;
  final _CacheState cacheState;
  final _Source source;
  final int startZoom;

  /// Switch the style variant a→b at half the sample window (measures a
  /// full runtime/style reload on identical payloads).
  final bool styleSwitch;

  /// Recorded camera-idle tail after the motion window. Motion previews
  /// have 200 ms to stop, then full-resolution upgrades race this tail;
  /// zero preserves the historical continuously-moving protocol.
  final int motionSettleMs;

  /// Zoom-step protocol (adjacent-zoom preload A/B): cold bytes are cleared,
  /// the map mounts and settles at [startZoom], idles [idleBeforeMs] (the
  /// preload debounce plus background fetches run), then the window is armed
  /// and the camera jumps [zoomStep] levels (positive = in). Time-to-sharp
  /// of the new zoom is the measurement. 0 keeps the historical protocols.
  final int zoomStep;
  final int idleBeforeMs;

  /// With [zoomStep] != 0 and [legHoldMs] > 0, the window records a second
  /// leg: after holding the stepped zoom for [legHoldMs] the camera jumps
  /// back to [startZoom], measuring zoom-reversal reuse (plan 13). The
  /// hold must exceed the rendered cache's 20 s inactive retention for
  /// the `_expired` variants to measure expiry misses rather than reuse.
  final int legHoldMs;

  /// Animated controller zoom executed right after arming (levels,
  /// positive = in). Exercises the animated-zoom overlay/reveal path with
  /// whatever cache state the scenario establishes.
  final int animatedZoom;

  /// With [zoomStep] != 0: pan this fraction of a tile after arming, idle
  /// briefly (the prepared window re-predicts around the panned center;
  /// the baseline's byte preload re-debounces), then jump [zoomStep]
  /// levels. Measures pan-then-zoom reveal — plan-13 Phase E A/B.
  final double panTilesBeforeZoom;

  /// Mount the map WITHOUT continuous zoom, so controller zooms route
  /// through the integer snapshot-overlay animation
  /// (`_startZoomAnimation`) instead of the fractional tween. The
  /// fractional variants exercise the continuous path; both must be
  /// captured before claiming the animated paths are covered
  /// (plan-13 review P2).
  final bool integerZoom;

  /// Per-scenario window length override; 0 uses the global
  /// `BENCHMARK_SAMPLE_SECONDS` default. Two-leg cycle windows need more
  /// than the default 10 s.
  final int sampleSeconds;

  const _Scenario(
    this.name, {
    this.motion = _Motion.none,
    this.cacheState = _CacheState.coldBytes,
    this.source = _Source.vector,
    this.startZoom = 10,
    this.styleSwitch = false,
    this.motionSettleMs = 0,
    this.zoomStep = 0,
    this.idleBeforeMs = 0,
    this.legHoldMs = 0,
    this.animatedZoom = 0,
    this.integerZoom = false,
    this.panTilesBeforeZoom = 0,
    this.sampleSeconds = 0,
  });

  /// Effective recorded-window length for this scenario.
  int get windowSeconds => sampleSeconds > 0 ? sampleSeconds : _sampleSeconds;
}

const _scenarios = [
  // Raster control: same camera paths through the raster pipeline.
  _Scenario('raster_control_static', source: _Source.raster),
  _Scenario('raster_control_fling',
      source: _Source.raster, motion: _Motion.fling),
  // Cold bytes: full pipeline from network bytes.
  _Scenario('vector_cold_static'),
  _Scenario('vector_cold_fling', motion: _Motion.fling),
  _Scenario('vector_cold_return', motion: _Motion.returnPan),
  _Scenario('vector_cold_pinch', motion: _Motion.pinch),
  // Recorded 3s idle tails: motion previews stop at 200ms and upgrade to
  // full-resolution while coverage sampling remains active.
  _Scenario('vector_cold_fling_settle',
      motion: _Motion.fling, motionSettleMs: 3000),
  _Scenario('vector_cold_return_settle',
      motion: _Motion.returnPan, motionSettleMs: 3000),
  _Scenario('vector_cold_pinch_settle',
      motion: _Motion.pinch, motionSettleMs: 3000),
  _Scenario('vector_cold_overzoom', startZoom: 16),
  // Zoom steps after an idle period (adjacent-zoom byte preload A/B; pair
  // with the payload server's --delay-ms to model network latency).
  _Scenario('vector_zoomstep_in1', zoomStep: 1, idleBeforeMs: 4000),
  _Scenario('vector_zoomstep_in2', zoomStep: 2, idleBeforeMs: 4000),
  _Scenario('vector_zoomstep_out2', zoomStep: -2, idleBeforeMs: 4000),
  // Zoom round trips (plan 13 Phase A): jump out, hold past the settle,
  // jump back — leg 2 measures retained-image reuse on reversal. The
  // hold is 15 s: long enough for leg 1's production to complete (the
  // review found z11 production outlasts a 5 s hold, which made leg 1
  // report null) while staying inside the 20 s inactive-image retention
  // so leg 2 still measures reuse rather than expiry.
  _Scenario('vector_zoomcycle_in1',
      zoomStep: 1, idleBeforeMs: 4000, legHoldMs: 15000, sampleSeconds: 30),
  _Scenario('vector_zoomcycle_out1',
      zoomStep: -1, idleBeforeMs: 4000, legHoldMs: 15000, sampleSeconds: 30),
  // Same round trips after the 20 s inactive-image retention has expired
  // everything: leg 2 measures the full reproduction path.
  _Scenario('vector_zoomcycle_in1_expired',
      zoomStep: 1, idleBeforeMs: 4000, legHoldMs: 22000, sampleSeconds: 40),
  _Scenario('vector_zoomcycle_out1_expired',
      zoomStep: -1, idleBeforeMs: 4000, legHoldMs: 22000, sampleSeconds: 40),
  // Pan-then-zoom (plan 13 Phase E A/B): arm, pan a fraction of a tile,
  // idle briefly (the candidate's prepared window re-predicts around the
  // panned center; the baseline's byte preload re-debounces), then zoom
  // in and measure the reveal. Holds, then jumps back (reversal).
  _Scenario('vector_pan_then_zoom',
      zoomStep: 1,
      panTilesBeforeZoom: 0.25,
      idleBeforeMs: 4000,
      legHoldMs: 8000,
      sampleSeconds: 25),
  // Warm rendered: motion tails without any loading cost.
  _Scenario('vector_warm_static', cacheState: _CacheState.warmRendered),
  _Scenario('vector_warm_fling',
      cacheState: _CacheState.warmRendered, motion: _Motion.fling),
  // Warm fractional pinch (plan 13 Phase B control: the retained grid
  // layer recaptures every frame while the tile scale changes).
  _Scenario('vector_warm_pinch',
      cacheState: _CacheState.warmRendered, motion: _Motion.pinch),
  // Combined pinch + pan around an off-center focal point.
  _Scenario('vector_warm_pinch_pan',
      cacheState: _CacheState.warmRendered, motion: _Motion.pinchPan),
  // Animated controller zoom with warm caches. The fractional variants
  // run the continuous tween; the `_int_` variants mount without
  // continuous zoom so controller zooms take the integer snapshot-overlay
  // animation — both paths, captured separately (plan-13 review).
  _Scenario('vector_warm_animated_zoom_frac_in',
      cacheState: _CacheState.warmRendered, animatedZoom: 1),
  _Scenario('vector_warm_animated_zoom_frac_out',
      cacheState: _CacheState.warmRendered, animatedZoom: -1),
  _Scenario('vector_warm_animated_zoom_int_in',
      cacheState: _CacheState.warmRendered,
      animatedZoom: 1,
      integerZoom: true),
  _Scenario('vector_warm_animated_zoom_int_out',
      cacheState: _CacheState.warmRendered,
      animatedZoom: -1,
      integerZoom: true),
  // Warm bytes, fresh runtime: disk-hit loads with cold parsed data.
  _Scenario('vector_warm_bytes_static',
      cacheState: _CacheState.warmBytesColdParsed),
  // Warm parsed, cold images: reload the settled viewport after arming.
  _Scenario('vector_warm_parsed_static',
      cacheState: _CacheState.warmParsedColdImages),
  // Style reload cost with warm disk bytes.
  _Scenario('vector_style_switch',
      cacheState: _CacheState.warmRendered, styleSwitch: true),
];

// Fling parameters (identical to map_benchmark.dart so the camera paths
// stay comparable across harnesses).
const _flingTauSeconds = 0.32;
const _flingSegmentSeconds = 1.6;
const _flingV0DegPerSec = 3.0;
final _flingMaxTravelDeg = _flingV0DegPerSec *
    _flingTauSeconds *
    (1 - math.exp(-_flingSegmentSeconds / _flingTauSeconds));

// Pinch-reversal cadence (identical to map_benchmark.dart).
const _pinchPeriodSeconds = 1.5;
const _pinchAmplitudeLevels = 0.75;

/// Off-center focal point for the pinch+pan motion: longitude/latitude of
/// the geographic point the gesture keeps anchored, ~1.4 tiles east and
/// half a tile north of the center at z10 (one z10 tile ≈ 0.35° lng).
const _pinchFocalLngOffset = 0.5;
const _pinchFocalLatOffset = 0.18;
double get _pinchFocalLng => _center.longitude + _pinchFocalLngOffset;
double get _pinchFocalLat => _center.latitude + _pinchFocalLatOffset;

/// Return-pan amplitude: ~1.4 tiles east at z10, away and back.
const _returnPanAmplitudeDeg = 0.5;
const _returnPanPeriodSeconds = 3.0;

/// One-shot return distance for the warm-parsed scenario: far enough that
/// the origin viewport leaves the aside grid (and its zoom-fallback pins —
/// pinned imagery survives cache flushes, which would otherwise let the
/// return reuse warm images), close enough that the parsed-tile LRU still
/// holds most shared source tiles.
const _returnFromOffsetDeg = 0.88;
const _returnFromSeconds = 6.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web captures cannot rely on `--start-paused` (the DWDS debug
  // extension never connects on a plain launch), so browser runs give
  // the capture tool time to attach by delaying the run: the capture
  // script passes BENCHMARK_ATTACH_DELAY_MS. Native captures start
  // paused and resume over the service protocol.
  const attachDelayMs =
      int.fromEnvironment('BENCHMARK_ATTACH_DELAY_MS', defaultValue: 0);
  if (attachDelayMs > 0) {
    await Future<void>.delayed(Duration(milliseconds: attachDelayMs));
  }
  // Canary for web captures: land in the sink before [initMap], because
  // a hang there otherwise looks identical to a page never running.
  const encodedSink = String.fromEnvironment('BENCHMARK_MARKER_URL');
  if (encodedSink.isNotEmpty) {
    unawaited(Dio().post<void>(
      encodedSink,
      queryParameters: {'label': _runLabel},
      data: 'FOSM_BENCHMARK_ENTRY main-entered',
    ));
  }
  if (!kProfileMode) throw StateError('Run this benchmark with --profile.');
  // Every unhandled app error becomes a marker payload: the browser
  // runs have no visible console (the capture reads the sink), so a
  // silent exception must reach the capture file to stay diagnosable.
  await runZonedGuarded(() async {
    await initMap();
    runApp(const MaterialApp(home: _VectorBenchmark()));
  }, (error, stack) {
    final sink = String.fromEnvironment('BENCHMARK_MARKER_URL');
    if (sink.isEmpty) return;
    unawaited(Dio().post<void>(
      sink,
      queryParameters: {'label': _runLabel},
      data: 'FOSM_BENCHMARK_RUN_ERROR $error\n$stack',
    ));
  });
}

class _VectorBenchmark extends StatefulWidget {
  const _VectorBenchmark();

  @override
  State<_VectorBenchmark> createState() => _VectorBenchmarkState();
}

/// Maximum bytes of one payload line. The device console relay truncates
/// longer lines around 1 KB (round-2 captures lost the tail of every
/// kilobyte payload), so payloads ride out in chunked continuation lines
/// that the log parsers reassemble.
const _payloadLineLimit = 900;

/// Emits `marker payload` as one line when it fits the safe line size,
/// or as continuation chunks otherwise:
///   `marker {first chunk}`
///   `FOSM_BENCHMARK_CHUNK {chunk} ...`
///   `FOSM_BENCHMARK_CHUNK_END`
/// Short markers (SCENARIO/SAMPLE_*/DONE) are below the limit and print
/// directly with [print], which is never wrapped.
void _payloadPrint(String marker, String payload) {
  if (payload.length <= _payloadLineLimit) {
    payloadOut('$marker $payload');
    return;
  }
  var offset = 0;
  while (offset < payload.length) {
    final end = math.min(offset + _payloadLineLimit, payload.length);
    payloadOut(
        '${offset == 0 ? '$marker ' : 'FOSM_BENCHMARK_CHUNK '}${payload.substring(offset, end)}');
    offset = end;
  }
  payloadOut('FOSM_BENCHMARK_CHUNK_END');
}

/// Emits one benchmark payload line: printed as chunk-safe console
/// lines and, when a marker sink URL is defined (browser captures),
/// POSTed whole to it — the chrome launch cannot relay app prints, and
/// the sink only appends, so ordering rides the awaited calls.
Future<void> _emitPayload(String marker, String payload) async {
  _payloadPrint(marker, payload);
  final sink = _markerSinkUrl;
  if (sink.isEmpty) return;
  try {
    await Dio().post<void>(sink,
        queryParameters: {'label': _runLabel}, data: '$marker $payload');
  } catch (_) {
    // Never fail the capture because of the sink; the console keeps
    // every line.
  }
}

/// Marker sink URL (browser captures): when set, every payload is also
/// POSTed there as one whole line, because the flutter_tools Chrome has
/// `--disable-extensions` and app prints cannot be relayed reliably.
/// Falls back to the `?sink=` query parameter so one web build serves
/// several reps with different sinks.
final String _markerSinkUrl = (() {
  final defined = const String.fromEnvironment('BENCHMARK_MARKER_URL');
  if (defined.isNotEmpty) return defined;
  return Uri.base.queryParameters['sink'] ?? '';
})();

class _VectorBenchmarkState extends State<_VectorBenchmark>
    with SingleTickerProviderStateMixin {
  final _controller = MapController();
  late final AnimationController _motion;
  final _timings = <ui.FrameTiming>[];
  bool _recording = false;
  _Scenario _scenario = _scenarios.first;

  /// Incremented whenever the map subtree must be recreated (cold and
  /// warm-bytes scenarios): a fresh runtime starts with empty parsed,
  /// rendered and in-memory byte caches.
  int _mapGeneration = 0;
  bool _mapMounted = true;
  double _motionSeconds = 1;

  /// Camera mode the currently mounted map was created with: switching
  /// continuous zoom on/off requires a fresh map state (widget
  /// parameter bound at mount).
  bool _mountedIntegerZoom = false;

  /// Style variant mounted into the map ('a' | 'b'); the style-switch
  /// scenario flips it mid-window.
  String _styleVariant = 'a';

  /// Camera pose the map mounts with; cold scenarios cannot use controller
  /// calls while unmounted, so the widget parameters carry the pose.
  int _startZoom = 10;
  Timer? _styleSwitchTimer;

  /// Per-frame rows while recording coverage scenarios:
  /// `[elapsedMs, coveredFraction, sharpFraction, labelTiles,
  /// labelCount, failedTiles, labelJobsOutstanding,
  /// coveredAreaFraction, sharpAreaFraction, labelReadyFraction]`.
  ///
  /// Measurement start (t=0) is the arming of the recording window — for
  /// cold scenarios that is the frame *before* the replacement map mounts,
  /// so its first load frame is the first measured frame. Samples whose
  /// grid is not laid out yet (`visibleCells == 0`) are skipped and
  /// counted in [_emptyGridFrames] rather than read as covered.
  final List<List<double>> _coverageSamples = [];
  Stopwatch? _coverageClock;
  double _coverageWindowMs = 0;
  int _emptyGridFrames = 0;

  /// First-seen and first-sharp timestamps per viewport cell id, for
  /// newly-exposed-region metrics during motion (cells first visible
  /// after the window's first sample).
  final Map<String, double> _cellFirstSeenMs = {};
  final Map<String, double> _cellSharpAtMs = {};

  /// Fraction of sharp visible cells whose tile's label preparation
  /// completed — tiles that prepared successfully with *zero* labels
  /// count as completed (`LabelOverlay.preparedTileKeys`), so a
  /// no-label tile is never mistaken for an unprepared one. 1.0 for an
  /// empty sharp set.
  double _labelReadyFraction(
      FosmTileCoverage coverage, Set<String> preparedKeys) {
    final sharp = coverage.sharpCellIds;
    if (sharp.isEmpty) return 1;
    var ready = 0;
    for (final cell in sharp) {
      // Cell ids are namespaced ('style/z/x/y'); label keys are plain.
      final plain = cell.substring(cell.indexOf('/') + 1);
      if (preparedKeys.contains(plain)) ready++;
    }
    return ready / sharp.length;
  }

  /// Peaks sampled per frame during the window (attribution buckets).
  int _peakRenderedBytes = 0;
  int _peakEstimatedTotalBytes = 0;
  int _peakParsedTiles = 0;
  int _peakPreparedLabels = 0;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this)..addListener(_move);
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  /// Emits a zero-work timeline marker at a recording boundary. These
  /// share the VM timeline clock with the `fosm.vector.*` pipeline
  /// events, so `tool/capture_benchmark.dart --timeline` can validate
  /// per-scenario capture coverage without any wall-clock alignment.
  void _timelineMark(String name) =>
      developer.Timeline.timeSync('fosm.benchmark.$name', () {});

  void _onTimings(List<ui.FrameTiming> frames) {
    if (!_recording) return;
    _timings.addAll(frames);
  }

  void _move() {
    final t = _motion.value * _motionSeconds;
    switch (_scenario.motion) {
      case _Motion.fling:
        _moveToFling(t);
      case _Motion.pinch:
        _controller.setFractionalZoom(
            _startZoom +
                _pinchAmplitudeLevels *
                    math.sin(t * 2 * math.pi / _pinchPeriodSeconds),
            animate: false);
      case _Motion.pinchPan:
        // Continuous zoom around an off-center focal point: the geographic
        // point under the focal stays fixed, so the camera center orbits
        // while the zoom oscillates — a combined pinch/pan gesture. The
        // focal sits ~1.4 tiles east, half a tile north of the center at
        // the start zoom.
        final delta = _pinchAmplitudeLevels *
            math.sin(t * 2 * math.pi / _pinchPeriodSeconds);
        final shrink = math.pow(2, -delta).toDouble();
        _controller.moveTo(
            LatLng(
              latitude: _pinchFocalLat +
                  (_center.latitude - _pinchFocalLat) * shrink,
              longitude: _pinchFocalLng +
                  (_center.longitude - _pinchFocalLng) * shrink,
            ),
            animate: false);
        _controller.setFractionalZoom(_startZoom + delta, animate: false);
      case _Motion.returnPan:
        final phase = 2 * math.pi * t / _returnPanPeriodSeconds;
        _controller.moveTo(
            LatLng(
                latitude: _center.latitude + 0.01 * math.sin(phase),
                longitude: _center.longitude +
                    _returnPanAmplitudeDeg * math.sin(phase)),
            animate: false);
      case _Motion.returnFrom:
        // Smoothstep from +offset back to the origin, then hold.
        final p = (t / _returnFromSeconds).clamp(0.0, 1.0);
        final eased = 1 - (p * p * (3 - 2 * p));
        _controller.moveTo(
            LatLng(
                latitude: _center.latitude,
                longitude: _center.longitude + _returnFromOffsetDeg * eased),
            animate: false);
      case _Motion.none:
        break;
    }
  }

  /// Alternating decaying pans, identical to map_benchmark.dart.
  void _moveToFling(double t) {
    final segment = (t / _flingSegmentSeconds).floor();
    final tSeg = t - segment * _flingSegmentSeconds;
    var longitude = _center.longitude;
    for (var i = 0; i < segment; i++) {
      longitude += (i.isEven ? 1.0 : -1.0) * _flingMaxTravelDeg;
    }
    longitude += (segment.isEven ? 1.0 : -1.0) *
        _flingV0DegPerSec *
        _flingTauSeconds *
        (1 - math.exp(-tSeg / _flingTauSeconds));
    final latitude = _center.latitude + 0.015 * math.sin(t * 1.1);
    _controller.moveTo(LatLng(latitude: latitude, longitude: longitude),
        animate: false);
  }

  Future<void> _drive(Duration duration) async {
    _motionSeconds = duration.inMicroseconds / 1e6;
    _motion.duration = duration;
    await _motion.forward(from: 0);
  }

  Future<void> _runWindow(Duration duration) async {
    switch (_scenario.motion) {
      case _Motion.none:
        await Future<void>.delayed(duration);
      default:
        await _drive(duration);
    }
  }

  /// Motion duration before a recorded settle tail. It stops on an exact
  /// motion-period boundary so pinch/return end back at the start zoom and
  /// fling ends at a segment boundary; otherwise a fractional endpoint can
  /// select a zoom absent from a bounded fixture and the tail measures
  /// fallback, not preview upgrade.
  Duration get _motionWindow {
    final settleMs = _scenario.motionSettleMs;
    if (settleMs == 0) return Duration(seconds: _scenario.windowSeconds);
    final sampleMs = _scenario.windowSeconds * 1000;
    switch (_scenario.motion) {
      case _Motion.pinch:
        final periods = sampleMs ~/ (_pinchPeriodSeconds * 1000);
        return Duration(
            milliseconds: (periods * _pinchPeriodSeconds * 1000).round());
      case _Motion.returnPan:
        final periods = sampleMs ~/ (_returnPanPeriodSeconds * 1000);
        return Duration(
            milliseconds: (periods * _returnPanPeriodSeconds * 1000).round());
      case _Motion.fling:
        final segments = sampleMs ~/ (_flingSegmentSeconds * 1000);
        return Duration(
            milliseconds: (segments * _flingSegmentSeconds * 1000).round());
      default:
        return Duration(milliseconds: sampleMs);
    }
  }

  Future<void> _clearDiskCache() async {
    try {
      if (MapDiskCache.isInitialized) await MapDiskCache.clear();
    } catch (_) {
      _emitPayload('FOSM_BENCHMARK_INVALID', 'disk-cache clear failed');
    }
  }

  /// Coverage-clock timestamps (ms) of every zoom leg jump, in order,
  /// plus the first sample recorded after each jump. Leg metrics measure
  /// from that first post-jump sample, not from the jump call: a frame
  /// already in flight when the jump fires can carry the pre-jump state,
  /// which would otherwise fake a near-instant all-sharp.
  /// The coverage report splits time-to-sharp per leg from these.
  final List<double> _legJumpAtMs = [];
  final List<double> _legBaseAtMs = [];

  /// Drives the zoom legs of a [zoomStep] scenario after arming: jump to
  /// `startZoom + zoomStep` at t≈0, hold [legHoldMs], jump back to
  /// [startZoom]. Leg boundaries are recorded on the coverage clock and
  /// emitted as payload lines for log-level attribution.
  Future<void> _driveZoomLegs(_Scenario scenario) async {
    if (scenario.panTilesBeforeZoom != 0) {
      await _drivePanThenZoomLegs(scenario);
      return;
    }
    Future<void> jump(int levels, String label) async {
      final atMs = _coverageClock?.elapsedMilliseconds.toDouble() ?? 0;
      _legJumpAtMs.add(atMs);
      unawaited(_emitPayload('FOSM_BENCHMARK_LEG_JUMP',
          '${scenario.name} leg=${_legJumpAtMs.length} levels=$label '
          'atMs=${atMs.round()}'));
      _timelineMark('legJump${_legJumpAtMs.length}.${scenario.name}');
      _controller.setZoom(scenario.startZoom + levels, animate: false);
    }

    await Future<void>.delayed(const Duration(milliseconds: 1));
    await jump(scenario.zoomStep, '${scenario.zoomStep}');
    if (scenario.legHoldMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: scenario.legHoldMs));
      if (!mounted) return;
      await jump(0, 'back');
    }
  }

  /// Pan-then-zoom legs (plan 13 Phase E A/B): pan a fraction of a tile,
  /// idle briefly — the candidate's idle re-admission re-predicts around
  /// the panned center while the baseline's byte preload re-debounces —
  /// then jump [zoomStep] levels and measure the reveal. Holds, then
  /// jumps back.
  Future<void> _drivePanThenZoomLegs(_Scenario scenario) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    _controller.moveTo(
        LatLng(
          latitude: _center.latitude,
          longitude: _center.longitude +
              scenario.panTilesBeforeZoom * 360 / (1 << scenario.startZoom),
        ),
        animate: false);
    // Pan-idle window: both arms' idle paths run here, unrecorded as
    // "preparation" — the measured leg is the zoom reveal after it.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    final atMs = _coverageClock?.elapsedMilliseconds.toDouble() ?? 0;
    _legJumpAtMs.add(atMs);
    unawaited(_emitPayload('FOSM_BENCHMARK_LEG_JUMP',
        '${scenario.name} leg=1 levels=${scenario.zoomStep} '
        'atMs=${atMs.round()}'));
    _timelineMark('legJump1.${scenario.name}');
    _controller.setZoom(scenario.startZoom + scenario.zoomStep,
        animate: false);
    if (scenario.legHoldMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: scenario.legHoldMs));
      if (!mounted) return;
      final backMs = _coverageClock?.elapsedMilliseconds.toDouble() ?? 0;
      _legJumpAtMs.add(backMs);
      unawaited(_emitPayload('FOSM_BENCHMARK_LEG_JUMP',
          '${scenario.name} leg=2 levels=0 atMs=${backMs.round()}'));
      _controller.setZoom(scenario.startZoom, animate: false);
    }
  }

  /// Disk-cache stats snapshot (delta-reported across the window); null
  /// when the disk cache is unavailable.
  Future<MapDiskCacheStats?> _diskStats() async {
    try {
      if (!MapDiskCache.isInitialized) return null;
      return await MapDiskCache.stats();
    } catch (_) {
      return null;
    }
  }

  /// Visits every (zoom, camera pose) the recorded pinch will select and
  /// settles each to completion, so the recorded window measures camera
  /// cost only (plan-13 review round 2): the sweep crosses integer zoom
  /// boundaries (`zoom = cameraZoom.round()`), and settling only the
  /// final viewport leaves the other grids' imagery stale-pruned and
  /// unrendered — the recorded window then races production and drops to
  /// fallback coverage. Each pose must settle or the capture is rejected
  /// loudly: a warm control that failed preparation must not pass as
  /// warm.
  Future<void> _warmPinchFootprint(_Scenario scenario) async {
    final isPan = scenario.motion == _Motion.pinchPan;
    // Two poses per grid side: the membership window shifts with the
    // tile scale within a grid (camera 9.6 renders the z10 grid at
    // 2^−0.4), so the far ends of each side cover both window shifts.
    final poses = <(double, LatLng)>[
      for (final d in [-0.74, -0.51, -0.49, 0.0, 0.49, 0.51, 0.74])
        (
          _startZoom + d,
          isPan ? _pinchPanCenter(d) : _center,
        ),
    ];
    for (final (zoom, center) in poses) {
      _controller.moveTo(center, animate: false);
      _controller.setFractionalZoom(zoom, animate: false);
      final settled = await _settle(Duration(seconds: _settleSeconds));
      if (!settled) {
        throw StateError(
            'warm footprint failed to settle at zoom $zoom — rejecting '
            'the capture: the warm control would be contaminated');
      }
    }
    _controller.moveTo(isPan ? _pinchPanCenter(0) : _center, animate: false);
    _controller.setFractionalZoom(_startZoom.toDouble(), animate: false);
    final settled = await _settle(Duration(seconds: _settleSeconds));
    if (!settled) {
      throw StateError(
          'warm footprint failed to settle at the start pose — rejecting '
          'the capture: the warm control would be contaminated');
    }
  }

  /// Camera center of the pinch-pan gesture at sine delta [delta]: the
  /// geographic point under the off-center focal stays fixed, so the
  /// center orbits it by 2^−delta (see [_Motion.pinchPan]).
  LatLng _pinchPanCenter(double delta) {
    final shrink = math.pow(2, -delta).toDouble();
    return LatLng(
      latitude: _pinchFocalLat + (_center.latitude - _pinchFocalLat) * shrink,
      longitude:
          _pinchFocalLng + (_center.longitude - _pinchFocalLng) * shrink,
    );
  }

  /// Warms a warm scenario's whole recorded footprint, unrecorded, and
  /// verifies preparation before the window arms (plan-13 review rounds
  /// 1-2). Pinch scenarios settle every (zoom, pose) the sweep selects;
  /// animated scenarios visit the zoom target and return; anything that
  /// fails to settle rejects the capture.
  Future<void> _warmMotionFootprint(_Scenario scenario) async {
    switch (scenario.motion) {
      case _Motion.pinch:
      case _Motion.pinchPan:
        await _warmPinchFootprint(scenario);
      case _Motion.none:
      case _Motion.fling:
      case _Motion.returnPan:
      case _Motion.returnFrom:
        if (scenario.animatedZoom != 0) {
          _controller.setZoom(
              scenario.startZoom + scenario.animatedZoom,
              animate: false);
          var settled = await _settle(Duration(seconds: _settleSeconds));
          if (settled) {
            _controller.setZoom(scenario.startZoom, animate: false);
            settled = await _settle(Duration(seconds: _settleSeconds));
          }
          if (!settled) {
            throw StateError(
                'warm footprint failed to settle at zoom '
                '${scenario.startZoom + scenario.animatedZoom} — rejecting '
                'the capture: the warm control would be contaminated');
          }
        }
    }
  }

  /// Cache-eviction counter snapshot at arming; the RESULT reports the
  /// delta across the window (plan 13 attribution).
  Map<String, Object?>? _cacheAttributionAtArm;

  /// Grid-recapture reason counters at arming (process-lifetime statics;
  /// the window delta attributes this scenario's recaptures).
  Map<String, Object?>? _gridRecapturesAtArm;

  Map<String, Object?>? _gridRecaptureDelta() {
    final before = _gridRecapturesAtArm;
    if (before == null) return null;
    final now = MapView.debugGridRecaptures.toJson();
    return {
      for (final key in now.keys)
        key: (now[key] as int? ?? 0) - (before[key] as int? ?? 0),
    };
  }

  /// Prepared-window A/B counters (plan 13 Phase E): window deltas of
  /// admitted / promoted / cancelled — the wasted-preparation metric is
  /// (admitted − promoted) / admitted.
  Map<String, Object?>? _preparedStatsAtArm;
  Map<String, Object?>? _preparedStatsDelta() {
    final before = _preparedStatsAtArm;
    if (before == null) return null;
    final now = _controller.preparedWindowStats;
    if (now == null) return null;
    return {
      for (final key in now.keys)
        key: (now[key] ?? 0) - (before[key] as int? ?? 0),
    };
  }

  Map<String, Object?>? _cacheAttributionDelta() {
    final before = _cacheAttributionAtArm;
    final now = _controller.cacheAttribution?.toJson();
    if (before == null || now == null) return null;
    int delta(Map before, Map now, String key) =>
        (now[key] as int? ?? 0) - (before[key] as int? ?? 0);
    final renderedBefore = before['renderedMisses'] as Map;
    final renderedNow = now['renderedMisses'] as Map;
    return {
      'renderedExpired': delta(renderedBefore, renderedNow, 'expired'),
      'renderedBudgetEvicted':
          delta(renderedBefore, renderedNow, 'budgetEvicted'),
      'renderedPressureFlushed':
          delta(renderedBefore, renderedNow, 'pressureFlushed'),
      'byteCacheEvictions':
          delta(before, now, 'byteCacheEvictions'),
      'parsedEvictions':
          now.containsKey('parsedEvictions')
              ? delta(before, now, 'parsedEvictions')
              : null,
      'byteCacheEntriesEnd': now['byteCacheEntries'],
      'parsedTilesEnd': now['parsedTiles'],
    };
  }

  /// Waits until the mounted map is visually settled: every strict
  /// viewport cell sharp, no loads in flight, the label-preparation
  /// queue drained *and* the prepared-label count stable for five
  /// consecutive frames. Stable counts alone do not prove preparation
  /// finished — a batch can be mid-flight without changing the cached
  /// count — so the outstanding-jobs counter must be zero too. Returns
  /// false on timeout (the report says `settled:false` — never silently a
  /// warm run).
  Future<bool> _settle(Duration limit) async {
    var quietFrames = 0;
    var lastLabels = -1;
    final clock = Stopwatch()..start();
    while (mounted && clock.elapsed < limit) {
      await WidgetsBinding.instance.endOfFrame;
      final coverage = _controller.tileCoverage;
      if (coverage == null || coverage.visibleCells == 0) {
        quietFrames = 0;
        continue;
      }
      if (!coverage.allSharp) {
        quietFrames = 0;
        continue;
      }
      final load = _controller.loadState;
      if (load != null && load.isLoading) {
        quietFrames = 0;
        continue;
      }
      final attribution = _controller.memoryAttribution;
      if ((attribution?.labelJobsOutstanding ?? 0) > 0) {
        quietFrames = 0;
        continue;
      }
      // Labels are only settled when every sharp cell's tile completed
      // preparation — a temporarily empty queue while other visible tiles
      // are still loading does not count.
      if (_scenario.source == _Source.vector &&
          _labelReadyFraction(coverage, _controller.labelPreparedTileKeys) <
              1) {
        quietFrames = 0;
        continue;
      }
      final labels = attribution?.preparedLabels ?? 0;
      if (labels != lastLabels) {
        quietFrames = 0;
        lastLabels = labels;
        continue;
      }
      if (++quietFrames >= 5) return true;
    }
    return false;
  }

  Future<void> _run() async {
    final view = View.of(context);
    final refresh = view.display.refreshRate;
    final styleUrlBase = '$_base/style-$_styleVariant.json';
    await _emitPayload(
        'FOSM_BENCHMARK_META',
        jsonEncode({
          'label': _runLabel,
          'harness': 'vector-baseline',
          'mode': 'profile',
          'os': osName(),
          'osVersion': osVersion(),
          'refreshHz': refresh,
          'physicalWidth': view.physicalSize.width,
          'physicalHeight': view.physicalSize.height,
          'devicePixelRatio': view.devicePixelRatio,
          'payloadIdentity': _payloadIdentity,
          'payloadProfile': _profileName,
          'payloadSeed':
              _payloadIdentity == BenchPayloads.identity ? _seed : null,
          'payloadServer': Uri.parse(_base).authority,
          'styleUrlPath':
              '/style-<variant>.json ($styleUrlBase mounted at start)',
          'sourceMaxZoom': 14,
          'centerLatitude': _center.latitude,
          'centerLongitude': _center.longitude,
          'sampleSeconds': _sampleSeconds,
          'settleSeconds': _settleSeconds,
          'schedulerPaced': true,
          'spans': VectorSpanLog.enabled,
          'timeline': const bool.fromEnvironment('fosm.traceVector'),
          'scenarioFilter': _scenarioFilter,
          'dashCull': const bool.fromEnvironment('fosm.vectorDashCull'),
          'speculation': const bool.fromEnvironment('fosm.vectorSpeculation'),
          'motion128': const bool.fromEnvironment('fosm.vectorMotion128'),
        }));

    final scenarios = _scenarioFilter.isEmpty
        ? _scenarios
        : _scenarios
            .where((s) => _scenarioFilterNames.contains(s.name))
            .toList();
    if (scenarios.isEmpty) {
      throw StateError('Unknown benchmark scenario: $_scenarioFilter');
    }
    for (final scenario in scenarios) {
      _scenario = scenario;
      _styleVariant = 'a';
      _styleSwitchTimer?.cancel();
      _styleSwitchTimer = null;
      _startZoom = scenario.startZoom;
      var settled = true;

      // Switching the camera mode (fractional ↔ integer) requires a
      // fresh map state; the next mount rebuilds its warm state through
      // the scenario's settle/warm-up path.
      if (_mountedIntegerZoom != scenario.integerZoom) {
        setState(() => _mapMounted = false);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        setState(() {
          _mapMounted = true;
          _mapGeneration++;
        });
        await WidgetsBinding.instance.endOfFrame;
        _mountedIntegerZoom = scenario.integerZoom;
      }

      final unmountFirst = scenario.cacheState == _CacheState.coldBytes ||
          scenario.cacheState == _CacheState.warmBytesColdParsed;
      if (unmountFirst) {
        // Nothing can load from or write to storage while it is cleared.
        setState(() => _mapMounted = false);
        await WidgetsBinding.instance.endOfFrame;
        if (scenario.cacheState == _CacheState.coldBytes) {
          await _clearDiskCache();
        }
        if (scenario.zoomStep != 0) {
          // Mount, settle at the start zoom and idle so the preload runs
          // before the window arms (not part of the measurement).
          if (!mounted) return;
          setState(() {
            _mapMounted = true;
            _mapGeneration++;
          });
          await WidgetsBinding.instance.endOfFrame;
          settled = await _settle(Duration(seconds: _settleSeconds));
          await Future<void>.delayed(
              Duration(milliseconds: scenario.idleBeforeMs));
        }
      } else {
        // Mounted warm states: park the camera at the scenario pose and
        // settle whatever the previous scenario left behind.
        setState(() {}); // refresh startZoom/variant parameters
        await WidgetsBinding.instance.endOfFrame;
        _controller.setZoom(scenario.startZoom, animate: false);
        _controller.moveTo(_center, animate: false);
        settled = await _settle(Duration(seconds: _settleSeconds));
        if (scenario.cacheState == _CacheState.warmParsedColdImages &&
            !settled) {
          throw StateError('Warm-parsed capture requires a settled viewport');
        }
        // Plan-13 review P2: a warm camera control must not race tile
        // arrivals in the recorded window, so warm the WHOLE motion
        // footprint first (unrecorded), then settle before arming.
        if (scenario.cacheState == _CacheState.warmRendered) {
          await _warmMotionFootprint(scenario);
          settled = await _settle(Duration(seconds: _settleSeconds));
        }
      }

      await _emitPayload(
          'FOSM_BENCHMARK_SCENARIO',
          '${scenario.name} '
              'motion=${scenario.motion.name} '
              'cacheState=${scenario.cacheState.name} '
              'source=${scenario.source.name} startZoom=${scenario.startZoom} '
              'styleSwitch=${scenario.styleSwitch} '
              'motionSettleMs=${scenario.motionSettleMs} '
              'integerZoom=${scenario.integerZoom} '
              'settled=$settled');

      final int rssBefore;
      // Disk-cache stats at arming; armRecording reassigns it. Awaited at
      // window end for the delta report.
      var diskBefore = Future<MapDiskCacheStats?>.value();
      void armRecording() {
        _timings.clear();
        _coverageSamples.clear();
        _coverageWindowMs = 0;
        _emptyGridFrames = 0;
        _cellFirstSeenMs.clear();
        _cellSharpAtMs.clear();
        _legJumpAtMs.clear();
        _legBaseAtMs.clear();
        _cacheAttributionAtArm = _controller.cacheAttribution?.toJson();
        _gridRecapturesAtArm = MapView.debugGridRecaptures.toJson();
        _preparedStatsAtArm =
            _controller.preparedWindowStats?.cast<String, Object?>();
        diskBefore = _diskStats();
        _peakRenderedBytes = 0;
        _peakEstimatedTotalBytes = 0;
        _peakParsedTiles = 0;
        _peakPreparedLabels = 0;
        VectorSpanLog.clear();
        VectorDashDiagnostics.clear();
        _coverageClock = Stopwatch()..start();
        _chainCoverageSample();
        _recording = true;
        _timelineMark('sampleStart.${scenario.name}');
        // armRecording is synchronous (the sampling chain starts here);
        // the marker rides out without the arm's timing depending on a
        // sink POST.
        unawaited(_emitPayload('FOSM_BENCHMARK_SAMPLE_START', scenario.name));
      }

      final sample = Duration(seconds: scenario.windowSeconds);
      if (unmountFirst && scenario.zoomStep == 0) {
        // Arm before mounting: the replacement's first load frame is the
        // first measured frame (cold and warm-bytes loads alike).
        if (!mounted) return;
        rssBefore = processRssBytes();
        armRecording();
        setState(() {
          _mapMounted = true;
          _mapGeneration++;
        });
        await WidgetsBinding.instance.endOfFrame;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
        rssBefore = processRssBytes();
        armRecording();
        // A settled static map renders no frames on its own, which would
        // leave the window without a single coverage sample. Force one
        // rebuild so the sampler records a t≈0 baseline row.
        setState(() {});
        if (scenario.zoomStep != 0) {
          // Legs continue asynchronously while the window records: the
          // single-step scenarios jump once; the cycle scenarios jump,
          // hold, and jump back (plan 13 zoom-reversal reuse).
          unawaited(_driveZoomLegs(scenario));
        }
        if (scenario.animatedZoom != 0) {
          _timelineMark('animatedZoom.${scenario.name}');
          _controller.setZoom(scenario.startZoom + scenario.animatedZoom,
              animate: true);
        }
      }

      if (scenario.cacheState == _CacheState.warmParsedColdImages) {
        // Arm first: every re-render belongs to the measured window. Keep
        // the exact settled viewport so its parsed source tiles remain warm.
        _controller.dropRebuildableCaches(includeVisibleImages: true);
      }

      if (scenario.styleSwitch) {
        _styleSwitchTimer = Timer(sample * 0.5, () {
          if (!mounted) return;
          setState(() => _styleVariant = 'b');
        });
      }

      await _runWindow(_motionWindow);
      _styleSwitchTimer?.cancel();
      _styleSwitchTimer = null;
      if (!mounted) return;
      if (scenario.motionSettleMs > 0) {
        // Stay inside the recorded window while the camera is idle, so
        // the 200 ms preview settle and full-resolution upgrades are
        // measured as time-to-sharp rather than occurring after the
        // sampler has stopped.
        await Future<void>.delayed(
            Duration(milliseconds: scenario.motionSettleMs));
      }
      if (scenario.motion != _Motion.none) {
        // Let trailing decodes/presentations land inside the window.
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      _recording = false;
      final coverageClock = _coverageClock;
      coverageClock?.stop();
      _coverageWindowMs = coverageClock?.elapsedMilliseconds.toDouble() ?? 0;
      _coverageClock = null;
      _timelineMark('sampleEnd.${scenario.name}');
      final dashDiagnostics = VectorDashDiagnostics.enabled
          ? VectorDashDiagnostics.snapshot()
          : null;
      await _emitPayload('FOSM_BENCHMARK_SAMPLE_END', scenario.name);

      // Disk-cache deltas across the window: reuse that avoided a network
      // request shows up as hits; a first visit shows misses.
      Map<String, Object?>? diskDelta;
      try {
        final before = await diskBefore;
        final after = await _diskStats();
        if (before != null && after != null) {
          diskDelta = {
            'hits': after.hits - before.hits,
            'misses': after.misses - before.misses,
            'evictions': after.evictions - before.evictions,
            'entryCountEnd': after.entryCount,
            'sizeBytesEnd': after.sizeBytes,
          };
        }
      } catch (_) {
        diskDelta = null;
      }

      final uiMs = _timings
          .map((f) => f.buildDuration.inMicroseconds / 1000)
          .toList()
        ..sort();
      final rasterMs = _timings
          .map((f) => f.rasterDuration.inMicroseconds / 1000)
          .toList()
        ..sort();
      double percentile(List<double> values, double p) =>
          values.isEmpty ? 0 : values[((values.length - 1) * p).round()];

      await _emitPayload(
          'FOSM_BENCHMARK_RESULT',
          jsonEncode({
            'label': _runLabel,
            'harness': 'vector-baseline',
            'scenario': scenario.name,
            'frames': _timings.length,
            'valid': _timings.isNotEmpty,
            'motion': scenario.motion.name,
            'cacheState': scenario.cacheState.name,
            'source': scenario.source.name,
            'startZoom': scenario.startZoom,
            'styleSwitch': scenario.styleSwitch,
            'motionSettleMs': scenario.motionSettleMs,
            'settled': settled,
            'sampleSeconds': scenario.windowSeconds,
            'zoomStep': scenario.zoomStep,
            'legHoldMs': scenario.legHoldMs,
            'animatedZoom': scenario.animatedZoom,
            'integerZoom': scenario.integerZoom,
            'payloadIdentity': _payloadIdentity,
            'payloadProfile': _profileName,
            'payloadSeed':
                _payloadIdentity == BenchPayloads.identity ? _seed : null,
            'spans': VectorSpanLog.enabled,
            'uiP50Ms': percentile(uiMs, 0.5),
            'uiP95Ms': percentile(uiMs, 0.95),
            'uiP99Ms': percentile(uiMs, 0.99),
            'uiMaxMs': percentile(uiMs, 1),
            'rasterP50Ms': percentile(rasterMs, 0.5),
            'rasterP95Ms': percentile(rasterMs, 0.95),
            'rasterP99Ms': percentile(rasterMs, 0.99),
            'rasterMaxMs': percentile(rasterMs, 1),
            'framesOver16_67Ms': _timings
                .where((f) =>
                    math.max(f.buildDuration.inMicroseconds,
                        f.rasterDuration.inMicroseconds) >
                    16667)
                .length,
            'framesOverDisplayBudget': _timings
                .where((f) =>
                    math.max(f.buildDuration.inMicroseconds,
                        f.rasterDuration.inMicroseconds) >
                    1000000 / refresh)
                .length,
            'coverage':
                _coverageReport(vector: scenario.source == _Source.vector),
            'cacheAttribution': _cacheAttributionDelta(),
            'gridRecaptures': _gridRecaptureDelta(),
            'preparedWindow': _preparedStatsDelta(),
            'diskCache': diskDelta,
            'peakRenderedBytes': _peakRenderedBytes,
            'peakEstimatedTotalBytes': _peakEstimatedTotalBytes,
            'peakParsedTiles': _peakParsedTiles,
            'peakPreparedLabels': _peakPreparedLabels,
            'rssBeforeBytes': rssBefore,
            'rssAfterBytes': processRssBytes(),
          }));

      if (VectorSpanLog.enabled) {
        await _emitPayload(
            'FOSM_BENCHMARK_VECTOR_STAGES',
            jsonEncode(
              buildVectorStageReport(
                VectorSpanLog.take(),
                dropped: VectorSpanLog.dropped,
              ),
            ));
      }
      if (dashDiagnostics != null) {
        await _emitPayload('FOSM_BENCHMARK_DASH_DIAGNOSTICS',
            jsonEncode({'scenario': scenario.name, ...dashDiagnostics}));
      }
    }
    await _emitPayload('FOSM_BENCHMARK_DONE', _runLabel);
  }

  /// Chained post-frame sampler: one row per rendered frame while
  /// recording, plus peak attribution buckets and per-cell exposure
  /// tracking. Frames whose grid is not laid out yet are skipped (and
  /// counted) — an empty grid must never be read as covered. Stops with
  /// recording.
  void _chainCoverageSample() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_recording || _coverageClock == null) return;
      final coverage = _controller.tileCoverage;
      if (coverage != null) {
        if (coverage.visibleCells == 0) {
          _emptyGridFrames++;
        } else {
          final nowMs = _coverageClock!.elapsedMilliseconds.toDouble();
          for (final cell in coverage.visibleCellIds) {
            _cellFirstSeenMs.putIfAbsent(cell, () => nowMs);
          }
          for (final cell in coverage.sharpCellIds) {
            _cellSharpAtMs.putIfAbsent(cell, () => nowMs);
          }
          final attribution = _controller.memoryAttribution;
          final labels = attribution?.preparedLabels ?? 0;
          final failed = _controller.loadState?.failedTiles ?? 0;
          if (attribution != null) {
            _peakRenderedBytes =
                math.max(_peakRenderedBytes, attribution.renderedImages.bytes);
            _peakEstimatedTotalBytes = math.max(
                _peakEstimatedTotalBytes, attribution.estimatedTotalBytes);
            _peakParsedTiles =
                math.max(_peakParsedTiles, attribution.parsedTiles ?? 0);
            _peakPreparedLabels = math.max(_peakPreparedLabels, labels);
          }
          final labelReady = _scenario.source == _Source.vector
              ? _labelReadyFraction(coverage, _controller.labelPreparedTileKeys)
              : 1.0;
          _coverageSamples.add([
            nowMs,
            coverage.coveredFraction,
            coverage.sharpFraction,
            (attribution?.preparedLabelTiles ?? 0).toDouble(),
            labels.toDouble(),
            failed.toDouble(),
            (attribution?.labelJobsOutstanding ?? 0).toDouble(),
            coverage.coveredAreaFraction,
            coverage.sharpAreaFraction,
            labelReady,
          ]);
          // Stamp the first sample recorded after each pending leg jump:
          // leg metrics measure from here (see [_legBaseAtMs]).
          if (_legJumpAtMs.isNotEmpty &&
              _legBaseAtMs.length < _legJumpAtMs.length) {
            final jumpMs = _legJumpAtMs[_legBaseAtMs.length];
            if (nowMs >= jumpMs) _legBaseAtMs.add(nowMs);
          }
        }
      }
      _chainCoverageSample();
    });
  }

  /// Derived coverage/labels metrics plus downsampled series (≤72 points).
  ///
  /// Definitions: `covered`/`sharp` are cell-count fractions (every
  /// visible grid cell weighted equally); `coveredArea`/`sharpArea` are
  /// pixel-area fractions (cells weighted by their viewport intersection)
  /// — partial edge cells make them diverge. "Newly exposed" cells are
  /// those first visible strictly after the window's first sample, so
  /// motion scenarios report time-to-sharp for cells revealed during the
  /// pan rather than for cells visible all along. Label readiness is
  /// `labelsViewportReadyMs` (allSharp + drained queue + every sharp
  /// cell's tile prepared, zero-label tiles counting as prepared);
  /// `labelsDrainedMs` is only the drained-queue component — a
  /// temporarily empty queue while other visible tiles are still loading
  /// does not make the viewport ready.
  Map<String, Object?> _coverageReport({required bool vector}) {
    final samples = _coverageSamples;
    int? firstWhereMs(bool Function(List<double> s) test) {
      for (final s in samples) {
        if (test(s)) return s[0].round();
      }
      return null;
    }

    var sharpMin = 1.0;
    var maxFailed = 0.0;
    for (final s in samples) {
      if (s[2] < sharpMin) sharpMin = s[2];
      if (s[5] > maxFailed) maxFailed = s[5];
    }
    // First-sharp and 95% timings come from the full-resolution samples,
    // never from the downsampled series.
    final thresholds = coverageThresholdTimings(samples);
    var lastLabelChangeMs = 0;
    for (var i = 0; i < samples.length; i++) {
      if (i == 0 || samples[i][3] != samples[i - 1][3]) {
        lastLabelChangeMs = samples[i][0].round();
      }
    }
    int? labelsDrainedMs;
    for (final s in samples) {
      if (s[3] > 0 && s[6] == 0) {
        labelsDrainedMs = s[0].round();
        break;
      }
    }
    // Viewport label readiness: imagery complete (all sharp), preparation
    // queue drained, *and* every sharp cell's tile completed preparation
    // — including tiles that prepared with zero labels. A temporarily
    // empty queue while other visible tiles are still downloading does
    // not satisfy this.
    int? labelsViewportReadyMs;
    if (vector) {
      for (final s in samples) {
        if (s[2] >= 1 && s[6] == 0 && s[9] >= 1) {
          labelsViewportReadyMs = s[0].round();
          break;
        }
      }
    }

    // Newly exposed regions: cells first seen after the first sample.
    final firstSampleMs = samples.isEmpty ? double.infinity : samples.first[0];
    final newToSharp = <double>[];
    var newlyExposed = 0;
    var newlyExposedSharp = 0;
    _cellFirstSeenMs.forEach((cell, seenMs) {
      if (seenMs <= firstSampleMs) return;
      newlyExposed++;
      final sharpAt = _cellSharpAtMs[cell];
      if (sharpAt == null) return;
      newlyExposedSharp++;
      newToSharp.add(sharpAt - seenMs);
    });
    double mean(Iterable<double> values) =>
        values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;

    final step = samples.length <= 72 ? 1 : (samples.length / 72).ceil();
    List<double> column(int index) =>
        [for (var i = 0; i < samples.length; i += step) samples[i][index]];
    final seriesMs = [
      for (var i = 0; i < samples.length; i += step) samples[i][0].round()
    ];
    List<double> ensureLast(int index) {
      final values = column(index);
      if (samples.isNotEmpty &&
          (values.isEmpty || seriesMs.last != samples.last[0].round())) {
        values.add(samples.last[index]);
      }
      return values;
    }

    // Zoom-leg splits (plan 13 cycle scenarios): time-to-sharp measured
    // from the first post-jump sample of each leg (see [_legBaseAtMs] —
    // a frame in flight at the jump can carry pre-jump state). Leg 2 of a
    // cycle returns to [startZoom]; its allSharpMs is the reversal-reuse
    // or reproduction metric. Each leg's search stops at the next jump:
    // a later leg's samples belong to that leg, and the sharp restoration
    // after the following jump must never masquerade as this leg's
    // completion (plan-13 review P1 — a leg whose imagery never arrives
    // reports null, not the next leg's recovery).
    final legs = <Map<String, Object?>>[];
    for (var k = 0; k < _legJumpAtMs.length; k++) {
      final baseMs =
          k < _legBaseAtMs.length ? _legBaseAtMs[k] : _legJumpAtMs[k];
      final endMs = k + 1 < _legBaseAtMs.length
          ? _legBaseAtMs[k + 1]
          : double.infinity;
      int? legFirst(bool Function(List<double> s) test) {
        for (final s in samples) {
          if (s[0] < baseMs) continue;
          if (s[0] >= endMs) return null;
          if (test(s)) return (s[0] - baseMs).round();
        }
        return null;
      }

      legs.add({
        'boundedToNextJump': true,
        'jumpMs': _legJumpAtMs[k].round(),
        'baseMs': baseMs.round(),
        'allCoveredMs': legFirst((s) => s[1] >= 1),
        'allSharpMs': legFirst((s) => s[2] >= 1),
        if (vector)
          'labelsViewportReadyMs':
              legFirst((s) => s[2] >= 1 && s[6] == 0 && s[9] >= 1),
      });
    }

    return {
      'samples': samples.length,
      'emptyGridFrames': _emptyGridFrames,
      'firstCoveredMs': firstWhereMs((s) => s[1] > 0),
      'allCoveredMs': firstWhereMs((s) => s[1] >= 1),
      ...thresholds,
      'allSharpMs': firstWhereMs((s) => s[2] >= 1),
      'minSharpFraction': _round4(sharpMin),
      'meanCoveredFraction':
          _round4OrNull(coverageMeanOverWindow(samples, 1, _coverageWindowMs)),
      'meanSharpFraction':
          _round4OrNull(coverageMeanOverWindow(samples, 2, _coverageWindowMs)),
      'meanCoveredAreaFraction':
          _round4OrNull(coverageMeanOverWindow(samples, 7, _coverageWindowMs)),
      'meanSharpAreaFraction':
          _round4OrNull(coverageMeanOverWindow(samples, 8, _coverageWindowMs)),
      'sharpFractionEnd': samples.isEmpty ? null : _round4(samples.last[2]),
      'sharpAreaFractionEnd': samples.isEmpty ? null : _round4(samples.last[8]),
      // Newly exposed regions during motion (0 for static windows).
      'newlyExposedCells': newlyExposed,
      'newlyExposedSharpByEnd': newlyExposedSharp,
      'meanNewToSharpMs': newToSharp.isEmpty ? null : mean(newToSharp).round(),
      'maxNewToSharpMs': newToSharp.isEmpty
          ? null
          : newToSharp.reduce((a, b) => a > b ? a : b).round(),
      // Labels-ready latency. `labelsViewportReadyMs` is the readiness
      // metric (imagery complete, queue drained, every sharp cell's tile
      // prepared — zero-label tiles count as prepared);
      // `labelsDrainedMs` is only the drained-queue component.
      'firstLabelsMs': firstWhereMs((s) => s[3] > 0),
      'labelsStableMs': samples.isEmpty ? null : lastLabelChangeMs,
      'labelsDrainedMs': labelsDrainedMs,
      'labelsViewportReadyMs': labelsViewportReadyMs,
      'labelTilesEnd': samples.isEmpty ? null : samples.last[3].round(),
      'labelCountEnd': samples.isEmpty ? null : samples.last[4].round(),
      'labelReadyFractionEnd':
          samples.isEmpty ? null : _round4(samples.last[9]),
      // Unreachable coverage: tile failures observed during the window.
      'maxFailedTiles': maxFailed.round(),
      'seriesMs': seriesMs,
      'seriesCovered': ensureLast(1),
      'seriesSharp': ensureLast(2),
      'seriesLabelTiles': ensureLast(3),
      'seriesCoveredArea': ensureLast(7),
      'seriesSharpArea': ensureLast(8),
      'seriesLabelReady': ensureLast(9),
      if (legs.isNotEmpty) 'legs': legs,
    };
  }

  static double? _round4OrNull(double? v) => v == null ? null : _round4(v);

  static double _round4(double v) => (v * 10000).round() / 10000;

  Future<Uint8List> _rasterTile(int z, int x, int y) =>
      downloadTileBytes('$_base/raster/$z/$x/$y.png');

  @override
  Widget build(BuildContext context) => Scaffold(
      body: _mapMounted
          ? KeyedSubtree(
              key: ValueKey<int>(_mapGeneration),
              child: MapView(
                latLng: _center,
                zoom: _startZoom,
                enableFractionalZoom: !_scenario.integerZoom,
                controller: _controller,
                vectorStyle: _scenario.source == _Source.vector
                    ? VectorMapStyle(
                        id: 'bench-$_styleVariant',
                        styleUrl: '$_base/style-$_styleVariant.json',
                      )
                    : null,
                tileFetcher:
                    _scenario.source == _Source.raster ? _rasterTile : null,
                showScaleBar: true,
                showZoomControls: false,
              ))
          // While unmounted (clearing storage or re-creating the runtime)
          // the map subtree is absent entirely: its state is disposed, so
          // no loads or writes can race the cache-state establishment.
          : const SizedBox.expand());

  @override
  void dispose() {
    _recording = false;
    _styleSwitchTimer?.cancel();
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    _motion.dispose();
    _controller.dispose();
    super.dispose();
  }
}
