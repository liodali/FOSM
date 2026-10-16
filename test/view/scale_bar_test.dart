import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/common/scale_bar_metrics.dart';

ScaleBarMetrics _metric(double latitude, int zoom, [double width = 120]) =>
    calculateScaleBar(
        latitude: latitude,
        zoom: zoom,
        maxWidth: width,
        unit: ScaleBarUnit.metric)!;

Widget _ruler(
        {double latitude = 0,
        int zoom = 10,
        ScaleBarUnit unit = ScaleBarUnit.metric,
        double width = 800,
        double height = 600,
        double textScale = 1}) =>
    MaterialApp(
        home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Center(
          child: SizedBox(
              width: width,
              height: height,
              child: MapScaleBar(latitude: latitude, zoom: zoom, unit: unit))),
    ));

Future<void> _map(WidgetTester tester, MapController controller,
        {bool show = true,
        ScaleBarUnit unit = ScaleBarUnit.metric,
        ValueChanged<LatLng>? onTap}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: MapView(
        latLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 10,
        showZoomControls: false,
        showScaleBar: show,
        scaleBarUnit: unit,
        controller: controller,
        onTap: onTap,
        tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
      )),
    ));

void main() {
  test('resolution follows Web Mercator zoom and latitude', () {
    expect(mapMetersPerPixel(0, 0), closeTo(156543.033928, 0.000001));
    expect(mapMetersPerPixel(0, 1), closeTo(mapMetersPerPixel(0, 0) / 2, 1e-8));
    expect(
        mapMetersPerPixel(60, 10), closeTo(mapMetersPerPixel(0, 10) / 2, 1e-8));
    expect(
        mapMetersPerPixel(-60, 10), closeTo(mapMetersPerPixel(60, 10), 1e-8));
    expect(mapMetersPerPixel(90, 10), mapMetersPerPixel(85.0511287798066, 10));
  });

  test('metric distances and ruler pixels agree at different cameras', () {
    final equator = _metric(0, 10);
    expect(equator.label, '10 km');
    expect(equator.width * mapMetersPerPixel(0, 10), closeTo(10000, 1e-8));
    expect(_metric(60, 10).label, '5 km');
    final close = _metric(0, 19);
    expect(close.label, '20 m');
    expect(close.width * mapMetersPerPixel(0, 19), closeTo(20, 1e-8));
    expect(_metric(0, 30).label, '0.01 m');
  });

  test('imperial distances use exact foot and mile conversions', () {
    final miles = calculateScaleBar(
        latitude: 0, zoom: 10, maxWidth: 120, unit: ScaleBarUnit.imperial)!;
    expect(miles.label, '10 mi');
    expect(
        miles.width * mapMetersPerPixel(0, 10), closeTo(10 * 1609.344, 1e-8));
    final feet = calculateScaleBar(
        latitude: 0, zoom: 19, maxWidth: 120, unit: ScaleBarUnit.imperial)!;
    expect(feet.label, '100 ft');
    expect(feet.width * mapMetersPerPixel(0, 19), closeTo(100 * 0.3048, 1e-8));
  });

  test('every ruler fits and chooses a 1/2/5 distance', () {
    for (final latitude in [-85.0, -60.0, 0.0, 60.0, 85.0]) {
      for (var zoom = 0; zoom <= 30; zoom++) {
        for (final width in [24.0, 67.0, 120.0, 200.0]) {
          for (final unit in ScaleBarUnit.values) {
            final ruler = calculateScaleBar(
                latitude: latitude, zoom: zoom, maxWidth: width, unit: unit)!;
            expect(ruler.width, greaterThan(0));
            expect(ruler.width, lessThanOrEqualTo(width));
            expect(ruler.width, greaterThanOrEqualTo(width * 0.39));
            final digits = ruler.label
                .split(' ')
                .first
                .replaceAll('.', '')
                .replaceAll('0', '');
            expect(['1', '2', '5'], contains(digits));
          }
        }
      }
    }
  });

  test('invalid inputs do not produce a ruler', () {
    for (final width in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
          calculateScaleBar(
              latitude: 0,
              zoom: 10,
              maxWidth: width,
              unit: ScaleBarUnit.metric),
          isNull);
    }
    expect(
        calculateScaleBar(
            latitude: double.nan,
            zoom: 10,
            maxWidth: 120,
            unit: ScaleBarUnit.metric),
        isNull);
    expect(
        calculateScaleBar(
            latitude: 0, zoom: -1, maxWidth: 120, unit: ScaleBarUnit.metric),
        isNull);
  });

  testWidgets(
      'widget paints the measured ruler and exposes a descriptive label',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_ruler());
    expect(find.text('10 km'), findsOneWidget);
    expect(find.bySemanticsLabel('Map scale: 10 kilometers'), findsOneWidget);
    final paint = find.descendant(
        of: find.byType(MapScaleBar), matching: find.byType(CustomPaint));
    expect(tester.getSize(paint).width, closeTo(_metric(0, 10).width, 1e-8));
    await tester.pumpWidget(_ruler(latitude: 60, unit: ScaleBarUnit.imperial));
    expect(find.text('5 mi'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('small viewports and large text avoid layout overflow',
      (tester) async {
    await tester.pumpWidget(_ruler(width: 100, height: 140, textScale: 3));
    expect(
        find.descendant(
            of: find.byType(MapScaleBar), matching: find.byType(CustomPaint)),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_ruler(width: 45, height: 80));
    expect(find.textContaining('km'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_ruler(width: 100, height: 50, textScale: 3));
    expect(find.textContaining('km'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map ruler follows zoom and latitude changes and can be hidden',
      (tester) async {
    final controller = MapController();
    await _map(tester, controller);
    expect(find.text('10 km'), findsOneWidget);
    controller.zoomIn(animate: false);
    await tester.pump();
    expect(find.text('5 km'), findsOneWidget);
    controller.moveTo(const LatLng(latitude: 60, longitude: 0), animate: false);
    await tester.pump();
    expect(find.text('2 km'), findsOneWidget);
    await _map(tester, controller, unit: ScaleBarUnit.imperial);
    expect(find.text('2 mi'), findsOneWidget);
    await _map(tester, controller, show: false);
    expect(find.byType(MapScaleBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tapping the ruler reaches the map beneath it', (tester) async {
    final controller = MapController();
    LatLng? tapped;
    await _map(tester, controller, onTap: (point) => tapped = point);
    await tester.tapAt(tester.getCenter(find.text('10 km')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(tapped, isNotNull);
    expect(tapped!.longitude, lessThan(0));
    expect(tapped!.latitude, lessThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('map default stays hidden and alignment can change',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MapView(
      latLng: const LatLng(latitude: 0, longitude: 0),
      zoom: 10,
      showZoomControls: false,
      tileFetcher: (_, __, ___) => Completer<Uint8List>().future,
    ))));
    expect(find.byType(MapScaleBar), findsNothing);
    await tester.pumpWidget(_ruler());
    final bottom = tester.getCenter(find.text('10 km'));
    await tester.pumpWidget(const MaterialApp(
        home:
            MapScaleBar(latitude: 0, zoom: 10, alignment: Alignment.topRight)));
    final top = tester.getCenter(find.text('10 km'));
    expect(top.dx, greaterThan(bottom.dx));
    expect(top.dy, lessThan(bottom.dy));
  });
}
