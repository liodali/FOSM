import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/view/polygon_layer.dart';
import 'package:fosm/src/view/shape_geometry.dart';

void main() {
  late TileManager manager;
  setUp(() {
    manager = TileManager.init(
        width: 200,
        height: 200,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 3,
        fetcher: (z, x, y) => Completer<Uint8List>().future,
        tilePadding: 0,
        preloadAdjacentZoom: false);
  });
  tearDown(() => manager.dispose());

  LatLng at(double x, double y) => manager.screenToLatLng(ui.Offset(x, y));
  List<LatLng> square(double start, double end) =>
      [at(start, start), at(end, start), at(end, end), at(start, end)];

  test('inverse projection roundtrips camera coordinates and wraps world edges',
      () {
    const point = LatLng(latitude: 47.4, longitude: 8.5);
    final inverse = manager.screenToLatLng(manager.latLngToScreen(point));
    expect(inverse.latitude, closeTo(point.latitude, 1e-9));
    expect(inverse.longitude, closeTo(point.longitude, 1e-9));
    expect(manager.screenToLatLng(const ui.Offset(100, 100)),
        const LatLng(latitude: 0, longitude: 0));
    expect(manager.screenToLatLng(const ui.Offset(356, 100)).longitude, 45);
    manager.setCenterTile(latLng: const LatLng(latitude: 0, longitude: 179));
    expect(manager.screenToLatLng(const ui.Offset(356, 100)).longitude, -136);
    expect(manager.screenToLatLng(const ui.Offset(100, -10000)).latitude,
        closeTo(85.0511287798066, 1e-9));
  });

  test('route selection includes border/tolerance and reports nearest segment',
      () {
    final route = MapPolyline(
        points: [at(20, 100), at(100, 100), at(100, 180)],
        interactive: true,
        strokeWidth: 4,
        borderColor: const ui.Color(0xFFFFFFFF),
        borderWidth: 2,
        hitTolerance: 5);
    final hit = hitTestPolylines([route], manager, const ui.Offset(108, 150))!;
    expect(hit.polyline, same(route));
    expect(hit.segmentIndex, 1);
    expect(hit.distancePixels, closeTo(8, 1e-8));
    expect(manager.latLngToScreen(hit.nearestPoint).dx, closeTo(100, 1e-8));
    expect(
        hitTestPolylines([route], manager, const ui.Offset(111, 150)), isNull);
  });

  test(
      'topmost interactive route wins; decorative and invalid routes pass through',
      () {
    final lower =
        MapPolyline(points: [at(0, 100), at(200, 100)], interactive: true);
    final top =
        MapPolyline(points: [at(0, 108), at(200, 108)], interactive: true);
    final decoration = MapPolyline(points: [at(0, 100), at(200, 100)]);
    final invalid = MapPolyline(
        points: [at(0, 100), const LatLng(latitude: double.nan, longitude: 0)],
        interactive: true);
    expect(
        hitTestPolylines([lower, top, decoration, invalid], manager,
                const ui.Offset(100, 100))!
            .polyline,
        same(top));
    expect(hitTestPolylines([decoration], manager, const ui.Offset(100, 100)),
        isNull);
    expect(
        hitTestPolylines([decoration], manager, const ui.Offset(100, 100),
                enableAll: true)!
            .polyline,
        same(decoration));
  });

  test(
      'dashed routes select continuously and remain aligned after camera changes',
      () {
    final route = MapPolyline(
        points: [at(20, 100), at(180, 100)],
        interactive: true,
        pattern: const MapPolylinePattern.dashed(dashLength: 2, gapLength: 30));
    expect(hitTestPolylines([route], manager, const ui.Offset(35, 100)),
        isNotNull);
    manager.zoom = 5;
    manager.setCenterTile(latLng: const LatLng(latitude: 0, longitude: 5));
    final position = manager.latLngToScreen(route.points.first);
    expect(hitTestPolylines([route], manager, position), isNotNull);
  });

  test(
      'polygon interiors select, holes pass through, and painted borders select',
      () {
    final polygon = MapPolygon(
        points: square(20, 180),
        holes: [square(70, 130)],
        interactive: true,
        hitTolerance: 0);
    expect(hitTestPolygons([polygon], manager, const ui.Offset(40, 40)),
        isNotNull);
    expect(
        hitTestPolygons([polygon], manager, const ui.Offset(100, 100)), isNull);
    expect(hitTestPolygons([polygon], manager, const ui.Offset(70, 100)),
        isNotNull);
    expect(
        hitTestPolygons([polygon], manager, const ui.Offset(10, 100)), isNull);
    final noBorder = MapPolygon(
        points: polygon.points,
        holes: polygon.holes,
        borderWidth: 0,
        interactive: true);
    expect(hitTestPolygons([noBorder], manager, const ui.Offset(100, 100)),
        isNull);
  });

  test('polygon selection obeys order, eligibility, and transient geometry',
      () {
    final lower = MapPolygon(points: square(20, 180), interactive: true);
    final upper = MapPolygon(points: square(30, 170), onTap: (_) {});
    final decoration = MapPolygon(points: square(10, 190));
    expect(
        hitTestPolygons(
                [lower, upper, decoration], manager, const ui.Offset(50, 50))!
            .polygon,
        same(upper));
    expect(
        hitTestPolygons([upper], manager, const ui.Offset(50, 50),
            longPress: true),
        isNull);
    expect(projectPolygon(const MapPolygon(points: []), manager), isNull);
    expect(
        projectPolygon(
            const MapPolygon(points: [
              LatLng(latitude: double.nan, longitude: 0),
              LatLng(latitude: 0, longitude: 0),
              LatLng(latitude: 1, longitude: 1)
            ]),
            manager),
        isNull);
  });

  testWidgets('polygon pixels match fill, hole, outline, and camera projection',
      (tester) async {
    final polygon = MapPolygon(
        points: square(20, 180),
        holes: [square(70, 130)],
        color: const ui.Color(0xFFFF0000),
        borderColor: const ui.Color(0xFF0000FF),
        borderWidth: 4);
    Future<ByteData> render() async {
      final recorder = ui.PictureRecorder();
      PolygonPainter(polygons: [polygon], manager: manager)
          .paint(ui.Canvas(recorder), const ui.Size(200, 200));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 200);
      picture.dispose();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    }

    final pixels = (await tester.runAsync(render))!;
    int channel(int x, int y, int c) => pixels.getUint8((y * 200 + x) * 4 + c);
    expect(channel(40, 40, 0), 255);
    expect(channel(100, 100, 3), 0);
    expect(channel(20, 100, 2), 255);
    expect(channel(5, 5, 3), 0);
    manager.setCenterFromTileCoords(
        manager.centerTileLng + 40 / 256, manager.centerTileLat);
    final shifted = (await tester.runAsync(render))!;
    expect(shifted.getUint8((40 * 200 + 30) * 4), 255);
    expect(shifted.getUint8((100 * 200 + 60) * 4 + 3), 0);
  });
}
