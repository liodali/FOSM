// Matched camera/vector workload for plan 12. Run in profile mode.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:fosm/fosm.dart';

import 'native_comparison_workload.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kProfileMode) throw StateError('Use --profile for comparison captures');
  await initMap();
  final workload = NativeComparisonWorkload.fromJson(
      await rootBundle.loadString('benchmark/native_comparison.json'));
  runApp(MaterialApp(home: NativeComparison(workload: workload)));
}

class NativeComparison extends StatefulWidget {
  const NativeComparison({super.key, required this.workload});
  final NativeComparisonWorkload workload;

  @override
  State<NativeComparison> createState() => _NativeComparisonState();
}

class _NativeComparisonState extends State<NativeComparison>
    with SingleTickerProviderStateMixin {
  final _controller = MapController();
  final _timings = <ui.FrameTiming>[];
  late final Ticker _ticker;
  late ComparisonScenario _scenario;
  bool _recording = false;
  final _clock = Stopwatch();
  int? _lastZoom;

  @override
  void initState() {
    super.initState();
    _scenario = widget.workload.scenarios.first;
    _ticker = createTicker((_) => _move());
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    if (_recording) _timings.addAll(timings);
  }

  void _move() {
    final p = _scenario.pose(_clock.elapsedMicroseconds / 1e6);
    final zoom = p[2].toInt();
    if (_lastZoom != zoom) {
      _lastZoom = zoom;
      _controller.setZoom(zoom, animate: false);
    }
    _controller.moveTo(LatLng(latitude: p[0], longitude: p[1]), animate: false);
  }

  Future<void> _window(double seconds) async {
    _lastZoom = null;
    _clock.reset();
    _clock.start();
    _move();
    _ticker.start();
    await Future<void>.delayed(Duration(microseconds: (seconds * 1e6).round()));
    _ticker.stop();
    _clock.stop();
  }

  Future<void> _run() async {
    final view = View.of(context);
    debugPrint('FOSM_NATIVE_COMPARE_META ${jsonEncode({
          'engine': 'flutter',
          'mode': 'profile',
          'sourceRevision': const String.fromEnvironment('BENCHMARK_REVISION',
              defaultValue: 'unrecorded'),
          'workload': widget.workload.document,
          'physicalWidth': view.physicalSize.width,
          'physicalHeight': view.physicalSize.height,
          'devicePixelRatio': view.devicePixelRatio,
          'refreshHz': view.display.refreshRate,
          'presentationMeasured': false,
          'cachePolicy': 'process warmup; persistent cache uncontrolled',
        })}');
    for (final scenario in widget.workload.scenarios) {
      _scenario = scenario;
      await _window(widget.workload.warmupSeconds);
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      _timings.clear();
      _recording = true;
      debugPrint('FOSM_NATIVE_COMPARE_START ${scenario.name}');
      debugPrint('FOSM_NATIVE_COMPARE_BOUNDS ${jsonEncode({
            'scenario': scenario.name,
            ...comparisonBounds(
                scenario.pose(0),
                view.physicalSize.width / view.devicePixelRatio,
                view.physicalSize.height / view.devicePixelRatio),
          })}');
      await _window(widget.workload.sampleSeconds);
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      _recording = false;
      double? percentile(Iterable<int> values, double p) {
        final sorted = values.toList()..sort();
        if (sorted.isEmpty) return null;
        return sorted[((sorted.length - 1) * p).round()] / 1000;
      }

      debugPrint('FOSM_NATIVE_COMPARE_RESULT ${jsonEncode({
            'scenario': scenario.name,
            'frames': _timings.length,
            'uiP95Ms': percentile(
                _timings.map((f) => f.buildDuration.inMicroseconds), .95),
            'uiP99Ms': percentile(
                _timings.map((f) => f.buildDuration.inMicroseconds), .99),
            'rasterP95Ms': percentile(
                _timings.map((f) => f.rasterDuration.inMicroseconds), .95),
            'rasterP99Ms': percentile(
                _timings.map((f) => f.rasterDuration.inMicroseconds), .99),
            'sharpFractionEnd': _controller.tileCoverage?.sharpFraction,
            'retainedBytesEnd':
                _controller.memoryAttribution?.estimatedTotalBytes,
          })}');
    }
    debugPrint('FOSM_NATIVE_COMPARE_DONE flutter');
  }

  @override
  void dispose() {
    _recording = false;
    _ticker.dispose();
    _controller.dispose();
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.workload.scenarios.first.pose(0);
    return Scaffold(
        body: MapView(
      controller: _controller,
      latLng: LatLng(latitude: p[0], longitude: p[1]),
      zoom: p[2].toInt(),
      animateZoom: false,
      showZoomControls: false,
      showScaleBar: false,
      vectorStyle: VectorMapStyle(
          id: 'native-comparison', styleUrl: widget.workload.styleUrl),
    ));
  }
}
