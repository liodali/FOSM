import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

const _origin = LatLng(latitude: 0, longitude: 0);

Future<void> _mount(WidgetTester tester, MapController controller,
    {bool enableFling = true,
    bool enableScrollZoom = true,
    bool animateZoom = false,
    LatLng center = _origin,
    LatLngBounds? bounds,
    Widget Function(Widget)? wrap}) async {
  Widget map = MapView(
    latLng: center,
    zoom: 5,
    minZoom: 3,
    maxZoom: 8,
    controller: controller,
    cameraBounds: bounds,
    enableFling: enableFling,
    enableScrollZoom: enableScrollZoom,
    animateZoom: animateZoom,
    showZoomControls: false,
    tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
  );
  if (wrap != null) map = wrap(map);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: map)));
}

Future<void> _wheel(WidgetTester tester, double dy,
    {Offset at = const Offset(500, 300), int ms = 0}) async {
  await tester.sendEventToBinding(PointerScrollEvent(
    position: at,
    scrollDelta: Offset(0, dy),
    timeStamp: Duration(milliseconds: ms),
  ));
  await tester.pump();
}

// Events spaced in time give the recognizer a real release velocity.
Future<TestGesture> _swipe(WidgetTester tester) async {
  final finger = await tester.startGesture(const Offset(300, 300));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await finger.moveBy(const Offset(15, 0),
        timeStamp: Duration(milliseconds: (i + 1) * 16));
  }
  return finger;
}

void main() {
  testWidgets('release coasts, slows, and settles', (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final finger = await _swipe(tester);
    final release = controller.center!.longitude;
    await finger.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final early = controller.center!.longitude;
    expect(early, lessThan(release));
    await tester.pump(const Duration(milliseconds: 100));
    final later = controller.center!.longitude;
    expect(early - later, lessThan(release - early));
    await tester.pumpAndSettle();
    final settled = controller.center;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.center, settled);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pointer down stops a fling before drag recognition',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final swipe = await _swipe(tester);
    await swipe.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final finger = await tester.startGesture(const Offset(400, 300));
    final stopped = controller.center;
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.center, stopped);
    await finger.up();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabled flings and cancelled gestures do not coast',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller, enableFling: false);
    var finger = await _swipe(tester);
    await finger.up();
    var stopped = controller.center;
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.center, stopped);
    await _mount(tester, controller);
    finger = await _swipe(tester);
    await finger.cancel();
    stopped = controller.center;
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.center, stopped);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('instant move and zoom commands cancel a running pan',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    var finger = await _swipe(tester);
    await finger.up();
    await tester.pump();
    controller.moveTo(_origin, animate: false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.center, _origin);
    finger = await _swipe(tester);
    await finger.up();
    await tester.pump();
    controller.zoomIn(animate: false);
    final stopped = controller.center;
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.zoom, 6);
    expect(controller.center, stopped);
    // Replaces the older animated move too, not only a fling.
    controller.moveTo(const LatLng(latitude: 15, longitude: 15));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    controller.moveTo(_origin, animate: false);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.center, _origin);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fling respects camera bounds and stops at an edge',
      (tester) async {
    final controller = MapController();
    final bounds = LatLngBounds(
        southwest: const LatLng(latitude: -30, longitude: -30),
        northeast: const LatLng(latitude: 30, longitude: 30));
    await _mount(tester, controller, bounds: bounds);
    await tester.fling(find.byType(MapView), const Offset(120, 0), 2500);
    await tester.pumpAndSettle();
    // At z5 a half viewport is 17.578125 degrees of longitude.
    expect(controller.center!.longitude, closeTo(-30 + 400 * 360 / 8192, 1e-6));
    final stopped = controller.center;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.center, stopped);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('widget camera changes and disabling fling stop momentum',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    var finger = await _swipe(tester);
    await finger.up();
    await tester.pump();
    await _mount(tester, controller, enableFling: false);
    final stopped = controller.center;
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.center, stopped);
    await _mount(tester, controller);
    finger = await _swipe(tester);
    await finger.up();
    await tester.pump();
    const target = LatLng(latitude: 10, longitude: 10);
    await _mount(tester, controller, center: target);
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.center, target);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pinch release never flings, including the last finger',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final b = await tester.startGesture(const Offset(500, 300), pointer: 2);
    await tester.pump(const Duration(milliseconds: 50));
    await a.moveBy(const Offset(-40, 0));
    await b.moveBy(const Offset(40, 0));
    await a.up();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await b.moveBy(const Offset(15, 0));
    }
    await b.up();
    final stopped = controller.center;
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.center, stopped);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wheel accumulates, anchors at cursor, reverses and clamps',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    await _wheel(tester, -40);
    expect(controller.zoom, 5);
    await _wheel(tester, -60, ms: 30);
    expect(controller.zoom, 6);
    // Cursor is 100px east of center. A zoom-in moves center 50 old pixels east.
    expect(controller.center!.longitude, closeTo(50 * 360 / 8192, 1e-8));
    await _wheel(tester, -80, ms: 60);
    await _wheel(tester, 100, ms: 90);
    expect(controller.zoom, 5);
    expect(controller.center!.longitude, closeTo(0, 1e-8));
    await _wheel(tester, -10000, ms: 120);
    expect(controller.zoom, 8);
    await _wheel(tester, -100, ms: 150);
    await _wheel(tester, 100, ms: 180);
    expect(controller.zoom, 7);
    await _wheel(tester, 10000, ms: 210);
    expect(controller.zoom, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wheel uses local coordinates in a padded viewport',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller,
        wrap: (map) => Padding(
            padding: const EdgeInsets.only(left: 100, top: 100), child: map));
    await _wheel(tester, -100, at: const Offset(550, 350));
    // Viewport center is now (450,350); the cursor is still 100px east.
    expect(controller.zoom, 6);
    expect(controller.center!.longitude, closeTo(50 * 360 / 8192, 1e-8));
    expect(controller.center!.latitude, closeTo(0, 1e-8));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabled wheel input bubbles to its parent', (tester) async {
    final controller = MapController();
    var parentScrolls = 0;
    await _mount(tester, controller,
        enableScrollZoom: false,
        wrap: (map) => Listener(
            onPointerSignal: (event) {
              GestureBinding.instance.pointerSignalResolver
                  .register(event, (_) => parentScrolls++);
            },
            child: map));
    await _wheel(tester, -100);
    expect(controller.zoom, 5);
    expect(parentScrolls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('camera callback echoes preserve momentum', (tester) async {
    final controller = MapController();
    var center = _origin;
    var zoom = 5;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
      builder: (context, update) => MapView(
        latLng: center,
        showZoomControls: false,
        zoom: zoom,
        controller: controller,
        tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
        onCameraChanged: (point, level) => update(() {
          center = point;
          zoom = level;
        }),
      ),
    )));
    final finger = await _swipe(tester);
    await finger.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final early = controller.center!.longitude;
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.center!.longitude, lessThan(early));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('diagonal fling slides along a clamped axis', (tester) async {
    final controller = MapController();
    await _mount(tester, controller,
        bounds: LatLngBounds(
            southwest: const LatLng(latitude: -60, longitude: -20),
            northeast: const LatLng(latitude: 60, longitude: 20)));
    await tester.flingFrom(
        const Offset(300, 150), const Offset(100, 100), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final first = controller.center!;
    expect(first.longitude, closeTo(-20 + 400 * 360 / 8192, 1e-6));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.center!.longitude, closeTo(first.longitude, 1e-8));
    expect(controller.center!.latitude, greaterThan(first.latitude));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wheel bursts expire and events resolve once or bubble at limits',
      (tester) async {
    final controller = MapController();
    var parentScrolls = 0;
    await _mount(tester, controller,
        wrap: (map) => Listener(
            onPointerSignal: (event) => GestureBinding
                .instance.pointerSignalResolver
                .register(event, (_) => parentScrolls++),
            child: map));
    await _wheel(tester, -60);
    await _wheel(tester, -40, ms: 300);
    expect(controller.zoom, 5);
    await _wheel(tester, -60, ms: 330);
    expect(controller.zoom, 6);
    expect(parentScrolls, 0);
    controller.setZoom(8, animate: false);
    await _wheel(tester, -100, ms: 400);
    expect(parentScrolls, 1);
    final finger = await tester.startGesture(const Offset(400, 300));
    await _wheel(tester, 100, ms: 430);
    expect(controller.zoom, 8);
    await finger.up();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pinch scale stays cumulative and damps small reversals',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final gestures = tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));
    const focal = Offset(400, 300);
    gestures
        .onScaleStart!(ScaleStartDetails(focalPoint: focal, pointerCount: 2));
    for (final scale in [1.43, 1.6, 1.9, 2.0]) {
      gestures.onScaleUpdate!(
          ScaleUpdateDetails(focalPoint: focal, scale: scale, pointerCount: 2));
      // Updates coalesce to once per display frame; a pump flushes the
      // current one before the assertion.
      await tester.pump();
      expect(controller.zoom, 6,
          reason: '2x pinch means exactly one zoom level');
    }
    gestures.onScaleUpdate!(
        ScaleUpdateDetails(focalPoint: focal, scale: 4, pointerCount: 2));
    await tester.pump();
    expect(controller.zoom, 7);
    gestures.onScaleUpdate!(
        ScaleUpdateDetails(focalPoint: focal, scale: 2.8, pointerCount: 2));
    await tester.pump();
    expect(controller.zoom, 7,
        reason: 'minor reversal near boundary should not flicker');
    gestures.onScaleUpdate!(
        ScaleUpdateDetails(focalPoint: focal, scale: 2, pointerCount: 2));
    await tester.pump();
    expect(controller.zoom, 6);
    gestures.onScaleUpdate!(
        ScaleUpdateDetails(focalPoint: focal, scale: 1, pointerCount: 2));
    await tester.pump();
    expect(controller.zoom, 5);
    gestures.onScaleEnd!(ScaleEndDetails());
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scale-update bursts coalesce to one build per frame',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final gestures = tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));
    const start = Offset(400, 300);

    // Single-pointer pan burst: several events arrive before the display
    // renders the next frame.
    gestures
        .onScaleStart!(ScaleStartDetails(focalPoint: start, pointerCount: 1));
    MapView.debugBuildCount = 0;
    for (final dx in [12, 24, 36, 48]) {
      gestures.onScaleUpdate!(ScaleUpdateDetails(
          focalPoint: start + Offset(dx.toDouble(), 0),
          scale: 1,
          pointerCount: 1));
    }
    // No frame has rendered: exactly one application (the first event)
    // happened, and no build ran.
    expect(MapView.debugBuildCount, 0);
    final midPan = controller.center!;
    final midPanLatitude = midPan.latitude;

    await tester.pump();
    // The burst's latest focal point wins, and the whole burst cost a
    // single map build.
    final end = controller.center!;
    expect(end.longitude, lessThan(midPan.longitude),
        reason: 'the coalesced remainder of the burst must still apply');
    expect(end.latitude, midPanLatitude);
    expect(MapView.debugBuildCount, 1);

    gestures.onScaleEnd!(ScaleEndDetails());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('camera commands cancel queued gesture updates and rebase',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final gestures = tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));
    const start = Offset(400, 300);

    gestures
        .onScaleStart!(ScaleStartDetails(focalPoint: start, pointerCount: 1));
    // Two updates in one frame: the first applies, the second queues.
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: start + const Offset(10, 0), scale: 1, pointerCount: 1));
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: start + const Offset(20, 0), scale: 1, pointerCount: 1));

    // A newer camera command must win over the still-queued update: the
    // next frame may not jump back to the gesture's trajectory.
    controller.moveTo(const LatLng(latitude: 0.05, longitude: 0.05),
        animate: false);
    await tester.pump();
    final after = controller.center!;
    expect(after.latitude, closeTo(0.05, 1e-9));
    expect(after.longitude, closeTo(0.05, 1e-9));

    // The still-active gesture continues from the commanded camera: the
    // next update pans by the 10px since the re-based anchor, not by the
    // 30px a stale pre-command baseline would apply.
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: start + const Offset(30, 0), scale: 1, pointerCount: 1));
    await tester.pump();
    final continued = controller.center!;
    expect(continued.longitude, lessThan(after.longitude),
        reason: 'the drag must still pan west');
    expect(after.longitude - continued.longitude, lessThan(0.45),
        reason: 'a stale gesture baseline would jump back by ~1.3 degrees');
    expect(continued.latitude, closeTo(after.latitude, 1e-9));
    gestures.onScaleEnd!(ScaleEndDetails());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sparse input on a later frame applies immediately',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final gestures = tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));
    const start = Offset(400, 300);

    gestures
        .onScaleStart!(ScaleStartDetails(focalPoint: start, pointerCount: 1));
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: start + const Offset(10, 0), scale: 1, pointerCount: 1));
    // A frame boundary passes with nothing queued.
    await tester.pump();

    // The first input of a later frame must apply immediately — not wait
    // for a flush that has nothing to do.
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: start + const Offset(30, 0), scale: 1, pointerCount: 1));
    final center = controller.center!;
    expect(center.longitude, lessThan(-1.0),
        reason: 'the full 30px drag must already be applied synchronously');
    gestures.onScaleEnd!(ScaleEndDetails());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rebasing preserves the fractional pinch baseline',
      (tester) async {
    final controller = MapController();
    // Default zoom limits: the potential extra step (zoom 9) must not be
    // masked by clamping.
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: _origin,
      zoom: 5,
      controller: controller,
      showZoomControls: false,
      tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
    ))));
    final gestures = tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));
    const focal = Offset(400, 300);
    // log₂ of this scale is 0.4999999999999992 — just under half a zoom
    // level. Chosen at a several-ulp margin so platform log differences
    // cannot flip it.
    const unchangedScale = 1.4142135623730943;

    // The pinch is already at this scale when a command sets zoom 8.
    gestures
        .onScaleStart!(ScaleStartDetails(focalPoint: focal, pointerCount: 2));
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: focal, scale: unchangedScale, pointerCount: 2));
    await tester.pump();
    expect(controller.zoom, 5, reason: 'the pinch itself must not step');

    controller.setZoom(8, animate: false);

    // Repeating the unchanged scale must land exactly on 8: a baseline
    // rounded up to 8 would produce exactly 8.5 → zoom 9.
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: focal, scale: unchangedScale, pointerCount: 2));
    await tester.pump();
    expect(controller.zoom, 8,
        reason: 'a rounded baseline would turn the unchanged scale into '
            'an extra zoom step');

    gestures.onScaleEnd!(ScaleEndDetails());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('resumed dragging cancels a command animation',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller);
    final gestures = tester.widget<GestureDetector>(find.descendant(
        of: find.byType(MapView),
        matching: find.byWidgetPredicate((widget) =>
            widget is GestureDetector && widget.onScaleStart != null)));
    const start = Offset(400, 300);

    // Finger down and already dragging.
    gestures
        .onScaleStart!(ScaleStartDetails(focalPoint: start, pointerCount: 1));
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: start + const Offset(10, 0), scale: 1, pointerCount: 1));
    await tester.pump();

    // An animated camera command starts while the finger stays down.
    controller.moveTo(const LatLng(latitude: 0.2, longitude: 0.2),
        animate: true);
    await tester.pump(); // start the animation ticker
    await tester.pump(const Duration(milliseconds: 175));
    final mid = controller.center!;
    expect(mid.latitude, greaterThan(0.01),
        reason: 'the animation should be moving the camera meanwhile');

    // The drag resumes: direct manipulation owns the camera, the
    // animation must stop instead of overwriting the drag on later ticks.
    gestures.onScaleUpdate!(ScaleUpdateDetails(
        focalPoint: start + const Offset(20, 0), scale: 1, pointerCount: 1));
    await tester.pump();
    final resumed = controller.center!;
    await tester.pump(const Duration(milliseconds: 350));
    final settled = controller.center!;
    expect(settled.latitude, closeTo(resumed.latitude, 1e-9),
        reason: 'animation ticks must not keep overwriting the drag');
    expect(settled.longitude, closeTo(resumed.longitude, 1e-9));
    expect(settled.latitude, lessThan(0.15),
        reason: 'the camera must not have reached the animation target');

    gestures.onScaleEnd!(ScaleEndDetails());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('multi-level zoom animation scales by the full zoom delta',
      (tester) async {
    final controller = MapController();
    await _mount(tester, controller, animateZoom: true);
    controller.setZoom(8);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // tile wait timeout
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 175)); // half of 350ms
    final transforms = find.descendant(
        of: find.byKey(const ValueKey('zoom-scale')),
        matching: find.byType(Transform));
    final matrices =
        tester.widgetList<Transform>(transforms).map((w) => w.transform);
    // EaseInOut halfway interpolates 1 -> 8 to 4.5, rather than 1 -> 2.
    expect(matrices.any((m) => (m.entry(0, 0) - 4.5).abs() < 0.05), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
