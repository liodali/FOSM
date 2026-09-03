import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
import 'package:fosm/src/view/polyline_layer.dart';

const _center = LatLng(latitude: 0, longitude: 0);
const _testZoom = 3;
const _paintSize = Size(100, 100);

final Uint8List _tinyPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Future<Uint8List> _stubFetcher(int z, int x, int y) async => _tinyPng;

LatLng _pointAtPixelOffset(
  double dx,
  double dy, {
  int zoom = _testZoom,
}) {
  return LatLng(
    latitude: tileY2Lat(lat2TileY(0, zoom) + dy / 256, zoom),
    longitude: tileX2Lng(lon2TileX(0, zoom) + dx / 256, zoom),
  );
}

TileManager _manager({int zoom = _testZoom}) {
  return TileManager.init(
    width: 100,
    height: 100,
    centerLatLng: _center,
    zoom: zoom,
    fetcher: _stubFetcher,
    tilePadding: 0,
    preloadAdjacentZoom: false,
  );
}

class _Pixels {
  final ByteData data;
  final int width;

  const _Pixels(this.data, this.width);

  int red(int x, int y) => data.getUint8((y * width + x) * 4);
  int green(int x, int y) => data.getUint8((y * width + x) * 4 + 1);
  int blue(int x, int y) => data.getUint8((y * width + x) * 4 + 2);
  int alpha(int x, int y) => data.getUint8((y * width + x) * 4 + 3);
}

Future<_Pixels> _render(
  WidgetTester tester,
  List<MapPolyline> polylines,
) async {
  final manager = _manager();
  try {
    final pixels = await tester.runAsync<_Pixels>(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      PolylinePainter(polylines: polylines, manager: manager).paint(
        canvas,
        _paintSize,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        _paintSize.width.toInt(),
        _paintSize.height.toInt(),
      );
      picture.dispose();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return _Pixels(bytes!, _paintSize.width.toInt());
    });
    return pixels!;
  } finally {
    manager.dispose();
  }
}

Finder get _polylinePaints => find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is PolylinePainter,
    );

PolylinePainter _currentPainter(WidgetTester tester) {
  final customPaint = tester.widget<CustomPaint>(_polylinePaints);
  return customPaint.painter! as PolylinePainter;
}

Widget _map({
  required List<MapPolyline> polylines,
  MapController? controller,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MapView(
        controller: controller,
        latLng: _center,
        zoom: _testZoom,
        tileFetcher: _stubFetcher,
        polylines: polylines,
        showZoomControls: false,
        animateZoom: false,
      ),
    ),
  );
}

class _PolylineHarness extends StatefulWidget {
  final List<MapPolyline> initialPolylines;

  const _PolylineHarness({
    super.key,
    required this.initialPolylines,
  });

  @override
  State<_PolylineHarness> createState() => _PolylineHarnessState();
}

class _PolylineHarnessState extends State<_PolylineHarness> {
  late List<MapPolyline> polylines = widget.initialPolylines;

  void replaceWith(List<MapPolyline> value) {
    setState(() => polylines = value);
  }

  @override
  Widget build(BuildContext context) => _map(polylines: polylines);
}

void main() {
  group('PolylinePainter geometry', () {
    testWidgets('projects the map center and consecutive points in order',
        (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-30, -30),
            _pointAtPixelOffset(30, -30),
            _pointAtPixelOffset(30, 30),
          ],
          color: Colors.red,
          strokeWidth: 4,
        ),
      ]);

      expect(pixels.red(50, 20), 244);
      expect(pixels.red(80, 50), 244);
      expect(pixels.alpha(50, 50), 0);
    });

    testWidgets('empty and one-point lines paint nothing', (tester) async {
      final pixels = await _render(tester, const [
        MapPolyline(points: []),
        MapPolyline(points: [LatLng(latitude: 0, longitude: 0)]),
      ]);

      expect(pixels.alpha(50, 50), 0);
    });

    testWidgets('keeps independent polylines disconnected', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-30, -20),
            _pointAtPixelOffset(-10, -20),
          ],
          color: Colors.red,
        ),
        MapPolyline(
          points: [
            _pointAtPixelOffset(10, 20),
            _pointAtPixelOffset(30, 20),
          ],
          color: Colors.blue,
        ),
      ]);

      expect(pixels.red(30, 30), 244);
      expect(pixels.blue(70, 70), 243);
      expect(pixels.alpha(50, 50), 0);
    });

    testWidgets('clips rather than culls a crossing off-screen segment',
        (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-70, 0),
            _pointAtPixelOffset(70, 0),
          ],
          color: Colors.red,
          strokeWidth: 4,
        ),
      ]);

      expect(pixels.alpha(0, 50), greaterThan(0));
      expect(pixels.red(50, 50), 244);
      expect(pixels.alpha(99, 50), greaterThan(0));
    });
  });

  group('PolylinePainter styling', () {
    testWidgets('uses custom color and stroke width', (tester) async {
      final points = [
        _pointAtPixelOffset(-20, 0),
        _pointAtPixelOffset(20, 0),
      ];
      final thin = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.green,
          strokeWidth: 2,
        ),
      ]);
      final thick = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.green,
          strokeWidth: 8,
        ),
      ]);

      expect(thin.alpha(50, 53), 0);
      expect(thick.green(50, 53), 175);
      expect(thick.alpha(50, 53), 255);
    });

    testWidgets('uses round caps', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-20, 0),
            _pointAtPixelOffset(20, 0),
          ],
          color: Colors.red,
          strokeWidth: 10,
        ),
      ]);

      expect(pixels.alpha(26, 50), greaterThan(0));
      expect(pixels.alpha(24, 50), 0);
    });

    testWidgets('transparent colors paint no visible pixels', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-20, 0),
            _pointAtPixelOffset(20, 0),
          ],
          color: Colors.transparent,
          strokeWidth: 8,
        ),
      ]);

      expect(pixels.alpha(50, 50), 0);
    });

    testWidgets('later polylines paint above earlier polylines',
        (tester) async {
      final points = [
        _pointAtPixelOffset(-20, 0),
        _pointAtPixelOffset(20, 0),
      ];
      final pixels = await _render(tester, [
        MapPolyline(points: points, color: Colors.red, strokeWidth: 8),
        MapPolyline(points: points, color: Colors.blue, strokeWidth: 4),
      ]);

      expect(pixels.red(50, 50), 33);
      expect(pixels.blue(50, 50), 243);
      expect(pixels.alpha(50, 50), 255);
    });

    test('always repaints because TileManager is mutable', () {
      final manager = _manager();
      addTearDown(manager.dispose);
      final oldPainter = PolylinePainter(polylines: const [], manager: manager);
      final painter = PolylinePainter(polylines: const [], manager: manager);

      expect(painter.shouldRepaint(oldPainter), isTrue);
    });
  });

  group('PolylineLayer widget integration', () {
    testWidgets('MapView omits the layer when no polylines are configured',
        (tester) async {
      await tester.pumpWidget(_map(polylines: const []));

      expect(find.byType(PolylineLayer), findsNothing);
      expect(_polylinePaints, findsNothing);
    });

    testWidgets('renders through an IgnorePointer', (tester) async {
      await tester.pumpWidget(
        _map(
          polylines: const [
            MapPolyline(
              points: [
                LatLng(latitude: 0, longitude: -1),
                LatLng(latitude: 0, longitude: 1),
              ],
            ),
          ],
        ),
      );

      expect(find.byType(PolylineLayer), findsOneWidget);
      expect(_polylinePaints, findsOneWidget);
      final ignorePointer = tester.widget<IgnorePointer>(
        find.descendant(
          of: find.byType(PolylineLayer),
          matching: find.byType(IgnorePointer),
        ),
      );
      expect(ignorePointer.ignoring, isTrue);
    });

    testWidgets('replaces and clears routes on parent rebuild', (tester) async {
      final key = GlobalKey<_PolylineHarnessState>();
      const initial = [
        MapPolyline(
          points: [
            LatLng(latitude: 0, longitude: -1),
            LatLng(latitude: 0, longitude: 1),
          ],
        ),
      ];
      final replacement = [
        const MapPolyline(
          points: [
            LatLng(latitude: -1, longitude: 0),
            LatLng(latitude: 1, longitude: 0),
          ],
          color: Colors.orange,
        ),
      ];

      await tester.pumpWidget(
        _PolylineHarness(key: key, initialPolylines: initial),
      );
      expect(_currentPainter(tester).polylines, same(initial));

      key.currentState!.replaceWith(replacement);
      await tester.pump();
      expect(_currentPainter(tester).polylines, same(replacement));

      key.currentState!.replaceWith(const []);
      await tester.pump();
      expect(find.byType(PolylineLayer), findsNothing);
    });

    testWidgets('reprojects after pan without consuming the gesture',
        (tester) async {
      const route = [
        MapPolyline(
          points: [
            LatLng(latitude: 0, longitude: 0),
            LatLng(latitude: 0, longitude: 1),
          ],
        ),
      ];
      await tester.pumpWidget(_map(polylines: route));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final before = _currentPainter(tester).manager.latLngToScreen(_center);
      expect(before, const Offset(400, 300));

      await tester.dragFrom(const Offset(400, 300), const Offset(-100, 0));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final after = _currentPainter(tester).manager.latLngToScreen(_center);
      expect(after.dx, closeTo(320, 0.5));
      expect(after.dy, closeTo(300, 0.5));
    });

    testWidgets('reprojects after controller zoom and movement',
        (tester) async {
      final controller = MapController();
      final east = _pointAtPixelOffset(40, 0);
      final route = [
        MapPolyline(points: [_center, east]),
      ];
      await tester.pumpWidget(
        _map(polylines: route, controller: controller),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      var painter = _currentPainter(tester);
      expect(
        painter.manager.latLngToScreen(east).dx,
        closeTo(440, 0.01),
      );

      controller.setZoom(4, animate: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      painter = _currentPainter(tester);
      expect(
        painter.manager.latLngToScreen(east).dx,
        closeTo(480, 0.01),
      );

      controller.moveTo(east, animate: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      painter = _currentPainter(tester);
      expect(
        painter.manager.latLngToScreen(east),
        const Offset(400, 300),
      );
    });
  });
}
