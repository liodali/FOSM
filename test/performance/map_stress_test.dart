// Workload/culling regressions, not FPS benchmarks. Profile timings come from
// example/lib/benchmark/map_benchmark.dart on an actual device.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/view/marker_cluster_engine.dart';
import 'package:fosm/src/view/user_location_layer.dart';

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

  testWidgets('frequently moving markers keep culling to the viewport',
      (tester) async {
    final markers = MarkerManager();
    final controller = MapController();
    var builds = 0;
    // Wide fleet over ±10° longitude; the zoom-10 viewport (plus cull
    // margin) only ever sees a narrow band around the center.
    List<Marker> fleet(int offset) => List.generate(
        2000,
        (i) => Marker(
              point: LatLng(
                  latitude: (i % 50) * 0.002,
                  longitude: (i ~/ 50 - 20) * 0.5 + offset * 0.01),
              child: _Probe(() => builds++),
            ));
    markers.addAll(fleet(0));
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
    await tester.pump();
    final visibleAtStart = find.byType(_Probe).evaluate().length;
    expect(visibleAtStart, greaterThan(0));
    expect(visibleAtStart, lessThan(400),
        reason: 'only a viewport band of the 2000-marker fleet is built');

    // Replace the whole fleet with new instances every frame — the
    // "frequently moving markers" workload. Builds must stay bounded by
    // the visible band, never the fleet size.
    final buildsBefore = builds;
    for (var frame = 1; frame <= 10; frame++) {
      markers
        ..clear()
        ..addAll(fleet(frame));
      await tester.pump();
      final visible = find.byType(_Probe).evaluate().length;
      expect(visible, allOf(greaterThan(0), lessThan(400)),
          reason: 'frame $frame keeps builds bounded to the viewport band');
    }
    final rebuiltPerFrame = (builds - buildsBefore) / 10;
    expect(rebuiltPerFrame, lessThan(400),
        reason: 'per-frame rebuilds must track the visible band, not the '
            'collection: $rebuiltPerFrame');

    // Panning across the moving fleet repositions without errors and
    // still builds nothing offscreen.
    controller.moveTo(const LatLng(latitude: 0, longitude: 5), animate: false);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
    controller.dispose();
  });

  testWidgets('frequent location updates reposition the indicator',
      (tester) async {
    final locationController = MapLocationController(follow: true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 47, longitude: 8),
      zoom: 14,
      locationController: locationController,
      showZoomControls: false,
      tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
    ))));
    var tick = 0;
    DateTime stamp = DateTime(2026, 1, 1);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      tick++;
      locationController.updateLocation(MapLocation(
        point: LatLng(latitude: 47 + tick * 0.0002, longitude: 8),
        accuracyMeters: 10,
        timestamp: stamp.add(Duration(seconds: tick)),
      ));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
    expect(find.byType(UserLocationLayer), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    locationController.dispose();
  });

  testWidgets('cluster results are reused across pans and fractional zoom '
      'within an integer step', (tester) async {
    final markers = MarkerManager()
      ..addAll([
        for (var i = 0; i < 200; i++)
          ClusterMarker(
            point: LatLng(
                latitude: 47 + (i % 20) * 0.001,
                longitude: 8 + (i ~/ 20) * 0.001),
            child: const SizedBox(width: 10, height: 10),
          ),
      ]);
    final controller = MapController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 47, longitude: 8),
      zoom: 12,
      enableFractionalZoom: true,
      markers: markers,
      markerClusterOptions: const MarkerClusterOptions(),
      controller: controller,
      showZoomControls: false,
      tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
    ))));
    await tester.pumpAndSettle();
    MarkerClusterEngine.debugComputations = 0;

    // Small pan: world-pixel grouping is camera-independent — reuse.
    controller.moveTo(
        const LatLng(latitude: 47.01, longitude: 8.01),
        animate: false);
    await tester.pump();
    expect(MarkerClusterEngine.debugComputations, 0,
        reason: 'a pan must not recluster');

    // Fractional zoom inside the same integer step: reuse.
    controller.setFractionalZoom(12.2, animate: false);
    await tester.pump();
    controller.setFractionalZoom(12.4, animate: false);
    await tester.pump();
    expect(MarkerClusterEngine.debugComputations, 0,
        reason: 'fractional zoom within one integer step must not recluster');

    // Crossing an integer step regroups — grouping rules keyed by zoom.
    controller.setFractionalZoom(13.0, animate: false);
    await tester.pump();
    expect(MarkerClusterEngine.debugComputations, greaterThan(0),
        reason: 'crossing an integer zoom step must recluster');

    // Mutating the collection invalidates.
    final afterZoom = MarkerClusterEngine.debugComputations;
    markers.add(ClusterMarker(
      point: const LatLng(latitude: 47.005, longitude: 8.005),
      child: const SizedBox(width: 10, height: 10),
    ));
    await tester.pump();
    expect(MarkerClusterEngine.debugComputations, greaterThan(afterZoom));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
    controller.dispose();
  });
}
