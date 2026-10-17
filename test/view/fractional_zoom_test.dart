import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/view/marker_layer.dart';
import 'package:fosm/src/view/render.dart';

const _center = LatLng(latitude: 0, longitude: 0);

TileManager _manager({LatLngBounds? bounds}) => TileManager.init(
    width: 800,
    height: 600,
    centerLatLng: _center,
    zoom: 10,
    cameraBounds: bounds,
    preloadAdjacentZoom: false,
    fetcher: (_, __, ___) => Completer<Uint8List>().future);

Future<void> _map(
  WidgetTester tester,
  MapController controller, {
  double? zoom,
  MarkerManager? markers,
  ValueChanged<double>? onZoom,
  List<MapPolyline> lines = const [],
  ValueChanged<LatLng>? onTap,
  bool enabled = true,
}) =>
    tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: _center,
      zoom: 10,
      fractionalZoom: zoom,
      enableFractionalZoom: enabled,
      controller: controller,
      markers: markers,
      showZoomControls: true,
      showScaleBar: true,
      polylines: lines,
      onTap: onTap,
      onFractionalZoomChanged: onZoom,
      tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
    ))));

GestureDetector _gestures(WidgetTester tester) =>
    tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));

void main() {
  test('projection and inverse agree across tile grid boundaries', () {
    final manager = _manager();
    addTearDown(manager.dispose);
    for (final zoom in [9.1, 9.49, 9.51, 10.25, 10.75, 11.99]) {
      manager.setCameraZoom(zoom);
      expect(manager.zoom, zoom.round());
      expect(manager.cameraZoom, zoom);
      expect(manager.renderedTileWidth,
          closeTo(256 * math.pow(2, zoom - zoom.round()), 1e-8));
      const point = LatLng(latitude: 0.1, longitude: 0.2);
      final roundtrip = manager.screenToLatLng(manager.latLngToScreen(point));
      expect(roundtrip.latitude, closeTo(point.latitude, 1e-8));
      expect(roundtrip.longitude, closeTo(point.longitude, 1e-8));
    }
  });

  test('focal point stays fixed through repeated fractional grid changes', () {
    final manager = _manager();
    addTearDown(manager.dispose);
    const focal = Offset(560, 230);
    final point = manager.screenToLatLng(focal);
    for (final zoom in [10.1, 10.49, 10.51, 11.25, 9.3, 10.0]) {
      manager.setCameraZoom(zoom, focalPoint: focal);
      expect((manager.latLngToScreen(point) - focal).distance, lessThan(1e-6));
    }
  });

  test('fractional camera bounds use the scaled viewport extent', () {
    final bounds = LatLngBounds(
        southwest: const LatLng(latitude: -1, longitude: -1),
        northeast: const LatLng(latitude: 1, longitude: 1));
    final manager = _manager(bounds: bounds);
    addTearDown(manager.dispose);
    for (final zoom in [9.49, 9.51, 10.25, 11.7]) {
      manager.setCameraZoom(zoom);
      manager.setCenterFromTileCoords(0, 0);
      final topLeft = manager.screenToLatLng(Offset.zero);
      expect(topLeft.longitude, closeTo(-1, 1e-7));
      expect(topLeft.latitude, closeTo(1, 1e-7));
      manager.setCenterFromTileCoords(1e9, 1e9);
      final bottomRight = manager.screenToLatLng(const Offset(800, 600));
      expect(bottomRight.longitude, closeTo(1, 1e-7));
      expect(bottomRight.latitude, closeTo(-1, 1e-7));
    }
  });

  test('scale changes invalidate grid once; repeated calculate stays cheap',
      () {
    final manager = _manager();
    addTearDown(manager.dispose);
    manager.calculate();
    final start = manager.gridRevision;
    manager.setCameraZoom(10.25);
    expect(manager.gridRevision, start + 1);
    final generation = manager.generation;
    for (var i = 0; i < 100; i++) {
      manager.calculate();
    }
    expect(manager.gridRevision, start + 1);
    expect(manager.generation, generation);
    manager.setCameraZoom(10.25);
    expect(manager.gridRevision, start + 1);
    manager.setZoom(10);
    expect(manager.cameraZoom, 10);
    expect(manager.renderedTileWidth, 256);
  });

  test('invalid zoom is rejected without corrupting the camera', () {
    final manager = _manager();
    addTearDown(manager.dispose);
    for (final value in [double.nan, double.infinity, -1.0, 30.1]) {
      expect(() => manager.setCameraZoom(value), throwsArgumentError);
      expect(manager.cameraZoom, 10);
    }
  });

  testWidgets('controller exposes exact zoom while tile requests stay integer',
      (tester) async {
    final controller = MapController();
    final changes = <double>[];
    await _map(tester, controller, onZoom: changes.add);
    controller.setFractionalZoom(10.25, animate: false);
    await tester.pump();
    expect(controller.fractionalZoom, 10.25);
    expect(controller.zoom, 10);
    expect(changes, [10.25]);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<RenderCanvasOSM>()
        .single;
    expect(painter.tileScale, closeTo(math.pow(2, 0.25), 1e-8));
    controller.setFractionalZoom(100, animate: false);
    expect(controller.fractionalZoom, 19);
    controller.setFractionalZoom(-10, animate: false);
    expect(controller.fractionalZoom, 1);
    expect(() => controller.setFractionalZoom(double.nan), throwsArgumentError);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'markers keep screen size and remain tappable at fractional positions',
      (tester) async {
    final controller = MapController();
    final markers = MarkerManager();
    var taps = 0;
    markers.add(Marker(
        point: const LatLng(latitude: 0, longitude: 0.1),
        onTap: () => taps++,
        child: const SizedBox(key: ValueKey('pin'), width: 30, height: 40)));
    await _map(tester, controller, markers: markers);
    final old = tester.getCenter(find.byKey(const ValueKey('pin')));
    controller.setFractionalZoom(10.25, animate: false);
    await tester.pump();
    final position = tester.getCenter(find.byKey(const ValueKey('pin')));
    expect(
        position.dx - 400, closeTo((old.dx - 400) * math.pow(2, 0.25), 1e-6));
    expect(
        tester.getSize(find.byKey(const ValueKey('pin'))), const Size(30, 40));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 350));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
  });

  testWidgets('pinch applies cumulative fractional scale and focal drift',
      (tester) async {
    final controller = MapController();
    final markers = MarkerManager();
    await _map(tester, controller, zoom: 10.2, markers: markers);
    final manager =
        tester.widget<MarkerLayer>(find.byType(MarkerLayer)).manager;
    final gestures = _gestures(tester);
    const start = Offset(500, 280);
    final point = manager.screenToLatLng(start);
    gestures
        .onScaleStart!(ScaleStartDetails(focalPoint: start, pointerCount: 2));
    const next = Offset(510, 290);
    gestures.onScaleUpdate!(
        ScaleUpdateDetails(focalPoint: next, scale: 1.2, pointerCount: 2));
    expect(controller.fractionalZoom,
        closeTo(10.2 + math.log(1.2) / math.ln2, 1e-8));
    expect((manager.latLngToScreen(point) - next).distance, lessThan(1e-6));
    gestures.onScaleUpdate!(
        ScaleUpdateDetails(focalPoint: next, scale: 2, pointerCount: 2));
    expect(controller.fractionalZoom, closeTo(11.2, 1e-8));
    expect((manager.latLngToScreen(point) - next).distance, lessThan(1e-6));
    gestures.onScaleEnd!(ScaleEndDetails());
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
  });

  testWidgets('wheel deltas zoom continuously and keep the cursor anchored',
      (tester) async {
    final controller = MapController();
    final markers = MarkerManager();
    await _map(tester, controller, markers: markers);
    final manager =
        tester.widget<MarkerLayer>(find.byType(MarkerLayer)).manager;
    const focal = Offset(500, 300);
    final point = manager.screenToLatLng(focal);
    await tester.sendEventToBinding(
        const PointerScrollEvent(position: focal, scrollDelta: Offset(0, -25)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(controller.fractionalZoom, closeTo(10.25, 1e-8));
    expect((manager.latLngToScreen(point) - focal).distance, lessThan(1e-6));
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
  });

  testWidgets(
      'zoom animation has intermediate camera values and touch stops it',
      (tester) async {
    final controller = MapController();
    await _map(tester, controller);
    controller.setFractionalZoom(11.5);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175));
    expect(controller.fractionalZoom, closeTo(10.75, 0.01));
    final finger = await tester.startGesture(const Offset(400, 300));
    final stopped = controller.fractionalZoom;
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.fractionalZoom, stopped);
    await finger.up();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'controlled zoom updates, echoes and disabling preserve a coherent camera',
      (tester) async {
    final controller = MapController();
    await _map(tester, controller, zoom: 10.3);
    expect(controller.fractionalZoom, 10.3);
    await _map(tester, controller, zoom: 10.8);
    expect(controller.fractionalZoom, 10.8);
    expect(controller.zoom, 11);
    await _map(tester, controller, enabled: false);
    expect(controller.fractionalZoom, 11);
    controller.setFractionalZoom(11.2, animate: false);
    expect(controller.fractionalZoom, 11.2,
        reason:
            'explicit continuous controller commands enable the camera capability');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fitBounds uses fractional zoom and honors asymmetric padding',
      (tester) async {
    final controller = MapController();
    final markers = MarkerManager();
    await _map(tester, controller, markers: markers);
    final manager =
        tester.widget<MarkerLayer>(find.byType(MarkerLayer)).manager;
    final bounds = LatLngBounds(
        southwest: const LatLng(latitude: -0.2, longitude: -0.3),
        northeast: const LatLng(latitude: 0.2, longitude: 0.3));
    const padding = EdgeInsets.fromLTRB(100, 40, 20, 60);
    controller.fitBounds(bounds, padding: padding, animate: false);
    final topLeft =
        manager.latLngToScreen(const LatLng(latitude: 0.2, longitude: -0.3));
    final bottomRight =
        manager.latLngToScreen(const LatLng(latitude: -0.2, longitude: 0.3));
    expect(topLeft.dx, greaterThanOrEqualTo(100 - 1e-6));
    expect(topLeft.dy, greaterThanOrEqualTo(40 - 1e-6));
    expect(bottomRight.dx, lessThanOrEqualTo(780 + 1e-6));
    expect(bottomRight.dy, lessThanOrEqualTo(540 + 1e-6));
    expect(
        (controller.fractionalZoom! - controller.fractionalZoom!.round()).abs(),
        greaterThan(0.01));
    controller.setFractionalZoom(10, animate: false);
    controller.fitBounds(bounds, padding: padding);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175));
    final middle = controller.fractionalZoom!;
    await tester.pump(const Duration(milliseconds: 175));
    expect(controller.fractionalZoom, isNot(closeTo(middle, 1e-6)));
    expect(
        manager.latLngToScreen(const LatLng(latitude: -0.2, longitude: 0.3)).dx,
        lessThanOrEqualTo(780 + 1e-6));
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
  });

  testWidgets(
      'camera notifications expose fractional zoom without changing integer fields',
      (tester) async {
    final controller = MapController();
    MapCameraChangeNotification? camera;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NotificationListener<MapCameraChangeNotification>(
                onNotification: (value) {
                  camera = value;
                  return false;
                },
                child: MapView(
                    latLng: _center,
                    zoom: 10,
                    controller: controller,
                    enableFractionalZoom: true,
                    showZoomControls: false,
                    tileFetcher: (_, __, ___) =>
                        Completer<Uint8List>().future)))));
    controller.setFractionalZoom(10.3, animate: false);
    expect(camera!.zoom, 10);
    expect(camera!.fractionalZoom, 10.3);
    expect(const MapCameraChangeNotification(_center, 8).fractionalZoom, 8);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'fractional callback echoes keep animations running and controls usable near max',
      (tester) async {
    final controller = MapController();
    var exact = 10.8;
    var integer = 11;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, update) => MapView(
        latLng: _center,
        zoom: integer,
        minZoom: 9,
        maxZoom: 11,
        fractionalZoom: exact,
        controller: controller,
        onZoomChanged: (value) => update(() => integer = value),
        onFractionalZoomChanged: (value) => update(() => exact = value),
        tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
      ),
    ))));
    await tester.tap(find.byIcon(Icons.add));
    // The map's double-tap recognizer resolves the tap arena first.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175));
    expect(controller.fractionalZoom, closeTo(10.9, 0.01));
    await tester.pump(const Duration(milliseconds: 175));
    expect(controller.fractionalZoom, 11);
    expect(exact, 11);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'single-pointer fling retains screen-pixel speed at fractional zoom',
      (tester) async {
    final controller = MapController();
    final markers = MarkerManager();
    await _map(tester, controller, zoom: 10.25, markers: markers);
    final manager =
        tester.widget<MarkerLayer>(find.byType(MarkerLayer)).manager;
    await tester.flingFrom(const Offset(300, 300), const Offset(100, 0), 1000);
    await tester.pump();
    final release = manager.centerTileLng;
    await tester.pump(const Duration(milliseconds: 100));
    final pixels =
        (release - manager.centerTileLng) * manager.renderedTileWidth;
    expect(pixels, inInclusiveRange(50, 110));
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
  });

  testWidgets('feature selection uses the scaled projection', (tester) async {
    final controller = MapController();
    MapPolylineHit? route;
    await _map(tester, controller, zoom: 10.4, lines: [
      MapPolyline(points: const [
        LatLng(latitude: 0, longitude: -0.2),
        LatLng(latitude: 0, longitude: 0.2)
      ], onTap: (hit) => route = hit)
    ]);
    await tester.tapAt(const Offset(430, 306));
    await tester.pump(const Duration(milliseconds: 350));
    expect(route, isNotNull);
    expect(route!.distancePixels, closeTo(6, 1e-6));
    expect(route!.nearestPoint.longitude,
        closeTo(30 * 360 / (256 * math.pow(2, 10.4)), 1e-8));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
