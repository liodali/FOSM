// Native profile-mode benchmark. See docs/performance/README.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fosm/fosm.dart';

import 'network_tile_source.dart';
import 'viewport_sample.dart';
import 'benchmark_report.dart' show coverageMeanOverWindow;

const _runLabel =
    String.fromEnvironment('BENCHMARK_LABEL', defaultValue: 'baseline');
const _fractional = bool.fromEnvironment('BENCHMARK_FRACTIONAL');

/// Adds window-resize sampling scenarios (`resize_idle`, `resize_motion`).
/// The app never resizes its own OS window: run it on desktop and drive
/// resize from outside (AppleScript, wmctrl, …) while the scenarios
/// sample — see docs/performance/web-desktop.md.
const _resize = bool.fromEnvironment('BENCHMARK_RESIZE');

/// Adds the load/motion acceptance scenarios (`cold_static`, `cold_fling`,
/// `cold_pinch`, `warm_fling`, `warm_pinch`, `follow`): cold-cache loads
/// with coverage sampling, decaying flings, zoom-direction reversals and
/// simulated GPS following. See docs/performance/README.md.
const _load = bool.fromEnvironment('BENCHMARK_LOAD');

/// Starts every scenario from recreated in-memory caches and a cleared
/// persistent disk cache (including the five standard scenarios).
const _cold = bool.fromEnvironment('BENCHMARK_COLD');

/// Simulated-network conditions applied to every tile fetch: fixed RTT,
/// bandwidth cap and an every-Nth-request failure. Zero disables each.
const _netDelayMs = int.fromEnvironment('BENCHMARK_NET_DELAY_MS');
const _netKbps = int.fromEnvironment('BENCHMARK_NET_KBPS');
const _netDropEvery = int.fromEnvironment('BENCHMARK_NET_DROP_EVERY');

/// Sampled-motion window per scenario in seconds (default six).
const _sampleSeconds =
    int.fromEnvironment('BENCHMARK_SAMPLE_SECONDS', defaultValue: 6);

/// Reported in META so A/B reports state which scheduler arm they measured
/// (`fosm.unpaced=true` is the unpaced pre-scheduler arm).
const _unpaced = bool.fromEnvironment('fosm.unpaced');

const _warmup = Duration(seconds: 2);
const _sample = Duration(seconds: _sampleSeconds);
const _center = LatLng(latitude: 47, longitude: 8);
late Uint8List _tile;

/// Camera-motion family used while sampling.
enum _Motion { loop, fling, pinch, follow, none }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kProfileMode) throw StateError('Run this benchmark with --profile.');
  await initMap();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xffe7eee4), BlendMode.src);
  final paint = Paint()
    ..color = const Color(0xffb0c5a9)
    ..strokeWidth = 2;
  for (var i = 0.0; i < 256; i += 32) {
    canvas.drawLine(Offset(i, 0), Offset(i, 256), paint);
    canvas.drawLine(Offset(0, i), Offset(256, i), paint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(256, 256);
  _tile = (await image.toByteData(format: ui.ImageByteFormat.png))!
      .buffer
      .asUint8List();
  image.dispose();
  picture.dispose();
  runApp(const MaterialApp(home: _Benchmark()));
}

class _Scenario {
  const _Scenario(this.name,
      {this.markers = 0,
      this.routePoints = 0,
      this.clustered = false,
      this.dense = false,
      this.zoom = false,
      this.idle = false,
      this.motion = _Motion.loop,
      this.cold = false,
      this.coverage = false});
  final String name;
  final int markers;
  final int routePoints;
  final bool clustered;
  final bool dense;
  final bool zoom;

  /// Samples without camera motion: frames come from the external
  /// resize driver only (see [BENCHMARK_RESIZE]).
  final bool idle;

  /// Camera-motion family driving the sample window.
  final _Motion motion;

  /// Recreate the map (fresh in-memory caches) and clear the persistent
  /// disk cache first: the scenario then measures a cold load.
  final bool cold;

  /// Record strict-viewport coverage per frame (time to covered/sharp
  /// cells, blank fraction over time).
  final bool coverage;

  _Motion get effectiveMotion => idle ? _Motion.none : motion;
}

const _scenarios = [
  _Scenario('markers_10000', markers: 10000),
  _Scenario('visible_markers_1000', markers: 1000, dense: true),
  _Scenario('route_50000', routePoints: 50000),
  _Scenario('clusters_10000', markers: 10000, clustered: true),
  _Scenario('mixed_camera', markers: 1000, routePoints: 10000, zoom: true),
];

/// Window-resize sampling: the app holds still (or moves, for the second
/// scenario) while an external driver resizes the OS window. Frame
/// percentiles then attribute resize cost separately from camera cost.
const _resizeScenarios = [
  _Scenario('resize_idle', markers: 1000, idle: true),
  _Scenario('resize_motion', markers: 1000),
];

/// Load/motion acceptance scenarios (BENCHMARK_LOAD). The cold variants
/// measure a from-scratch load (fresh caches, optionally a constrained
/// simulated network) while coverage is sampled per frame; the warm
/// variants isolate motion-frame tails from loading cost, and `follow`
/// exercises the location-following retarget path.
const _loadScenarios = [
  _Scenario('cold_static',
      markers: 1000, motion: _Motion.none, cold: true, coverage: true),
  _Scenario('cold_fling',
      markers: 1000, motion: _Motion.fling, cold: true, coverage: true),
  _Scenario('cold_pinch',
      markers: 1000, motion: _Motion.pinch, cold: true, coverage: true),
  _Scenario('warm_fling', markers: 1000, motion: _Motion.fling, coverage: true),
  _Scenario('warm_pinch', markers: 1000, motion: _Motion.pinch, coverage: true),
  _Scenario('follow', markers: 100, motion: _Motion.follow),
];

/// Fling parameters: alternating decaying pans. Velocity is
/// `v0·e^(−t/τ)`; travel integrates to `v0·τ·(1−e^(−t/τ))`. The initial
/// speed matches a fast real fling (a few tiles per second at zoom 10).
const _flingTauSeconds = 0.32;
const _flingSegmentSeconds = 1.6;
const _flingV0DegPerSec = 3.0;
final _flingMaxTravelDeg = _flingV0DegPerSec *
    _flingTauSeconds *
    (1 - math.exp(-_flingSegmentSeconds / _flingTauSeconds));

/// Pinch-reversal cadence: the zoom direction reverses every half period.
const _pinchPeriodSeconds = 1.5;
const _pinchAmplitudeLevels = 0.75;

/// Simulated-GPS cadence for the `follow` scenario.
const _followFixInterval = Duration(milliseconds: 250);

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark>
    with SingleTickerProviderStateMixin {
  final _controller = MapController();
  final _markers = MarkerManager();
  final _locations = MapLocationController();
  final _net = SimulatedNetwork(
      delayMs: _netDelayMs, kbps: _netKbps, dropEvery: _netDropEvery);
  late final AnimationController _motion;
  final _timings = <ui.FrameTiming>[];
  bool _recording = false;
  _Scenario _scenario = _scenarios.first;
  List<MapPolyline> _routes = const [];

  /// Incremented before cold scenarios so the map subtree is recreated:
  /// a fresh tile manager starts with empty in-memory caches and no jobs.
  int _mapGeneration = 0;

  /// Whether a map is mounted at all. Cold scenarios unmount entirely
  /// (nothing can load from or write to storage while it is cleared) and
  /// remount only after recording is armed, so the replacement's first
  /// load frame is the first frame of the measured window.
  bool _mapMounted = true;
  double _motionSeconds = 1;
  Timer? _followFixTimer;
  int _followFixes = 0;

  /// Per-frame coverage samples: `[elapsedMs, coveredFraction,
  /// sharpFraction]`, collected while recording coverage scenarios.
  final List<List<double>> _coverageSamples = [];
  Stopwatch? _coverageClock;

  /// Length of the last coverage recording window in ms (clock armed to
  /// clock stopped), for window-integrated means.
  double _coverageWindowMs = 0;

  BenchmarkViewportSample? _viewportSample;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this)..addListener(_move);
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTimings(List<ui.FrameTiming> frames) {
    if (!_recording) return;
    _timings.addAll(frames);
  }

  void _move() {
    final t = _motion.value * _motionSeconds;
    switch (_scenario.effectiveMotion) {
      case _Motion.loop:
        final phase = t * math.pi * 2 / math.max(1, _motionSeconds);
        _controller.moveTo(
            LatLng(
                latitude: 47 + math.sin(phase) * 0.12,
                longitude: 8 + math.cos(phase) * 0.15),
            animate: false);
        if (_scenario.zoom) {
          if (_fractional) {
            _controller.setFractionalZoom(10 + math.sin(phase), animate: false);
          } else {
            _controller.setZoom(10 + math.sin(phase).round(), animate: false);
          }
        }
      case _Motion.fling:
        _moveToFling(t);
      case _Motion.pinch:
        _controller.setFractionalZoom(
            10 +
                _pinchAmplitudeLevels *
                    math.sin(t * 2 * math.pi / _pinchPeriodSeconds),
            animate: false);
      case _Motion.none:
      case _Motion.follow:
        break; // Frames come from tile arrival / retargeting, not the ticker.
    }
  }

  /// Alternating decaying pans: deterministic per tick from closed-form
  /// integration, so interrupted/restarted drives stay identical.
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
    switch (_scenario.effectiveMotion) {
      case _Motion.none:
      case _Motion.follow:
        await Future<void>.delayed(duration);
      default:
        await _drive(duration);
    }
  }

  void _startFollow() {
    _stopFollow();
    _followFixes = 0;
    // The owned controller's follow request survives detachment (the
    // MapView honours it on attach), unlike the MapController delegate
    // path which is dropped while unmounted.
    _locations.follow();
    _followFixTimer = Timer.periodic(_followFixInterval, (_) {
      final i = _followFixes++;
      _locations.updateLocation(MapLocation(
          point: LatLng(
              latitude: 47 + 0.00030 * i + 0.00002 * math.sin(i),
              longitude: 8 + 0.00022 * i),
          accuracyMeters: 6 + 2 * math.sin(i * 0.7).abs(),
          bearing: 40,
          timestamp: DateTime.now()));
    });
  }

  void _stopFollow() {
    _followFixTimer?.cancel();
    _followFixTimer = null;
  }

  Future<void> _clearDiskCache() async {
    try {
      if (MapDiskCache.isInitialized) await MapDiskCache.clear();
    } catch (_) {
      // A failed clear turns the scenario warm; the report still says
      // cold=true, so surface it loudly instead of reporting silently.
      debugPrint('FOSM_BENCHMARK_INVALID disk-cache clear failed');
    }
  }

  Future<void> _run() async {
    final viewportSample = BenchmarkViewportSample(View.of(context));
    _viewportSample = viewportSample;
    final refresh = View.of(context).display.refreshRate;
    debugPrint('FOSM_BENCHMARK_META ${jsonEncode({
          'label': _runLabel,
          'mode': 'profile',
          'os': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'refreshHz': refresh,
          'physicalWidth': View.of(context).physicalSize.width,
          'physicalHeight': View.of(context).physicalSize.height,
          'fractionalZoom': _fractional,
          'devicePixelRatio': View.of(context).devicePixelRatio,
          'tileSource': _net.inert
              ? 'offline generated 256x256 raster; no HTTP'
              : 'offline generated 256x256 raster through simulated '
                  'network ${_net.describe()}',
          'warmupSeconds': _warmup.inSeconds,
          'sampleSeconds': _sample.inSeconds,
          'schedulerPaced': !_unpaced,
          'loadMode': _load,
          'coldMode': _cold,
          'net': _net.describe(),
        })}');
    final scenarios =
        _resize ? _resizeScenarios : (_load ? _loadScenarios : _scenarios);
    for (final scenario in scenarios) {
      _scenario = scenario;
      _stopFollow();
      _net.reset();
      final cold = scenario.cold || _cold;
      if (cold) {
        // Unmount the old map first: its state is disposed, so nothing
        // can load from or write to storage while it is cleared. (An
        // earlier shape of this sequence swapped the key while the old
        // map stayed mounted — see the review history in
        // docs/performance/results-scheduler-ios.md for the leaked-tile
        // artifact that caused.)
        setState(() => _mapMounted = false);
        await WidgetsBinding.instance.endOfFrame;
        await _clearDiskCache();
      }
      _controller.setZoom(10, animate: false);
      _controller.moveTo(_center, animate: false);
      final span = scenario.dense ? 0.16 : 4.0;
      _markers.clear();
      _markers.addAll(List.generate(scenario.markers, (i) {
        final point = LatLng(
            latitude: 47 + ((i % 100) / 99 - 0.5) * span,
            longitude: 8 +
                ((i ~/ 100) / math.max(1, (scenario.markers / 100).ceil() - 1) -
                        0.5) *
                    span);
        const child = SizedBox(
            width: 10, height: 10, child: ColoredBox(color: Colors.red));
        return scenario.clustered
            ? ClusterMarker(point: point, child: child)
            : Marker(point: point, child: child);
      }));
      _routes = scenario.routePoints == 0
          ? const []
          : [
              MapPolyline(
                  points: List.generate(scenario.routePoints, (i) {
                    final t = i / (scenario.routePoints - 1);
                    return LatLng(
                        latitude: 47 + math.sin(t * math.pi * 24) * 0.15,
                        longitude: 7.7 + t * 0.6);
                  }),
                  color: Colors.blue,
                  strokeWidth: 4)
            ];
      if (scenario.motion == _Motion.follow) _startFollow();
      // Synchronization signal for external drivers (resize scripts):
      // warmup starts now, sampling starts [BENCHMARK_SAMPLE_START].
      debugPrint('FOSM_BENCHMARK_SCENARIO ${scenario.name} '
          'warmupSeconds=${cold ? 0 : _warmup.inSeconds} '
          'sampleSeconds=${_sample.inSeconds} motion=${scenario.effectiveMotion.name} cold=$cold');
      void armRecording() {
        _timings.clear();
        viewportSample.start();
        _coverageSamples.clear();
        _coverageWindowMs = 0;
        _coverageClock = scenario.coverage ? (Stopwatch()..start()) : null;
        if (scenario.coverage) _chainCoverageSample();
        _recording = true;
        debugPrint('FOSM_BENCHMARK_SAMPLE_START ${scenario.name}');
      }

      final int rssBefore;
      if (cold) {
        // Arm recording *before* mounting the replacement: its first load
        // frame — grid build, fetch issuance, early arrivals — is then
        // the first frame of the measured window, so no cold work escapes
        // it. Controller calls above were dropped while unmounted; the
        // widget parameters already hold the scenario's start pose, and
        // the fresh generation key guarantees a fresh map state.
        if (!mounted) return;
        rssBefore = ProcessInfo.currentRss;
        armRecording();
        setState(() {
          _mapMounted = true;
          _mapGeneration++;
        });
        await WidgetsBinding.instance.endOfFrame;
      } else {
        setState(() {});
        await WidgetsBinding.instance.endOfFrame;
        // Warm scenarios drive/settle through warmup as before; the
        // follow scenario's fixes (started above) flow through warmup.
        await _runWindow(_warmup);
        // Profile mode batches frame reports. Drain warmup reports before
        // sampling.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
        rssBefore = ProcessInfo.currentRss;
        armRecording();
      }
      await _runWindow(_sample);
      if (!cold) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (!mounted) return;
      _recording = false;
      viewportSample.stop();
      final coverageClock = _coverageClock;
      coverageClock?.stop();
      _coverageWindowMs = coverageClock?.elapsedMilliseconds.toDouble() ?? 0;
      _coverageClock = null;
      debugPrint('FOSM_BENCHMARK_SAMPLE_END ${scenario.name}');
      // A resize scenario whose viewport never changed measured nothing:
      // a mistimed external driver produced zero frames (resize_idle) or
      // camera-only frames (resize_motion). Report it as invalid rather
      // than as perfect-looking numbers.
      final resized = viewportSample.changes > 0;
      final valid = !_resize || (resized && _timings.isNotEmpty);
      if (!valid) {
        debugPrint('FOSM_BENCHMARK_INVALID ${scenario.name}: no sampled '
            'frames or viewport change during sampling — check the external '
            'resize driver and SAMPLE_START/SAMPLE_END window');
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
      debugPrint('FOSM_BENCHMARK_RESULT ${jsonEncode({
            'label': _runLabel,
            'scenario': scenario.name,
            'frames': _timings.length,
            'valid': valid,
            'viewportChanges': viewportSample.changes,
            'viewportSizes': viewportSample.sizes.toList(),
            'markers': scenario.markers,
            'routePoints': scenario.routePoints,
            'motion': scenario.effectiveMotion.name,
            'cold': cold,
            'schedulerPaced': !_unpaced,
            'net': _net.describe(),
            'network': _net.stats(),
            if (scenario.coverage) 'coverage': _coverageReport(),
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
            'rssBeforeBytes': rssBefore,
            'rssAfterBytes': ProcessInfo.currentRss,
          })}');
      _stopFollow();
    }
    debugPrint('FOSM_BENCHMARK_DONE $_runLabel');
  }

  /// Chained post-frame callback: samples coverage once per rendered
  /// frame while recording, then re-arms itself. Stops with recording.
  void _chainCoverageSample() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_recording || _coverageClock == null) return;
      final coverage = _controller.tileCoverage;
      if (coverage != null) {
        _coverageSamples.add([
          _coverageClock!.elapsedMilliseconds.toDouble(),
          coverage.coveredFraction,
          coverage.sharpFraction,
        ]);
      }
      _chainCoverageSample();
    });
  }

  /// Derived coverage metrics plus a downsampled series (at most 72
  /// points; parallel arrays of elapsed ms, covered and sharp fractions).
  Map<String, Object?> _coverageReport() {
    final samples = _coverageSamples;
    int? firstWhereMs(bool Function(List<double> s) test) {
      for (final s in samples) {
        if (test(s)) return s[0].round();
      }
      return null;
    }

    var sharpMin = 1.0;
    for (final s in samples) {
      if (s[2] < sharpMin) sharpMin = s[2];
    }
    final step = samples.length <= 72 ? 1 : (samples.length / 72).ceil();
    final seriesMs = <int>[];
    final seriesCovered = <double>[];
    final seriesSharp = <double>[];
    for (var i = 0; i < samples.length; i += step) {
      seriesMs.add(samples[i][0].round());
      seriesCovered.add(_round4(samples[i][1]));
      seriesSharp.add(_round4(samples[i][2]));
    }
    if (samples.isNotEmpty &&
        (seriesMs.isEmpty || seriesMs.last != samples.last[0].round())) {
      seriesMs.add(samples.last[0].round());
      seriesCovered.add(_round4(samples.last[1]));
      seriesSharp.add(_round4(samples.last[2]));
    }
    return {
      'samples': samples.length,
      'firstCoveredMs': firstWhereMs((s) => s[1] > 0),
      'allCoveredMs': firstWhereMs((s) => s[1] >= 1),
      'allSharpMs': firstWhereMs((s) => s[2] >= 1),
      'minSharpFraction': _round4(sharpMin),
      // Window-integrated means: each sample holds until the next (with
      // boundary extension to the recording-window ends), so arms
      // publishing at different frame frequencies — or a still map whose
      // frames stop early — compare coverage over the *whole* window.
      'meanCoveredFraction':
          _round4OrNull(coverageMeanOverWindow(samples, 1, _coverageWindowMs)),
      'meanSharpFraction':
          _round4OrNull(coverageMeanOverWindow(samples, 2, _coverageWindowMs)),
      'sharpFractionEnd': samples.isEmpty ? null : _round4(samples.last[2]),
      'seriesMs': seriesMs,
      'seriesCovered': seriesCovered,
      'seriesSharp': seriesSharp,
    };
  }

  static double? _round4OrNull(double? v) => v == null ? null : _round4(v);

  static double _round4(double v) => (v * 10000).round() / 10000;

  @override
  void dispose() {
    _recording = false;
    _viewportSample?.stop();
    _stopFollow();
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    _motion.dispose();
    _markers.dispose();
    _locations.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<Uint8List> _instantTile(int z, int x, int y) async => _tile;

  @override
  Widget build(BuildContext context) => Scaffold(
      body: _mapMounted
          ? KeyedSubtree(
              key: ValueKey<int>(_mapGeneration),
              child: MapView(
                latLng: _center,
                zoom: 10,
                enableFractionalZoom: _fractional || _load,
                controller: _controller,
                locationController: _load ? _locations : null,
                markers: _markers,
                markerClusterOptions:
                    _scenario.clustered ? const MarkerClusterOptions() : null,
                polylines: _routes,
                showScaleBar: true,
                showZoomControls: false,
                tileFetcher: _net.wrap(_instantTile),
              ))
          // While unmounted (cold scenarios clearing storage) the map
          // subtree is absent entirely — its state is disposed, so no
          // loads or writes can race the clear.
          : const SizedBox.expand());
}
