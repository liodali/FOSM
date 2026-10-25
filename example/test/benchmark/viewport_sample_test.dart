import 'package:example/benchmark/viewport_sample.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('counts the first resize before any timing report',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    final sample = BenchmarkViewportSample(tester.view);
    addTearDown(sample.stop);

    sample.start();
    expect(sample.changes, 0);
    expect(sample.sizes, hasLength(1));

    tester.view.physicalSize = const Size(1280, 800);
    expect(sample.changes, 1);
    expect(sample.sizes, hasLength(2));
  });

  testWidgets('counts a resize and return without timing reports',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    final sample = BenchmarkViewportSample(tester.view);
    addTearDown(sample.stop);

    sample.start();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.physicalSize = const Size(800, 600);
    expect(sample.changes, 2);
    expect(sample.sizes, hasLength(2));
  });

  testWidgets('unchanged metrics do not count as a resize', (tester) async {
    final sample = BenchmarkViewportSample(tester.view);
    addTearDown(sample.stop);

    sample.start();
    tester.binding.handleMetricsChanged();
    tester.binding.handleMetricsChanged();
    expect(sample.changes, 0);
    expect(sample.sizes, hasLength(1));
  });

  testWidgets('counts DPR changes only inside each sampling window',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final sample = BenchmarkViewportSample(tester.view);
    addTearDown(sample.stop);

    sample.start();
    tester.view.devicePixelRatio = 2;
    expect(sample.changes, 1);
    sample.stop();
    tester.view.devicePixelRatio = 3;
    expect(sample.changes, 1);
    expect(sample.sizes, hasLength(2));

    sample.start();
    expect(sample.changes, 0);
    expect(sample.sizes, hasLength(1));
    tester.view.devicePixelRatio = 1;
    expect(sample.changes, 1);
  });
}
