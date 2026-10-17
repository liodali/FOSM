// Native profile-mode benchmark. See docs/performance/README.md.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fosm/fosm.dart';

const _runLabel =
    String.fromEnvironment('BENCHMARK_LABEL', defaultValue: 'baseline');
const _fractional = bool.fromEnvironment('BENCHMARK_FRACTIONAL');
const _warmup = Duration(seconds: 2);
const _sample = Duration(seconds: 6);
const _center = LatLng(latitude: 47, longitude: 8);
late Uint8List _tile;

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
      this.zoom = false});
  final String name;
  final int markers;
  final int routePoints;
  final bool clustered;
  final bool dense;
  final bool zoom;
}

const _scenarios = [
  _Scenario('markers_10000', markers: 10000),
  _Scenario('visible_markers_1000', markers: 1000, dense: true),
  _Scenario('route_50000', routePoints: 50000),
  _Scenario('clusters_10000', markers: 10000, clustered: true),
  _Scenario('mixed_camera', markers: 1000, routePoints: 10000, zoom: true),
];

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark>
    with SingleTickerProviderStateMixin {
  final _controller = MapController();
  final _markers = MarkerManager();
  late final AnimationController _motion;
  final _timings = <ui.FrameTiming>[];
  bool _recording = false;
  _Scenario _scenario = _scenarios.first;
  List<MapPolyline> _routes = const [];

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this)..addListener(_move);
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTimings(List<ui.FrameTiming> frames) {
    if (_recording) _timings.addAll(frames);
  }

  void _move() {
    final phase = _motion.value * math.pi * 2;
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
  }

  Future<void> _drive(Duration duration) async {
    _motion.duration = duration;
    await _motion.forward(from: 0);
  }

  Future<void> _run() async {
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
          'tileSource': 'offline generated 256x256 raster; no HTTP',
          'warmupSeconds': _warmup.inSeconds,
          'sampleSeconds': _sample.inSeconds,
        })}');
    for (final scenario in _scenarios) {
      _scenario = scenario;
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
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      await _drive(_warmup);
      // Profile mode batches frame reports. Drain warmup reports before sampling.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final rssBefore = ProcessInfo.currentRss;
      _timings.clear();
      _recording = true;
      await _drive(_sample);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      _recording = false;
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
            'markers': scenario.markers,
            'routePoints': scenario.routePoints,
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
    }
    debugPrint('FOSM_BENCHMARK_DONE $_runLabel');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    _motion.dispose();
    _markers.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          body: MapView(
        latLng: _center,
        zoom: 10,
        enableFractionalZoom: _fractional,
        controller: _controller,
        markers: _markers,
        markerClusterOptions:
            _scenario.clustered ? const MarkerClusterOptions() : null,
        polylines: _routes,
        showScaleBar: true,
        showZoomControls: false,
        tileFetcher: (_, __, ___) async => _tile,
      ));
}
