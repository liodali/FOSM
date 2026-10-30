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
//   warmParsedColdImages  mounted, settled → dropRebuildableCaches()
//                         (disk bytes + parsed tiles survive, rendered
//                         images flushed) → pan aside → arm → return pan
//                         re-renders from warm parsed data.
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

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fosm/fosm.dart';

import 'vector_payloads.dart';
import 'vector_stage_report.dart';
import 'benchmark_report.dart' show coverageMeanOverWindow;

const _runLabel =
    String.fromEnvironment('BENCHMARK_LABEL', defaultValue: 'vector-baseline');

/// Base URL of the payload server (scheme + host + port only; never a
/// credential-bearing URL — the trace/report payloads exclude it too).
const _base = String.fromEnvironment('BENCHMARK_VECTOR_BASE',
    defaultValue: 'http://127.0.0.1:8787');

const _profileName = String.fromEnvironment('BENCHMARK_VECTOR_PROFILE',
    defaultValue: 'denseCity');

const _seed = int.fromEnvironment('BENCHMARK_VECTOR_SEED',
    defaultValue: BenchPayloads.defaultSeed);

const _sampleSeconds =
    int.fromEnvironment('BENCHMARK_SAMPLE_SECONDS', defaultValue: 10);

/// Upper bound for the settle phase that establishes warm cache states.
const _settleSeconds =
    int.fromEnvironment('BENCHMARK_SETTLE_SECONDS', defaultValue: 25);

const _center = LatLng(latitude: 47, longitude: 8);

/// Camera-motion family used while sampling.
enum _Motion { none, fling, pinch, returnPan, returnFrom }

/// How each scenario's cache state is established (see file comment).
enum _CacheState { coldBytes, warmBytesColdParsed, warmParsedColdImages, warmRendered }

enum _Source { vector, raster }

class _Scenario {
  const _Scenario(
    this.name, {
    this.motion = _Motion.none,
    this.cacheState = _CacheState.coldBytes,
    this.source = _Source.vector,
    this.startZoom = 10,
    this.styleSwitch = false,
  });

  final String name;
  final _Motion motion;
  final _CacheState cacheState;
  final _Source source;
  final int startZoom;

  /// Switch the style variant a→b at half the sample window (measures a
  /// full runtime/style reload on identical payloads).
  final bool styleSwitch;
}

const _scenarios = [
  // Raster control: same camera paths through the raster pipeline.
  _Scenario('raster_control_static', source: _Source.raster),
  _Scenario('raster_control_fling', source: _Source.raster, motion: _Motion.fling),
  // Cold bytes: full pipeline from network bytes.
  _Scenario('vector_cold_static'),
  _Scenario('vector_cold_fling', motion: _Motion.fling),
  _Scenario('vector_cold_return', motion: _Motion.returnPan),
  _Scenario('vector_cold_pinch', motion: _Motion.pinch),
  _Scenario('vector_cold_overzoom', startZoom: 16),
  // Warm rendered: motion tails without any loading cost.
  _Scenario('vector_warm_static', cacheState: _CacheState.warmRendered),
  _Scenario('vector_warm_fling',
      cacheState: _CacheState.warmRendered, motion: _Motion.fling),
  // Warm bytes, fresh runtime: disk-hit loads with cold parsed data.
  _Scenario('vector_warm_bytes_static',
      cacheState: _CacheState.warmBytesColdParsed),
  // Warm parsed, flushed images: return pan re-renders from parsed cache.
  _Scenario('vector_warm_parsed_return',
      cacheState: _CacheState.warmParsedColdImages, motion: _Motion.returnFrom),
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
  if (!kProfileMode) throw StateError('Run this benchmark with --profile.');
  await initMap();
  runApp(const MaterialApp(home: _VectorBenchmark()));
}

class _VectorBenchmark extends StatefulWidget {
  const _VectorBenchmark();

  @override
  State<_VectorBenchmark> createState() => _VectorBenchmarkState();
}

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
            10 +
                _pinchAmplitudeLevels *
                    math.sin(t * 2 * math.pi / _pinchPeriodSeconds),
            animate: false);
      case _Motion.returnPan:
        final phase = 2 * math.pi * t / _returnPanPeriodSeconds;
        _controller.moveTo(
            LatLng(
                latitude: 47 + 0.01 * math.sin(phase),
                longitude: 8 + _returnPanAmplitudeDeg * math.sin(phase)),
            animate: false);
      case _Motion.returnFrom:
        // Smoothstep from +offset back to the origin, then hold.
        final p = (t / _returnFromSeconds).clamp(0.0, 1.0);
        final eased = 1 - (p * p * (3 - 2 * p));
        _controller.moveTo(
            LatLng(latitude: 47, longitude: 8 + _returnFromOffsetDeg * eased),
            animate: false);
      case _Motion.none:
        break;
    }
  }

  /// Alternating decaying pans, identical to map_benchmark.dart.
  void _moveToFling(double t) {
    final segment = (t / _flingSegmentSeconds).floor();
    final tSeg = t - segment * _flingSegmentSeconds;
    var longitude = 8.0;
    for (var i = 0; i < segment; i++) {
      longitude += (i.isEven ? 1.0 : -1.0) * _flingMaxTravelDeg;
    }
    longitude += (segment.isEven ? 1.0 : -1.0) *
        _flingV0DegPerSec *
        _flingTauSeconds *
        (1 - math.exp(-tSeg / _flingTauSeconds));
    final latitude = 47 + 0.015 * math.sin(t * 1.1);
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

  Future<void> _clearDiskCache() async {
    try {
      if (MapDiskCache.isInitialized) await MapDiskCache.clear();
    } catch (_) {
      debugPrint('FOSM_BENCHMARK_INVALID disk-cache clear failed');
    }
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
    debugPrint('FOSM_BENCHMARK_META ${jsonEncode({
          'label': _runLabel,
          'harness': 'vector-baseline',
          'mode': 'profile',
          'os': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'refreshHz': refresh,
          'physicalWidth': view.physicalSize.width,
          'physicalHeight': view.physicalSize.height,
          'devicePixelRatio': view.devicePixelRatio,
          'payloadIdentity': BenchPayloads.identity,
          'payloadProfile': _profileName,
          'payloadSeed': _seed,
          'payloadServer': Uri.parse(_base).authority,
          'styleUrlPath': '/style-<variant>.json ($styleUrlBase mounted at start)',
          'sourceMaxZoom': 14,
          'sampleSeconds': _sampleSeconds,
          'settleSeconds': _settleSeconds,
          'schedulerPaced': true,
          'spans': VectorSpanLog.enabled,
          'timeline': const bool.fromEnvironment('fosm.traceVector'),
        })}');

    for (final scenario in _scenarios) {
      _scenario = scenario;
      _styleVariant = 'a';
      _styleSwitchTimer?.cancel();
      _styleSwitchTimer = null;
      _startZoom = scenario.startZoom;
      var settled = true;

      final unmountFirst = scenario.cacheState == _CacheState.coldBytes ||
          scenario.cacheState == _CacheState.warmBytesColdParsed;
      if (unmountFirst) {
        // Nothing can load from or write to storage while it is cleared.
        setState(() => _mapMounted = false);
        await WidgetsBinding.instance.endOfFrame;
        if (scenario.cacheState == _CacheState.coldBytes) {
          await _clearDiskCache();
        }
      } else {
        // Mounted warm states: park the camera at the scenario pose and
        // settle whatever the previous scenario left behind.
        setState(() {}); // refresh startZoom/variant parameters
        await WidgetsBinding.instance.endOfFrame;
        _controller.setZoom(scenario.startZoom, animate: false);
        _controller.moveTo(_center, animate: false);
        settled = await _settle(Duration(seconds: _settleSeconds));
        if (scenario.cacheState == _CacheState.warmParsedColdImages) {
          // Flush rendered images and memory bytes; disk bytes, parsed
          // tiles and prepared labels survive. Images protected by the
          // visible grid survive the first drop, so pan aside, settle,
          // and drop again — the origin pose's images are evictable by
          // then and really leave the cache, making the return pan
          // re-render from warm parsed data instead of cache reuse.
          _controller.dropRebuildableCaches();
          _controller.moveTo(
              LatLng(latitude: 47, longitude: 8 + _returnFromOffsetDeg),
              animate: false);
          settled = await _settle(Duration(seconds: _settleSeconds));
          _controller.dropRebuildableCaches();
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }

      debugPrint('FOSM_BENCHMARK_SCENARIO ${scenario.name} '
          'motion=${scenario.motion.name} '
          'cacheState=${scenario.cacheState.name} '
          'source=${scenario.source.name} startZoom=${scenario.startZoom} '
          'styleSwitch=${scenario.styleSwitch} settled=$settled');

      final int rssBefore;
      void armRecording() {
        _timings.clear();
        _coverageSamples.clear();
        _coverageWindowMs = 0;
        _emptyGridFrames = 0;
        _cellFirstSeenMs.clear();
        _cellSharpAtMs.clear();
        _peakRenderedBytes = 0;
        _peakEstimatedTotalBytes = 0;
        _peakParsedTiles = 0;
        _peakPreparedLabels = 0;
        VectorSpanLog.clear();
        _coverageClock = Stopwatch()..start();
        _chainCoverageSample();
        _recording = true;
        _timelineMark('sampleStart.${scenario.name}');
        debugPrint('FOSM_BENCHMARK_SAMPLE_START ${scenario.name}');
      }

      final sample = Duration(seconds: _sampleSeconds);
      if (unmountFirst) {
        // Arm before mounting: the replacement's first load frame is the
        // first measured frame (cold and warm-bytes loads alike).
        if (!mounted) return;
        rssBefore = ProcessInfo.currentRss;
        armRecording();
        setState(() {
          _mapMounted = true;
          _mapGeneration++;
        });
        await WidgetsBinding.instance.endOfFrame;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
        rssBefore = ProcessInfo.currentRss;
        armRecording();
        // A settled static map renders no frames on its own, which would
        // leave the window without a single coverage sample. Force one
        // rebuild so the sampler records a t≈0 baseline row.
        setState(() {});
      }

      if (scenario.styleSwitch) {
        _styleSwitchTimer = Timer(sample * 0.5, () {
          if (!mounted) return;
          setState(() => _styleVariant = 'b');
        });
      }

      await _runWindow(sample);
      _styleSwitchTimer?.cancel();
      _styleSwitchTimer = null;
      if (!mounted) return;
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
      debugPrint('FOSM_BENCHMARK_SAMPLE_END ${scenario.name}');

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

      debugPrint('FOSM_BENCHMARK_RESULT ${jsonEncode({
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
            'settled': settled,
            'sampleSeconds': _sampleSeconds,
            'payloadIdentity': BenchPayloads.identity,
            'payloadProfile': _profileName,
            'payloadSeed': _seed,
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
            'coverage': _coverageReport(
                vector: scenario.source == _Source.vector),
            'peakRenderedBytes': _peakRenderedBytes,
            'peakEstimatedTotalBytes': _peakEstimatedTotalBytes,
            'peakParsedTiles': _peakParsedTiles,
            'peakPreparedLabels': _peakPreparedLabels,
            'rssBeforeBytes': rssBefore,
            'rssAfterBytes': ProcessInfo.currentRss,
          })}');

      if (VectorSpanLog.enabled) {
        debugPrint('FOSM_BENCHMARK_VECTOR_STAGES ${jsonEncode(
              buildVectorStageReport(
                VectorSpanLog.take(),
                dropped: VectorSpanLog.dropped,
              ),
            )}');
      }
    }
    debugPrint('FOSM_BENCHMARK_DONE $_runLabel');
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
              ? _labelReadyFraction(
                  coverage, _controller.labelPreparedTileKeys)
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
    int? firstSharpMs;
    int? covered95Ms;
    int? sharp95Ms;
    for (final s in samples) {
      if (firstSharpMs == null && s[2] > 0) firstSharpMs = s[0].round();
      if (covered95Ms == null && s[1] >= 0.95) covered95Ms = s[0].round();
      if (sharp95Ms == null && s[2] >= 0.95) sharp95Ms = s[0].round();
      if (firstSharpMs != null && covered95Ms != null && sharp95Ms != null) {
        break;
      }
    }
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
    final firstSampleMs =
        samples.isEmpty ? double.infinity : samples.first[0];
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
    double mean(Iterable<double> values) => values.isEmpty
        ? 0
        : values.reduce((a, b) => a + b) / values.length;

    final step = samples.length <= 72 ? 1 : (samples.length / 72).ceil();
    List<double> column(int index) => [
          for (var i = 0; i < samples.length; i += step) samples[i][index]
        ];
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

    return {
      'samples': samples.length,
      'emptyGridFrames': _emptyGridFrames,
      'firstCoveredMs': firstWhereMs((s) => s[1] > 0),
      'allCoveredMs': firstWhereMs((s) => s[1] >= 1),
      'firstSharpMs': firstSharpMs,
      'covered95Ms': covered95Ms,
      'sharp95Ms': sharp95Ms,
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
                enableFractionalZoom: true,
                controller: _controller,
                vectorStyle: _scenario.source == _Source.vector
                    ? VectorMapStyle(
                        id: 'bench-$_styleVariant',
                        styleUrl: '$_base/style-$_styleVariant.json',
                      )
                    : null,
                tileFetcher: _scenario.source == _Source.raster
                    ? _rasterTile
                    : null,
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
