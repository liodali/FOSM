import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/map_controller.dart';

const _center = LatLng(latitude: 0, longitude: 0);
const _testZoom = 3;

final Uint8List _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00,
  0x1F, 0x15, 0xC4, 0x89,
  0x00, 0x00, 0x00, 0x0A,
  0x49, 0x44, 0x41, 0x54,
  0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
  0x0D, 0x0A, 0x2D, 0xB4,
  0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82,
]);

Future<Uint8List> _stubFetcher(int z, int x, int y) async => _tinyPng;

Future<void> _pumpMap(
  WidgetTester tester, {
  MapController? controller,
  MarkerManager? markers,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MapView(
          controller: controller,
          latLng: _center,
          zoom: _testZoom,
          tileFetcher: _stubFetcher,
          markers: markers,
          animateZoom: false,
        ),
      ),
    ),
  );
}

class _FakeDelegate implements MapControllerDelegate {
  final _calls = <String>[];
  LatLng _centerValue = _center;
  int _zoomValue = _testZoom;
  MarkerManager? _markerManager;

  @override
  LatLng get center => _centerValue;

  @override
  int get zoom => _zoomValue;

  @override
  MarkerManager? get markerManager => _markerManager;

  @override
  void moveTo(LatLng latLng, {bool animate = true}) {
    _calls.add('moveTo $animate');
    _centerValue = latLng;
  }

  @override
  void setZoom(int zoom, {bool animate = true}) {
    _calls.add('setZoom $zoom $animate');
    _zoomValue = zoom;
  }

  @override
  void zoomBy(int delta, {bool animate = true}) {
    _calls.add('zoomBy $delta $animate');
    _zoomValue += delta;
  }
}

void main() {
  group('MapController lifecycle', () {
    test('starts detached', () {
      final controller = MapController();
      expect(controller.isAttached, isFalse);
      expect(controller.center, isNull);
      expect(controller.zoom, isNull);
    });

    test('attach/detach update isAttached and notify listeners', () {
      final controller = MapController();
      final delegate = _FakeDelegate();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.attach(delegate);
      expect(controller.isAttached, isTrue);
      expect(controller.center, _center);
      expect(controller.zoom, _testZoom);
      expect(notifications, 1);

      controller.detach(delegate);
      expect(controller.isAttached, isFalse);
      expect(notifications, 2);
    });

    test('detach is idempotent', () {
      final controller = MapController();
      final delegate = _FakeDelegate();
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.detach(delegate);
      controller.detach(delegate);
      expect(notifications, 0);
    });
  });

  group('MapController camera methods', () {
    test('zoomIn zoomOut setZoom moveTo delegate to attached delegate', () {
      final controller = MapController();
      final delegate = _FakeDelegate();
      controller.attach(delegate);

      controller.zoomIn();
      expect(delegate._calls, ['zoomBy 1 true']);
      expect(controller.zoom, _testZoom + 1);

      controller.zoomOut(animate: false);
      expect(delegate._calls, ['zoomBy 1 true', 'zoomBy -1 false']);
      expect(controller.zoom, _testZoom);

      controller.setZoom(10, animate: false);
      expect(delegate._calls, [
        'zoomBy 1 true',
        'zoomBy -1 false',
        'setZoom 10 false',
      ]);
      expect(controller.zoom, 10);

      const target = LatLng(latitude: 10, longitude: 20);
      controller.moveTo(target, animate: false);
      expect(delegate._calls, [
        'zoomBy 1 true',
        'zoomBy -1 false',
        'setZoom 10 false',
        'moveTo false',
      ]);
      expect(controller.center, target);
    });

    test('camera methods are no-ops when detached', () {
      final controller = MapController();
      controller.zoomIn();
      controller.zoomOut();
      controller.setZoom(5);
      controller.moveTo(const LatLng(latitude: 1, longitude: 1));
      expect(controller.isAttached, isFalse);
    });
  });

  group('MapController marker methods', () {
    test('delegate to marker manager', () {
      final controller = MapController();
      final delegate = _FakeDelegate().._markerManager = MarkerManager();
      controller.attach(delegate);

      final marker = Marker(
        point: _center,
        child: const SizedBox(),
      );
      controller.addMarker(marker);
      expect(delegate.markerManager!.length, 1);

      expect(controller.removeMarker(marker), isTrue);
      expect(delegate.markerManager!.length, 0);

      controller.addMarker(marker);
      controller.clearMarkers();
      expect(delegate.markerManager!.length, 0);
    });

    test('are no-ops when no marker manager is attached', () {
      final controller = MapController();
      controller.attach(_FakeDelegate());
      final marker = Marker(point: _center, child: const SizedBox());
      expect(() => controller.addMarker(marker), returnsNormally);
      expect(controller.removeMarker(marker), isFalse);
      expect(() => controller.clearMarkers(), returnsNormally);
    });
  });

  group('MapView controller integration', () {
    testWidgets('attaches controller after first frame', (tester) async {
      final controller = MapController();
      await _pumpMap(tester, controller: controller);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(controller.isAttached, isTrue);
      expect(controller.zoom, _testZoom);
      expect(controller.center, _center);
    });

    testWidgets('setZoom updates the map', (tester) async {
      final controller = MapController();
      await _pumpMap(tester, controller: controller);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      controller.setZoom(5, animate: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(controller.zoom, 5);
    });

    testWidgets('zoomIn and zoomOut update the map', (tester) async {
      final controller = MapController();
      await _pumpMap(tester, controller: controller);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      controller.zoomIn(animate: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(controller.zoom, _testZoom + 1);

      controller.zoomOut(animate: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(controller.zoom, _testZoom);
    });

    testWidgets('moveTo jumps the camera when animate is false',
        (tester) async {
      final controller = MapController();
      await _pumpMap(tester, controller: controller);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      const target = LatLng(latitude: 10, longitude: 20);
      controller.moveTo(target, animate: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(controller.center, target);
    });

    testWidgets('addMarker and removeMarker update the map', (tester) async {
      final controller = MapController();
      final markers = MarkerManager();
      await _pumpMap(tester, controller: controller, markers: markers);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      const markerChild = SizedBox(width: 40, height: 40, key: Key('marker'));
      final marker = Marker(point: _center, child: markerChild);
      controller.addMarker(marker);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('marker')), findsOneWidget);

      controller.removeMarker(marker);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('marker')), findsNothing);
    });
  });

  group('Map notifications', () {
    testWidgets('MapReadyNotification is dispatched', (tester) async {
      final controller = MapController();
      MapReadyNotification? ready;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<MapReadyNotification>(
              onNotification: (n) {
                ready = n;
                return false;
              },
              child: MapView(
                controller: controller,
                latLng: _center,
                zoom: _testZoom,
                tileFetcher: _stubFetcher,
                animateZoom: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(ready, isNotNull);
      expect(ready!.controller, same(controller));
    });

    testWidgets('MapZoomChangeNotification is dispatched on zoom changes',
        (tester) async {
      final controller = MapController();
      final zooms = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<MapZoomChangeNotification>(
              onNotification: (n) {
                zooms.add(n.zoom);
                return false;
              },
              child: MapView(
                controller: controller,
                latLng: _center,
                zoom: _testZoom,
                tileFetcher: _stubFetcher,
                animateZoom: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      controller.zoomIn(animate: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(zooms, contains(_testZoom + 1));
    });

    testWidgets('MapMarkerTapNotification is dispatched on marker tap',
        (tester) async {
      final controller = MapController();
      final markers = MarkerManager()
        ..add(
          Marker(
            point: _center,
            onTap: () {},
            child: const SizedBox(width: 40, height: 40, key: Key('marker')),
          ),
        );
      Marker? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<MapMarkerTapNotification>(
              onNotification: (n) {
                tapped = n.marker;
                return false;
              },
              child: MapView(
                controller: controller,
                latLng: _center,
                zoom: _testZoom,
                tileFetcher: _stubFetcher,
                markers: markers,
                animateZoom: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byKey(const Key('marker')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(tapped, same(markers.markers.first));
    });

    testWidgets('MapOverlayShownNotification and MapOverlayHiddenNotification',
        (tester) async {
      final controller = MapController();
      final marker = Marker(
        point: _center,
        overlayBuilder: (context) => const SizedBox(key: Key('overlay')),
        child: const SizedBox(width: 40, height: 40, key: Key('marker')),
      );
      final markers = MarkerManager();

      final events = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<MapNotification>(
              onNotification: (n) {
                switch (n) {
                  case MapOverlayShownNotification(:final marker):
                    events.add('shown ${marker.point.latitude}');
                  case MapOverlayHiddenNotification(:final marker):
                    events.add('hidden ${marker.point.latitude}');
                  default:
                }
                return false;
              },
              child: MapView(
                controller: controller,
                latLng: _center,
                zoom: _testZoom,
                tileFetcher: _stubFetcher,
                markers: markers,
                animateZoom: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      controller.addMarker(marker);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byKey(const Key('marker')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(events, contains(contains('shown')));

      await tester.tap(find.byKey(const Key('marker')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(events, contains(contains('hidden')));
    });
  });

  group('MapEventListenerMixin', () {
    testWidgets('hooks receive notifications', (tester) async {
      final controller = MapController();
      final captured = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: _HookTestPage(
            controller: controller,
            onReady: () => captured.add('ready'),
            onMarkerTap: () => captured.add('tap'),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(captured, contains('ready'));

      await tester.tap(find.byKey(const Key('marker')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(captured, contains('tap'));
    });
  });
}

class _HookTestPage extends StatefulWidget {
  final MapController controller;
  final VoidCallback onReady;
  final VoidCallback onMarkerTap;

  const _HookTestPage({
    required this.controller,
    required this.onReady,
    required this.onMarkerTap,
  });

  @override
  State<_HookTestPage> createState() => _HookTestPageState();
}

class _HookTestPageState extends State<_HookTestPage>
    with MapEventListenerMixin {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: listenToMap(
        MapView(
          controller: widget.controller,
          latLng: _center,
          zoom: _testZoom,
          tileFetcher: _stubFetcher,
          markers: MarkerManager()
            ..add(
              Marker(
                point: _center,
                onTap: () {},
                child: const SizedBox(width: 40, height: 40, key: Key('marker')),
              ),
            ),
          animateZoom: false,
        ),
      ),
    );
  }

  @override
  void onMapReady(MapController controller) => widget.onReady();

  @override
  void onMapMarkerTapped(Marker marker) => widget.onMarkerTap();
}
