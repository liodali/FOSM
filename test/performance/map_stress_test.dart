// Workload/culling regressions, not FPS benchmarks. Profile timings come from
// example/lib/benchmark/map_benchmark.dart on an actual device.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

class _Probe extends StatelessWidget {
  const _Probe(this.onBuild);
  final VoidCallback onBuild;
  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 10, height: 10);
  }
}

void main() {
  testWidgets('10000 markers build only those in the viewport', (tester) async {
    final markers = MarkerManager();
    final controller = MapController();
    var builds = 0;
    markers.addAll(List.generate(
        10000,
        (i) => Marker(
              point: LatLng(latitude: 0, longitude: i < 20 ? 0 : 80),
              child: _Probe(() => builds++),
            )));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 10,
      markers: markers,
      controller: controller,
      showZoomControls: false,
      tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
    ))));
    expect(builds, 20);
    expect(find.byType(_Probe), findsNWidgets(20));
    controller.moveTo(const LatLng(latitude: 0, longitude: 20), animate: false);
    await tester.pump();
    expect(find.byType(_Probe), findsNothing);
    expect(builds, 20, reason: 'offscreen widgets must not build during a pan');
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
    controller.dispose();
  });

  testWidgets('50000-point route renders and remains selectable',
      (tester) async {
    MapPolylineHit? hit;
    final points = List.generate(50000, (i) {
      final x = i / 49999;
      return LatLng(
          latitude: math.sin(x * math.pi * 12) * 0.1,
          longitude: -0.4 + x * 0.8);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 10,
      polylines: [MapPolyline(points: points, onTap: (value) => hit = value)],
      showZoomControls: false,
      tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
    ))));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 350));
    expect(hit, isNotNull);
    expect(hit!.distancePixels, lessThan(1));
    expect(hit!.segmentIndex, inInclusiveRange(24990, 25010));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
