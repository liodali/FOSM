import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/view/polygon_layer.dart';

const _origin = LatLng(latitude: 0, longitude: 0);
const _routePoints = [
  LatLng(latitude: 0, longitude: -20),
  LatLng(latitude: 0, longitude: 20)
];
const _areaPoints = [
  LatLng(latitude: 10, longitude: -10),
  LatLng(latitude: 10, longitude: 10),
  LatLng(latitude: -10, longitude: 10),
  LatLng(latitude: -10, longitude: -10)
];
const _hole = [
  LatLng(latitude: 2, longitude: -2),
  LatLng(latitude: 2, longitude: 2),
  LatLng(latitude: -2, longitude: 2),
  LatLng(latitude: -2, longitude: -2)
];

Future<void> _map(
  WidgetTester tester, {
  ValueChanged<LatLng>? onTap,
  ValueChanged<LatLng>? onLongPress,
  List<MapPolygon> polygons = const [],
  List<MapPolyline> polylines = const [],
  MarkerManager? markers,
  MapController? controller,
  bool Function(MapNotification)? notifications,
}) =>
    tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NotificationListener<MapNotification>(
      onNotification: notifications,
      child: MapView(
          latLng: _origin,
          zoom: 3,
          animateZoom: false,
          showZoomControls: false,
          tileFetcher: (z, x, y) => Completer<Uint8List>().future,
          markers: markers,
          controller: controller,
          onTap: onTap,
          onLongPress: onLongPress,
          polygons: polygons,
          polylines: polylines),
    ))));

Future<void> _tap(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('tap positions are relative to the map inside a padded layout',
      (tester) async {
    LatLng? tapped;
    MapTapNotification? event;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Padding(
      padding: const EdgeInsets.fromLTRB(80, 40, 120, 60),
      child: NotificationListener<MapTapNotification>(
        onNotification: (notification) {
          event = notification;
          return false;
        },
        child: MapView(
            latLng: _origin,
            zoom: 3,
            showZoomControls: false,
            tileFetcher: (z, x, y) => Completer<Uint8List>().future,
            onTap: (point) => tapped = point),
      ),
    ))));
    await _tap(tester, const Offset(636, 290));
    expect(tapped!.longitude, closeTo(45, 1e-8));
    expect(tapped!.latitude, closeTo(0, 1e-8));
    expect(event!.localPosition, const Offset(556, 250));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('interactive flags enable notification-only polygon selection',
      (tester) async {
    final events = <MapNotification>[];
    var mapTaps = 0;
    const polygon = MapPolygon(points: _areaPoints, interactive: true);
    await _map(tester,
        polygons: [polygon],
        onTap: (_) => mapTaps++,
        notifications: (event) {
          events.add(event);
          return false;
        });
    await _tap(tester, const Offset(400, 300));
    expect(events.whereType<MapPolygonTapNotification>().single.hit.polygon,
        same(polygon));
    expect(mapTaps, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'map tap and long press report coordinates and distinct notifications',
      (tester) async {
    final taps = <LatLng>[];
    final holds = <LatLng>[];
    final events = <MapNotification>[];
    await _map(tester, onTap: taps.add, onLongPress: holds.add,
        notifications: (event) {
      events.add(event);
      return false;
    });
    await _tap(tester, const Offset(656, 300));
    expect(taps.single.longitude, closeTo(45, 1e-8));
    expect(taps.single.latitude, closeTo(0, 1e-8));
    expect(events.whereType<MapTapNotification>().single.localPosition,
        const Offset(656, 300));
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(holds.single, _origin);
    expect(taps, hasLength(1));
    expect(events.whereType<MapLongPressNotification>(), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('route wins over polygon; markers win over routes',
      (tester) async {
    final log = <String>[];
    final markers = MarkerManager();
    final polygon =
        MapPolygon(points: _areaPoints, onTap: (_) => log.add('polygon'));
    final route = MapPolyline(
        points: _routePoints,
        onTap: (hit) {
          expect(hit.distancePixels, closeTo(0, 1e-8));
          log.add('route');
        });
    await _map(tester,
        markers: markers,
        polygons: [polygon],
        polylines: [route],
        onTap: (_) => log.add('map'));
    await _tap(tester, const Offset(400, 300));
    expect(log, ['route']);
    markers.add(Marker(
        point: _origin,
        child: const SizedBox(width: 40, height: 40),
        onTap: () => log.add('marker')));
    await tester.pump();
    await _tap(tester, const Offset(400, 300));
    expect(log, ['route', 'marker']);
    await _tap(tester, const Offset(430, 270));
    expect(log.last, 'polygon');
    await _tap(tester, const Offset(650, 450));
    expect(log.last, 'map');
    await tester.pumpWidget(const SizedBox.shrink());
    markers.dispose();
  });

  testWidgets(
      'decorative routes and polygon holes allow map taps; updates replace shapes',
      (tester) async {
    var maps = 0;
    var areas = 0;
    final polygon = MapPolygon(
        points: _areaPoints, holes: const [_hole], onTap: (_) => areas++);
    await _map(tester,
        onTap: (_) => maps++,
        polygons: [polygon],
        polylines: const [MapPolyline(points: _routePoints)]);
    await _tap(tester, const Offset(400, 300));
    expect(maps, 1);
    expect(areas, 0);
    await _tap(tester, const Offset(430, 270));
    expect(areas, 1);
    await _map(tester, onTap: (_) => maps++);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is CustomPaint && widget.painter is PolygonPainter),
        findsNothing);
    await _tap(tester, const Offset(430, 270));
    expect(maps, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'features select correctly after camera movement and zoom; drag is not a tap',
      (tester) async {
    var routes = 0;
    var maps = 0;
    final controller = MapController();
    final route = MapPolyline(points: _routePoints, onTap: (_) => routes++);
    await _map(tester,
        controller: controller, polylines: [route], onTap: (_) => maps++);
    controller.moveTo(const LatLng(latitude: 0, longitude: 5), animate: false);
    controller.setZoom(5, animate: false);
    await tester.pump();
    await _tap(tester, const Offset(400, 300));
    expect(routes, 1);
    await tester.dragFrom(const Offset(400, 300), const Offset(100, 80));
    await tester.pump(const Duration(milliseconds: 350));
    expect(routes, 1);
    expect(maps, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
      'interactive feature long press sends its own event, not a map event',
      (tester) async {
    var holds = 0;
    var maps = 0;
    final events = <MapNotification>[];
    await _map(tester,
        polylines: [
          MapPolyline(points: _routePoints, onLongPress: (_) => holds++)
        ],
        onLongPress: (_) => maps++,
        notifications: (event) {
          events.add(event);
          return false;
        });
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pump();
    expect(holds, 1);
    expect(maps, 0);
    expect(events.whereType<MapPolylineLongPressNotification>(), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
