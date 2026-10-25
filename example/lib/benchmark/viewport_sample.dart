import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

/// Records viewport changes independently of batched frame-timing reports.
class BenchmarkViewportSample with WidgetsBindingObserver {
  BenchmarkViewportSample(this.view);

  final FlutterView view;
  final Set<String> sizes = {};
  int changes = 0;
  String? _lastKey;
  bool _recording = false;

  void start() {
    stop();
    changes = 0;
    sizes.clear();
    _lastKey = null;
    _track(); // Seed the baseline before the driver receives SAMPLE_START.
    _recording = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    if (!_recording) return;
    _recording = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeMetrics() {
    if (_recording) _track();
  }

  void _track() {
    final key = '${view.physicalSize.width}'
        'x${view.physicalSize.height}@${view.devicePixelRatio}';
    if (_lastKey != null && key != _lastKey) changes++;
    _lastKey = key;
    sizes.add(key);
  }
}
