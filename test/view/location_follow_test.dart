import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

const _origin = LatLng(latitude: 0, longitude: 0);
const _a = MapLocation(
    point: LatLng(latitude: 0.05, longitude: 0.1),
    accuracyMeters: 50,
    bearing: 90);
const _b = MapLocation(point: LatLng(latitude: 0.1, longitude: 0.2));

Future<void> _mount(WidgetTester tester, MapLocationController locations,
        MapController camera,
        {Duration duration = Duration.zero,
        double? zoom,
        bool showUserLocation = true,
        bool showLocationControl = true,
        ValueChanged<LatLng>? onTap,
        void Function(LatLng, int)? onCamera,
        ValueChanged<MapLocationFollowState>? onFollow,
        LatLngBounds? bounds}) =>
    tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RepaintBoundary(
                key: const ValueKey('map-boundary'),
                child: MapView(
                  latLng: _origin,
                  zoom: 10,
                  fractionalZoom: zoom,
                  controller: camera,
                  locationController: locations,
                  cameraBounds: bounds,
                  showZoomControls: false,
                  showUserLocation: showUserLocation,
                  showLocationControl: showLocationControl,
                  locationFollowAnimationDuration: duration,
                  onTap: onTap,
                  onCameraChanged: onCamera,
                  onLocationFollowChanged: onFollow,
                  tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
                )))));

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, MapLocationController locations,
    MapController camera) async {
  await tester.pumpWidget(const SizedBox.shrink());
  locations.dispose();
  camera.dispose();
}

Future<int> _bluePixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('map-boundary')));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final pixels =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
              .buffer
              .asUint8List();
      var count = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i + 2] > pixels[i] + 10) count++;
      }
      return count;
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets(
      'waits for a fix, follows at exact fractional zoom and reports transitions',
      (tester) async {
    final locations = MapLocationController(follow: true);
    final camera = MapController();
    final states = <MapLocationFollowState>[];
    await _mount(tester, locations, camera, zoom: 10.25, onFollow: states.add);
    expect(camera.center, _origin);
    expect(find.byTooltip('Waiting for location'), findsOneWidget);
    locations.updateLocation(_a);
    await _flush(tester);
    expect(camera.center, _a.point);
    expect(camera.fractionalZoom, 10.25);
    expect(states, [MapLocationFollowState.following]);
    expect(camera.locationFollowState, MapLocationFollowState.following);
    expect(find.byTooltip('Following location'), findsOneWidget);
    await _dispose(tester, locations, camera);
  });

  testWidgets('many fixes in a frame center only on the newest target',
      (tester) async {
    final locations = MapLocationController(follow: true);
    final camera = MapController();
    final moves = <LatLng>[];
    await _mount(tester, locations, camera,
        onCamera: (point, _) => moves.add(point));
    for (var i = 0; i < 100; i++) {
      locations.updateLocation(
          MapLocation(point: LatLng(latitude: i / 1000, longitude: 0.1)));
    }
    await _flush(tester);
    expect(camera.center, locations.location!.point);
    expect(moves, hasLength(1));
    await _dispose(tester, locations, camera);
  });

  testWidgets('new fixes smoothly retarget from the in-flight camera position',
      (tester) async {
    final locations = MapLocationController(follow: true)..updateLocation(_a);
    final camera = MapController();
    await _mount(tester, locations, camera,
        duration: const Duration(milliseconds: 300));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final intermediate = camera.center!;
    expect(intermediate.longitude, greaterThan(0));
    expect(intermediate.longitude, lessThan(_a.point.longitude));
    locations.updateLocation(_b);
    await tester.pump();
    expect(camera.center!.longitude, closeTo(intermediate.longitude, 1e-8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(camera.center!.latitude, closeTo(_b.point.latitude, 1e-8));
    expect(camera.center!.longitude, closeTo(_b.point.longitude, 1e-8));
    await _dispose(tester, locations, camera);
  });

  testWidgets(
      'host camera echoes preserve follow motion and reduced motion is instant',
      (tester) async {
    final locations = MapLocationController(follow: true)..updateLocation(_a);
    final camera = MapController();
    var center = _origin;
    var reduceMotion = false;
    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (context, setState) {
        rebuild = setState;
        return MediaQuery(
          data:
              MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: MapView(
            showZoomControls: false,
            latLng: center,
            zoom: 10,
            controller: camera,
            locationController: locations,
            onCameraChanged: (point, _) => setState(() => center = point),
            tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
          ),
        );
      },
    )));
    await _flush(tester);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(camera.center!.latitude, closeTo(_a.point.latitude, 1e-8));
    expect(locations.isFollowing, isTrue);
    rebuild(() => reduceMotion = true);
    await tester.pump();
    locations.updateLocation(_b);
    await _flush(tester);
    expect(camera.center, _b.point);
    await _dispose(tester, locations, camera);
  });

  testWidgets('drag pauses follow, live fixes move the dot, recenter resumes',
      (tester) async {
    final locations = MapLocationController(follow: true)..updateLocation(_a);
    final camera = MapController();
    await _mount(tester, locations, camera);
    await _flush(tester);
    await tester.drag(find.byType(MapView), const Offset(80, 0));
    await tester.pump();
    expect(locations.state, MapLocationFollowState.paused);
    // No timed velocity in this drag, so the released camera is stable.
    final panned = camera.center;
    locations.updateLocation(_b);
    await _flush(tester);
    expect(camera.center, panned);
    expect(find.byTooltip('Recenter and follow location'), findsOneWidget);
    await tester.tap(find.byTooltip('Recenter and follow location'));
    await tester.pump(const Duration(milliseconds: 350));
    await _flush(tester);
    expect(locations.isFollowing, isTrue);
    expect(camera.center, _b.point);
    await _dispose(tester, locations, camera);
  });

  testWidgets('tap interrupts a follow animation only until the finger lifts',
      (tester) async {
    final locations = MapLocationController(follow: true)..updateLocation(_a);
    final camera = MapController();
    await _mount(tester, locations, camera,
        duration: const Duration(milliseconds: 300));
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 80));
    final finger = await tester.startGesture(const Offset(350, 200));
    final stopped = camera.center;
    await tester.pump(const Duration(milliseconds: 200));
    expect(camera.center, stopped);
    expect(locations.isFollowing, isTrue);
    locations.updateLocation(_b);
    await tester.pump();
    expect(camera.center, stopped);
    await finger.up();
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 350));
    expect(camera.center!.longitude, closeTo(_b.point.longitude, 1e-8));
    await tester.pump(const Duration(milliseconds: 350));
    await _dispose(tester, locations, camera);
  });

  testWidgets('manual move pauses and MapController can resume or stop',
      (tester) async {
    final locations = MapLocationController(follow: true)..updateLocation(_a);
    final camera = MapController();
    await _mount(tester, locations, camera);
    await _flush(tester);
    camera.moveTo(_origin, animate: false);
    expect(locations.state, MapLocationFollowState.paused);
    locations.updateLocation(_b);
    await _flush(tester);
    expect(camera.center, _origin);
    camera.followLocation();
    await _flush(tester);
    expect(camera.center, _b.point);
    camera.stopLocationFollowing();
    expect(locations.state, MapLocationFollowState.off);
    await _dispose(tester, locations, camera);
  });

  testWidgets('pinch and focal wheel zoom pause following', (tester) async {
    final locations = MapLocationController(follow: true)..updateLocation(_a);
    final camera = MapController();
    await _mount(tester, locations, camera, zoom: 10.25);
    await _flush(tester);
    final gestures = tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));
    gestures.onScaleStart!(
        ScaleStartDetails(focalPoint: const Offset(400, 300), pointerCount: 2));
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: const Offset(410, 300), scale: 1.1, pointerCount: 2));
    gestures.onScaleEnd!(ScaleEndDetails());
    expect(locations.state, MapLocationFollowState.paused);
    locations.follow();
    await _flush(tester);
    await tester.sendEventToBinding(const PointerScrollEvent(
        position: Offset(500, 300), scrollDelta: Offset(0, -20)));
    expect(locations.state, MapLocationFollowState.paused);
    await _dispose(tester, locations, camera);
  });

  testWidgets(
      'zoom animation defers the newest follow fix until source tile units are stable',
      (tester) async {
    final locations = MapLocationController(follow: true)..updateLocation(_a);
    final camera = MapController();
    await _mount(tester, locations, camera, zoom: 10.25);
    await _flush(tester);
    camera.setFractionalZoom(11.4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175));
    locations.updateLocation(_b);
    await tester.pump();
    expect(locations.isFollowing, isTrue);
    await tester.pump(const Duration(milliseconds: 190));
    await _flush(tester);
    expect(camera.fractionalZoom, closeTo(11.4, 1e-8));
    expect(camera.center!.latitude, closeTo(_b.point.latitude, 1e-9));
    expect(camera.center!.longitude, closeTo(_b.point.longitude, 1e-9));
    await _dispose(tester, locations, camera);
  });

  testWidgets(
      'controller replacement detaches old updates; unmount preserves host ownership',
      (tester) async {
    final first = MapLocationController(follow: true)..updateLocation(_a);
    final second = MapLocationController(follow: true)..updateLocation(_b);
    final camera = MapController();
    await _mount(tester, first, camera);
    await _flush(tester);
    await _mount(tester, second, camera);
    await _flush(tester);
    expect(camera.center, _b.point);
    first.updateLocation(const MapLocation(point: _origin));
    await _flush(tester);
    expect(camera.center, _b.point);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(() => second.updateLocation(_a), returnsNormally);
    first.dispose();
    second.dispose();
    camera.dispose();
  });

  testWidgets(
      'stream failure shows last known fix; recovery resumes and clear hides it',
      (tester) async {
    final source = StreamController<MapLocation>(sync: true);
    final locations =
        MapLocationController(locations: source.stream, follow: true);
    final camera = MapController();
    final semantics = tester.ensureSemantics();
    await _mount(tester, locations, camera);
    source.add(_a);
    await _flush(tester);
    expect(find.bySemanticsLabel('Current location'), findsOneWidget);
    source.addError(StateError('GPS unavailable'));
    await _flush(tester);
    expect(find.bySemanticsLabel('Last known location'), findsOneWidget);
    expect(find.byTooltip('Location unavailable'), findsOneWidget);
    source.add(_b);
    await _flush(tester);
    expect(camera.center, _b.point);
    locations.clearLocation();
    await _flush(tester);
    expect(find.bySemanticsLabel('Current location'), findsNothing);
    expect(locations.state, MapLocationFollowState.waiting);
    semantics.dispose();
    await _dispose(tester, locations, camera);
    await tester.runAsync(source.close);
  });

  testWidgets(
      'accuracy area grows with fractional zoom while dot keeps its screen size',
      (tester) async {
    final locations = MapLocationController()
      ..updateLocation(const MapLocation(point: _origin, accuracyMeters: 5000));
    final camera = MapController();
    await _mount(tester, locations, camera,
        zoom: 10.0, showLocationControl: false);
    await _flush(tester);
    final before = await _bluePixels(tester);
    camera.setFractionalZoom(10.25, animate: false);
    await _flush(tester);
    final after = await _bluePixels(tester);
    expect(after / before, closeTo(math.pow(2, 0.5), 0.08));
    final semantics = tester.ensureSemantics();
    expect(tester.getSize(find.bySemanticsLabel('Current location')),
        const Size(48, 48));
    semantics.dispose();
    await _dispose(tester, locations, camera);
  });

  testWidgets(
      'position dot lets map taps pass through and overlays can be hidden',
      (tester) async {
    final locations = MapLocationController()
      ..updateLocation(const MapLocation(point: _origin));
    final camera = MapController();
    LatLng? tapped;
    await _mount(tester, locations, camera, onTap: (point) => tapped = point);
    await _flush(tester);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 350));
    expect(tapped, isNotNull);
    final semantics = tester.ensureSemantics();
    await _mount(tester, locations, camera,
        showUserLocation: false, showLocationControl: false);
    expect(find.bySemanticsLabel('Current location'), findsNothing);
    expect(find.byType(MapLocationControl), findsNothing);
    semantics.dispose();
    await _dispose(tester, locations, camera);
  });

  testWidgets('following respects camera bounds and pole coordinates',
      (tester) async {
    final locations = MapLocationController(follow: true)
      ..updateLocation(
          const MapLocation(point: LatLng(latitude: 90, longitude: 0)));
    final camera = MapController();
    await _mount(tester, locations, camera);
    await _flush(tester);
    expect(camera.center!.latitude, closeTo(85.0511287798066, 1e-8));
    locations.updateLocation(_b);
    final bounds = LatLngBounds(
        southwest: const LatLng(latitude: -0.1, longitude: -0.1),
        northeast: const LatLng(latitude: 0.1, longitude: 0.1));
    await _mount(tester, locations, camera, bounds: bounds);
    await _flush(tester);
    expect(camera.center!.latitude.abs(), lessThan(0.1));
    expect(camera.center!.longitude.abs(), lessThan(0.1));
    expect(locations.isFollowing, isTrue);
    await _dispose(tester, locations, camera);
  });
}
