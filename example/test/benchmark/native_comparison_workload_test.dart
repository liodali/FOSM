import 'dart:io';

import 'package:example/benchmark/native_comparison_workload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final workload = NativeComparisonWorkload.fromJson(
      File('benchmark/native_comparison.json').readAsStringSync());

  test('shared workload closes both camera trajectories', () {
    expect(workload.scenarios.map((s) => s.name),
        ['vector_pan', 'vector_zoom_steps']);
    for (final scenario in workload.scenarios) {
      expect(scenario.pose(0), scenario.pose(8));
      expect(scenario.pose(.5), scenario.pose(8.5));
    }
  });

  test('pan interpolates by wall time, independently of frame cadence', () {
    final pan = workload.scenarios.first;
    expect(pan.pose(1)[0], closeTo(47.03, 1e-10));
    expect(pan.pose(1)[1], closeTo(8.04, 1e-10));
    expect(pan.pose(1)[2], 10);
    pan.pose(.7); // A skipped/extra frame never changes the pose at t=1.
    expect(pan.pose(1)[0], closeTo(47.03, 1e-10));
  });

  test('zoom is held until the next waypoint', () {
    final zoom = workload.scenarios.last;
    expect(zoom.pose(1.999)[2], 10);
    expect(zoom.pose(2)[2], 11);
    expect(zoom.pose(4)[2], 10);
    expect(zoom.pose(6)[2], 9);
  });

  test('bounds expose Web Mercator extent for native scale calibration', () {
    final bounds = comparisonBounds([0, 0, 1], 256, 256);
    expect(bounds['west'], -90);
    expect(bounds['east'], 90);
    expect(bounds['north'], closeTo(66.51326044, 1e-7));
    expect(bounds['south'], closeTo(-66.51326044, 1e-7));
  });

  test('rejects malformed or non-closing trajectories', () {
    expect(
        () => ComparisonScenario('bad', [
              [0, 47, 8, 10]
            ]),
        throwsFormatException);
    expect(
        () => ComparisonScenario('bad', [
              [0, 47, 8, 10],
              [0, 47, 8, 10]
            ]),
        throwsFormatException);
    expect(
        () => ComparisonScenario('bad', [
              [0, 47, 8, 10],
              [2, 48, 8, 10]
            ]),
        throwsFormatException);
  });
}
