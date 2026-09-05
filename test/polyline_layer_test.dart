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
  List<MapPolyline> polylines, {
  int zoom = _testZoom,
}) async {
  final manager = _manager(zoom: zoom);
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

    testWidgets('draws a border outside the main stroke', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-20, 0),
            _pointAtPixelOffset(20, 0),
          ],
          color: Colors.blue,
          strokeWidth: 6,
          borderColor: Colors.white,
          borderWidth: 3,
        ),
      ]);

      // Main stroke center is blue.
      expect(pixels.blue(50, 50), 243);
      // Border pixels are outside the main stroke on both sides.
      expect(pixels.alpha(50, 45), greaterThan(0));
      expect(pixels.red(50, 45), greaterThan(200));
      expect(pixels.green(50, 45), greaterThan(200));
      expect(pixels.blue(50, 45), greaterThan(200));
      expect(pixels.alpha(50, 57), 0);
    });

    testWidgets('uses configurable stroke caps', (tester) async {
      final round = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-20, 0),
            _pointAtPixelOffset(20, 0),
          ],
          color: Colors.red,
          strokeWidth: 10,
          strokeCap: StrokeCap.round,
        ),
      ]);
      final butt = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-20, 0),
            _pointAtPixelOffset(20, 0),
          ],
          color: Colors.red,
          strokeWidth: 10,
          strokeCap: StrokeCap.butt,
        ),
      ]);

      // Round caps extend past the endpoint; butt caps do not.
      expect(round.alpha(26, 50), greaterThan(0));
      expect(butt.alpha(26, 50), 0);
    });

    testWidgets('renders dashed patterns with gaps', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-30, 0),
            _pointAtPixelOffset(30, 0),
          ],
          color: Colors.red,
          strokeWidth: 4,
          pattern: const MapPolylinePattern.dashed(
            dashLength: 10,
            gapLength: 10,
          ),
        ),
      ]);

      // Dash interval at distance 20..30 from the left endpoint.
      expect(pixels.alpha(45, 50), greaterThan(0));
      // Gap interval at distance 30..40 from the left endpoint.
      expect(pixels.alpha(55, 50), 0);
    });

    testWidgets('dashed border and inner dash align', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-30, 0),
            _pointAtPixelOffset(30, 0),
          ],
          color: Colors.blue,
          strokeWidth: 4,
          borderColor: Colors.white,
          borderWidth: 2,
          pattern: const MapPolylinePattern.dashed(
            dashLength: 10,
            gapLength: 10,
          ),
        ),
      ]);

      // A dash exists and its surrounding border is visible.
      expect(pixels.alpha(45, 50), greaterThan(0));
      expect(pixels.alpha(45, 46), greaterThan(0));
      expect(pixels.red(45, 46), greaterThan(200));
    });

    testWidgets('renders dotted patterns with spacing', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-30, 0),
            _pointAtPixelOffset(30, 0),
          ],
          color: Colors.red,
          strokeWidth: 6,
          pattern: const MapPolylinePattern.dotted(spacing: 20),
        ),
      ]);

      // Dot center at the first repeat point (distance == spacing).
      expect(pixels.alpha(40, 50), greaterThan(0));
      // Midpoint between first and second dot is a gap.
      expect(pixels.alpha(30, 50), 0);
    });

    testWidgets('dotted phase continues across route vertices', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-20, 0),
            _pointAtPixelOffset(-5, 0),
            _pointAtPixelOffset(-5, 25),
          ],
          color: Colors.red,
          strokeWidth: 4,
          pattern: const MapPolylinePattern.dotted(spacing: 20),
        ),
      ]);

      // Segment 1 is 15px and segment 2 is 25px. With spacing 20, the second
      // dot lands at cumulative distance 20 (5px along segment 2) rather than
      // resetting at the vertex (distance 15), leaving the vertex unpainted.
      expect(pixels.alpha(45, 55), greaterThan(0));
      expect(pixels.alpha(45, 50), 0);
      // The route ends at cumulative distance 40; no irregular extra endpoint
      // dot is forced when the sampling loop reaches the exact path length.
      expect(pixels.alpha(45, 70), 0);
    });

    testWidgets(
        'configurable joins render distinct silhouettes and miter limits',
        (tester) async {
      Future<_Pixels> renderWithJoin(
        StrokeJoin join, {
        double miterLimit = 4,
      }) =>
          _render(tester, [
            MapPolyline(
              points: [
                _pointAtPixelOffset(-20, -10),
                _pointAtPixelOffset(0, 10),
                _pointAtPixelOffset(20, -10),
              ],
              color: Colors.red,
              strokeWidth: 12,
              strokeJoin: join,
              strokeMiterLimit: miterLimit,
            ),
          ]);

      final round = await renderWithJoin(StrokeJoin.round);
      final bevel = await renderWithJoin(StrokeJoin.bevel);
      final miter = await renderWithJoin(StrokeJoin.miter);
      final clippedMiter =
          await renderWithJoin(StrokeJoin.miter, miterLimit: 1);

      // All joins paint the shared vertex.
      expect(round.alpha(50, 60), greaterThan(0));
      expect(bevel.alpha(50, 60), greaterThan(0));
      expect(miter.alpha(50, 60), greaterThan(0));

      // At (50, 65): round and miter extend past the bevel's cut edge.
      expect(round.alpha(50, 65), greaterThan(0));
      expect(bevel.alpha(50, 65), 0);
      expect(miter.alpha(50, 65), greaterThan(0));

      // At (50, 68): miter tip extends further than round.
      expect(round.alpha(50, 68), 0);
      expect(miter.alpha(50, 68), greaterThan(0));

      // Low miter limit clips the sharp spike to bevel behavior.
      expect(clippedMiter.alpha(50, 68), 0);
    });

    testWidgets('uses square stroke caps with corner extension',
        (tester) async {
      final points = [
        _pointAtPixelOffset(-20, 0),
        _pointAtPixelOffset(20, 0),
      ];
      final butt = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.red,
          strokeWidth: 10,
          strokeCap: StrokeCap.butt,
        ),
      ]);
      final round = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.red,
          strokeWidth: 10,
          strokeCap: StrokeCap.round,
        ),
      ]);
      final square = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.red,
          strokeWidth: 10,
          strokeCap: StrokeCap.square,
        ),
      ]);

      // Endpoint is at (30, 50).
      // Butt does not extend past x = 30.
      expect(butt.alpha(27, 50), 0);
      // Round and square both extend past x = 30 along the center line.
      expect(round.alpha(27, 50), greaterThan(0));
      expect(square.alpha(27, 50), greaterThan(0));

      // At the cap corner (25, 45): square covers the corner while round does not.
      expect(butt.alpha(25, 45), 0);
      expect(round.alpha(25, 45), 0);
      expect(square.alpha(25, 45), greaterThan(0));
    });

    testWidgets('dashed pattern respects offset and negative normalization',
        (tester) async {
      final points = [
        _pointAtPixelOffset(-30, 0),
        _pointAtPixelOffset(30, 0),
      ];

      // Positive offset: first dash is delayed by offset.
      final positive = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.red,
          strokeWidth: 4,
          pattern: const MapPolylinePattern.dashed(
            dashLength: 10,
            gapLength: 10,
            offset: 6,
          ),
        ),
      ]);
      // Left endpoint is at screen (20, 50).
      // Interval [0, 6) is gap: at screen (22, 50), distance 2 is transparent.
      expect(positive.alpha(22, 50), 0);
      // Interval [6, 16] is dash: at screen (30, 50), distance 10 is painted.
      expect(positive.alpha(30, 50), greaterThan(0));

      // Negative offset: normalized modulo cycle (20). -4 % 20 == 16.
      // First dash starts at distance 16.
      final negative = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.red,
          strokeWidth: 4,
          pattern: const MapPolylinePattern.dashed(
            dashLength: 10,
            gapLength: 10,
            offset: -4,
          ),
        ),
      ]);
      // At screen (25, 50), distance 5 is in the initial gap before distance 16.
      expect(negative.alpha(25, 50), 0);
      // At screen (40, 50), distance 20 is inside the first dash [16, 26].
      expect(negative.alpha(40, 50), greaterThan(0));
    });

    testWidgets('dotted pattern respects offset and negative normalization',
        (tester) async {
      final points = [
        _pointAtPixelOffset(-30, 0),
        _pointAtPixelOffset(30, 0),
      ];

      // Positive offset: first dot starts at offset.
      final positive = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.red,
          strokeWidth: 4,
          pattern: const MapPolylinePattern.dotted(
            spacing: 20,
            offset: 8,
          ),
        ),
      ]);
      // Endpoint is at screen (20, 50).
      // Dot at distance 8: screen (28, 50) is painted.
      expect(positive.alpha(28, 50), greaterThan(0));
      // Distance 0 at screen (20, 50) has no dot.
      expect(positive.alpha(20, 50), 0);

      // Negative offset: normalized modulo spacing (20). -6 % 20 == 14.
      final negative = await _render(tester, [
        MapPolyline(
          points: points,
          color: Colors.red,
          strokeWidth: 4,
          pattern: const MapPolylinePattern.dotted(
            spacing: 20,
            offset: -6,
          ),
        ),
      ]);
      // Dot at distance 14: screen (34, 50) is painted.
      expect(negative.alpha(34, 50), greaterThan(0));
      // Distance 8 at screen (28, 50) has no dot.
      expect(negative.alpha(28, 50), 0);
    });

    testWidgets('dash continues through a non-cycle-aligned vertex',
        (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-30, 0),
            _pointAtPixelOffset(-15, 0),
            _pointAtPixelOffset(-15, 25),
          ],
          color: Colors.red,
          strokeWidth: 4,
          strokeCap: StrokeCap.butt,
          pattern: const MapPolylinePattern.dashed(
            dashLength: 20,
            gapLength: 10,
          ),
        ),
      ]);

      // Segment 1 is 15px (screen (20, 50) to (35, 50)).
      // Dash length is 20px, so it crosses the corner at (35, 50) and continues
      // 5px down segment 2 to screen (35, 55).
      expect(pixels.alpha(35, 50), greaterThan(0));
      expect(pixels.alpha(35, 53), greaterThan(0));
      // Gap runs from distance 20 to 30: screen (35, 60) is distance 25 (gap).
      expect(pixels.alpha(35, 60), 0);
    });

    testWidgets('pattern phase remains stable when route starts off-screen',
        (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(-80, 0),
            _pointAtPixelOffset(30, 0),
          ],
          color: Colors.red,
          strokeWidth: 4,
          strokeCap: StrokeCap.butt,
          pattern: const MapPolylinePattern.dashed(
            dashLength: 20,
            gapLength: 10,
          ),
        ),
      ]);

      // Route starts off-screen at screen (-30, 50).
      // Dash 0: -30..-10
      // Gap 0: -10..0
      // Dash 1: 0..20
      // Gap 1: 20..30
      // Dash 2: 30..50
      // Gap 2: 50..60
      // Dash 3: 60..80
      // Visible dash 2 covers screen x = 30..50.
      expect(pixels.alpha(40, 50), greaterThan(0));
      // Gap 2 covers screen x = 50..60.
      expect(pixels.alpha(55, 50), 0);
      // Dash 3 covers screen x = 60..80.
      expect(pixels.alpha(70, 50), greaterThan(0));
    });

    testWidgets('renders dotted borders with correct radii', (tester) async {
      final pixels = await _render(tester, [
        MapPolyline(
          points: [
            _pointAtPixelOffset(0, 0),
            _pointAtPixelOffset(40, 0),
          ],
          color: Colors.blue,
          strokeWidth: 6,
          borderColor: Colors.white,
          borderWidth: 3,
          pattern: const MapPolylinePattern.dotted(spacing: 20),
        ),
      ]);

      // Dot center is at screen (50, 50).
      // Inner radius is 3, border radius is 6.
      // At center: inner color (blue).
      expect(pixels.blue(50, 50), greaterThan(200));
      // At distance 4 from center (50, 54): border color (white).
      expect(pixels.red(50, 54), greaterThan(200));
      expect(pixels.green(50, 54), greaterThan(200));
      expect(pixels.blue(50, 54), greaterThan(200));
      // At distance 8 from center (50, 58): outside dot border.
      expect(pixels.alpha(50, 58), 0);
    });

    testWidgets('fast-forwards patterns to a distant visible route section',
        (tester) async {
      const zoom = 19;
      final pixels = await _render(
        tester,
        [
          MapPolyline(
            points: [
              _pointAtPixelOffset(-2100000, -10, zoom: zoom),
              _pointAtPixelOffset(30, -10, zoom: zoom),
            ],
            color: Colors.red,
            strokeWidth: 4,
            strokeCap: StrokeCap.butt,
            pattern: const MapPolylinePattern.dashed(
              dashLength: 10,
              gapLength: 10,
            ),
          ),
          MapPolyline(
            points: [
              _pointAtPixelOffset(-2100000, 10, zoom: zoom),
              _pointAtPixelOffset(30, 10, zoom: zoom),
            ],
            color: Colors.blue,
            strokeWidth: 4,
            pattern: const MapPolylinePattern.dotted(spacing: 20),
          ),
        ],
        zoom: zoom,
      );

      // The viewport is more than 100,000 pattern cycles from each route
      // start, but visible marks are found directly rather than by walking
      // every preceding cycle.
      expect(pixels.red(55, 40), greaterThan(0));
      expect(pixels.alpha(65, 40), 0);
      expect(pixels.blue(50, 60), greaterThan(0));
      expect(pixels.alpha(60, 60), 0);
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
