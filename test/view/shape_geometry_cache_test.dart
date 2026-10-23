// Geometry cache, segment index and culling parity regressions.
//
// The acceptance bar for the geometry performance plan: hit-test answers
// and exported appearance must not change. Every parity check here
// compares the cached/indexed/culled paths against the original direct
// algorithms (full projection + full scans), never against the index
// itself.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/view/polygon_layer.dart';
import 'package:fosm/src/view/polyline_layer.dart';
import 'package:fosm/src/view/shape_geometry.dart';
import 'package:fosm/src/view/shape_geometry_cache.dart';

const _size = ui.Size(200, 200);

TileManager _manager(
    {int zoom = 3, LatLng center = const LatLng(latitude: 0, longitude: 0)}) {
  return TileManager.init(
    width: _size.width,
    height: _size.height,
    centerLatLng: center,
    zoom: zoom,
    fetcher: (z, x, y) => Completer<Uint8List>().future,
    tilePadding: 0,
    preloadAdjacentZoom: false,
  );
}

List<LatLng> _zigzag(int count, double latSpan, double lngSpan,
    {LatLng center = const LatLng(latitude: 0, longitude: 0)}) {
  return [
    for (var i = 0; i < count; i++)
      LatLng(
        latitude:
            (center.latitude + math.sin(i * 0.7) * latSpan).clamp(-84.9, 84.9),
        longitude: (center.longitude + (i / math.max(1, count - 1) - 0.5) *
                lngSpan)
            .clamp(-179.9, 179.9),
      ),
  ];
}

/// Dense polygon ring (screen-space circle converted to coordinates).
List<LatLng> _circle(int count, double radiusDegrees,
    {LatLng center = const LatLng(latitude: 0, longitude: 0)}) {
  return [
    for (var i = 0; i < count; i++)
      LatLng(
        latitude: (center.latitude +
                math.sin(i * 2 * math.pi / count) * radiusDegrees)
            .clamp(-84.9, 84.9),
        longitude: (center.longitude +
                math.cos(i * 2 * math.pi / count) * radiusDegrees)
            .clamp(-179.9, 179.9),
      ),
  ];
}

void main() {
  group('ShapeCamera projection parity', () {
    test('cached world projection is bit-identical to latLngToScreen',
        () {
      final rng = math.Random(20261023);
      final probes = <LatLng>[
        // Structured edges plus randomized points.
        for (var i = 0; i < 200; i++)
          LatLng(
            latitude: rng.nextDouble() * 168 - 84,
            longitude: rng.nextDouble() * 358 - 179,
          ),
        const LatLng(latitude: 0, longitude: 0),
        const LatLng(latitude: 85.0511287798066, longitude: 180),
        const LatLng(latitude: -85.0511287798066, longitude: -180),
        const LatLng(latitude: 84.9, longitude: 0.0001),
        const LatLng(latitude: 89.9, longitude: 100), // off-world, painted
        const LatLng(latitude: 90, longitude: 0), // projects to infinity
      ];
      for (final zoom in [0, 1, 3, 8, 14, 20]) {
        final manager = _manager(zoom: zoom);
        addTearDown(manager.dispose);
        for (final cameraCenter in [
          const LatLng(latitude: 0, longitude: 0),
          const LatLng(latitude: 47.3769, longitude: 8.5417),
          const LatLng(latitude: -33.9, longitude: 151.2),
        ]) {
          manager.setCenterTile(latLng: cameraCenter);
          final cache = ShapeGeometryCache();
          final ring = cache.ring(probes);
          final camera = ShapeCamera.of(manager);
          for (var i = 0; i < probes.length; i++) {
            final expected = manager.latLngToScreen(probes[i]);
            final actual = camera.toScreen(ring.nx[i], ring.ny[i]);
            if (expected.dx.isNaN || expected.dy.isNaN) {
              expect(actual.dx.isNaN || actual.dy.isNaN, isTrue,
                  reason: 'NaN must project to NaN at zoom $zoom');
            } else {
              expect(actual, expected,
                  reason:
                      'offset must be bit-identical at zoom $zoom for $i');
            }
          }
        }
      }
    });
  });

  group('projectRingCached parity', () {
    test('accepts and rejects exactly what projectRing does', () {
      final manager = _manager();
      addTearDown(manager.dispose);
      final cache = ShapeGeometryCache();
      final cases = <List<LatLng>>[
        [const LatLng(latitude: 0, longitude: -1), const LatLng(latitude: 1, longitude: 1)],
        const [],
        [const LatLng(latitude: 0, longitude: 0)],
        [const LatLng(latitude: 86, longitude: 0), const LatLng(latitude: 0, longitude: 0)],
        [const LatLng(latitude: 0, longitude: 181), const LatLng(latitude: 0, longitude: 0)],
        [const LatLng(latitude: 0, longitude: -180.5), const LatLng(latitude: 0, longitude: 0)],
        [const LatLng(latitude: double.nan, longitude: 0), const LatLng(latitude: 0, longitude: 0)],
        [const LatLng(latitude: 0, longitude: double.infinity), const LatLng(latitude: 0, longitude: 0)],
        [const LatLng(latitude: 90, longitude: 0), const LatLng(latitude: 0, longitude: 0)],
        _zigzag(64, 40, 100),
      ];
      for (final points in cases) {
        final direct = projectRing(points, manager);
        final cached = projectRingCached(points, manager, cache);
        expect(cached == null, direct == null,
            reason: 'acceptance must match for ${points.length} points');
        if (direct != null) {
          expect(cached!.length, direct.length);
          for (var i = 0; i < direct.length; i++) {
            expect(cached[i], direct[i],
                reason: 'offset $i must be bit-identical');
          }
        }
      }
    });
  });

  group('ShapeGeometryCache retention', () {
    test('keys entries by points-list identity', () {
      final cache = ShapeGeometryCache();
      final points = _zigzag(8, 1, 2);
      final first = cache.ring(points);
      expect(cache.ring(points), same(first));
      expect(cache.debugRingBuilds, 1);

      // Equal contents, different list: a new data revision.
      final copy = List<LatLng>.of(points);
      final rebuilt = cache.ring(copy);
      expect(identical(rebuilt, first), isFalse);
      expect(cache.debugRingBuilds, 2);
      expect(cache.debugRingCount, 2);
    });

    test('style-only rebuilds reuse the cached ring', () {
      final cache = ShapeGeometryCache();
      final points = _zigzag(12, 1, 2);
      final withStyleA = MapPolyline(points: points);
      final withStyleB = MapPolyline(
        points: points,
        color: const ui.Color(0xFF000000),
        strokeWidth: 9,
        pattern: const MapPolylinePattern.dashed(),
      );
      final ringA = cache.ring(withStyleA.points);
      final ringB = cache.ring(withStyleB.points);
      expect(ringB, same(ringA));
      expect(cache.debugRingBuilds, 1);
      expect(identical(withStyleA.points, withStyleB.points), isTrue);
    });

    test('evicts least-recently-used entries beyond the budget', () {
      final cache = ShapeGeometryCache(maxCachedVertices: 10);
      final listA = _zigzag(5, 1, 2);
      final listB = _zigzag(5, 1, 2);
      final a = cache.ring(listA);
      cache.ring(listB);
      expect(cache.debugRingCount, 2);
      expect(cache.debugCachedVertices, 10);

      // A third 5-vertex ring exceeds the budget: the eldest (A) leaves.
      final listC = _zigzag(5, 1, 2);
      cache.ring(listC);
      expect(cache.debugRingCount, 2);
      expect(cache.debugCachedVertices, 10);
      expect(cache.debugRingBuilds, 3);

      // A was evicted: re-requesting it rebuilds a fresh entry (and the
      // insertion evicts B, now the eldest).
      final rebuiltA = cache.ring(listA);
      expect(cache.debugRingBuilds, 4);
      expect(identical(rebuiltA, a), isFalse);

      // C survived the last eviction: no rebuild.
      final cAgain = cache.ring(listC);
      expect(identical(cAgain, rebuiltA), isFalse);
      expect(cache.debugRingBuilds, 4, reason: 'C must still be resident');
    });

    test('never evicts the ring being inserted even when oversized', () {
      final cache = ShapeGeometryCache(maxCachedVertices: 4);
      cache.ring(_zigzag(40, 1, 2));
      expect(cache.debugRingCount, 1);
      expect(cache.debugCachedVertices, 40);
    });

    test('segment grids charge the budget', () {
      final cache = ShapeGeometryCache(maxCachedVertices: 700);
      final dense = _zigzag(600, 1, 1);
      final small = _zigzag(10, 1, 1);
      cache.ring(small);
      expect(cache.debugCachedVertices, 10);
      final ring = cache.ring(dense);
      expect(cache.debugCachedVertices, 610);
      // Building the grid doubles the ring's charge and evicts `small`.
      final grid = cache.gridFor(ring, dense);
      expect(grid, isNotNull);
      expect(cache.debugCachedVertices, 1200);
      expect(cache.debugRingCount, 1);
    });

    test('stays bounded when live updates replace the points list', () {
      final cache = ShapeGeometryCache(); // default 262144 vertex units
      var latest = _zigzag(1000, 1, 1);
      for (var frame = 0; frame < 80; frame++) {
        latest = _zigzag(1000, 1, 1);
        cache.ring(latest);
      }
      expect(cache.debugCachedVertices,
          lessThanOrEqualTo(cache.maxCachedVertices));
      // The most recent generation is still resident and not rebuilt.
      expect(cache.debugRingCount, lessThanOrEqualTo(264));
      final buildsBefore = cache.debugRingBuilds;
      final again = cache.ring(latest);
      expect(cache.debugRingBuilds, buildsBefore);
      expect(again.nx.length, 1000);
    });
  });

  group('RingSegmentGrid candidates', () {
    test('include every segment an exact radius test accepts', () {
      final manager = _manager(zoom: 14);
      addTearDown(manager.dispose);
      final cache = ShapeGeometryCache();
      final points = _zigzag(700, 0.01, 0.05);
      final ring = cache.ring(points);
      final grid = cache.gridFor(ring, points);
      expect(grid, isNotNull);
      final camera = ShapeCamera.of(manager);
      final rng = math.Random(99);

      final taps = <ui.Offset>[
        // On-vertex taps, boundary taps and far taps.
        for (var i = 0; i < points.length; i += 37) ...[
          manager.latLngToScreen(points[i]),
          manager.latLngToScreen(points[i]) + const ui.Offset(6, 0),
          manager.latLngToScreen(points[i]) + const ui.Offset(-6, 6),
        ],
        for (var i = 0; i < 30; i++)
          ui.Offset(rng.nextDouble() * 400 - 100, rng.nextDouble() * 400 - 100),
      ];

      for (final tap in taps) {
        for (final radius in [0.0, 3.5, 12.0]) {
          final query = camera.worldQueryRect(tap, radius);
          final candidates = <int>{};
          grid!.query(query, candidates.add);

          var accepted = 0;
          for (var i = 0; i + 1 < points.length; i++) {
            final a = manager.latLngToScreen(points[i]);
            final b = manager.latLngToScreen(points[i + 1]);
            final nearest = nearestOnSegment(tap, a, b);
            if ((nearest - tap).distanceSquared <= radius * radius) {
              accepted++;
              expect(candidates.contains(i), isTrue,
                  reason:
                      'segment $i within radius $radius of $tap must be a '
                      'candidate');
            }
          }
          // A small radius on a dense route must not degrade to a full scan.
          if (radius == 3.5 && accepted == 0) {
            expect(candidates.length, lessThan(points.length ~/ 2),
                reason: 'far taps must not return the whole route');
          }
        }
      }
    });

    test('covers zero-length and grid-spanning oversize segments', () {
      final manager = _manager();
      addTearDown(manager.dispose);
      final cache = ShapeGeometryCache();
      final points = <LatLng>[
        // One world-spanning segment (oversize path in the grid)…
        const LatLng(latitude: 10, longitude: -170),
        const LatLng(latitude: -10, longitude: 170),
        // …dense short zigzag with duplicates…
        for (var i = 0; i < 600; i++)
          LatLng(
              latitude: 0.0005 * math.sin(i * 1.3),
              longitude: -0.01 + i * 0.00003),
        for (var i = 0; i < 4; i++) const LatLng(latitude: 0.001, longitude: 0),
      ];
      final ring = cache.ring(points);
      final grid = cache.gridFor(ring, points);
      expect(grid, isNotNull);
      final camera = ShapeCamera.of(manager);
      manager.setCenterTile(latLng: const LatLng(latitude: 0, longitude: 0));

      // Tap near the duplicate cluster and near the long segment's middle.
      for (final anchor in [
        manager.latLngToScreen(const LatLng(latitude: 0.001, longitude: 0)),
        manager.latLngToScreen(const LatLng(latitude: 0, longitude: 0)),
        manager.latLngToScreen(const LatLng(latitude: 5, longitude: -85)),
      ]) {
        for (final radius in [2.0, 25.0]) {
          final query = camera.worldQueryRect(anchor, radius);
          final candidates = <int>{};
          grid!.query(query, candidates.add);
          for (var i = 0; i + 1 < points.length; i++) {
            final a = manager.latLngToScreen(points[i]);
            final b = manager.latLngToScreen(points[i + 1]);
            final nearest = nearestOnSegment(anchor, a, b);
            if ((nearest - anchor).distanceSquared <= radius * radius) {
              expect(candidates.contains(i), isTrue,
                  reason: 'segment $i near $anchor must be a candidate');
            }
          }
        }
      }
    });
  });

  group('hitTestPolylines parity', () {
    test('indexed selection matches the direct scan exactly', () {
      final manager = _manager();
      addTearDown(manager.dispose);
      final rng = math.Random(7);

      // Stacked routes: interactive, callback-only, decorative, invalid.
      final dense = _zigzag(700, 30, 80);
      final lines = <MapPolyline>[
        MapPolyline(
            points: _zigzag(6, 5, 10),
            interactive: true,
            strokeWidth: 4,
            hitTolerance: 0),
        MapPolyline(
            points: dense,
            onTap: (_) {},
            onLongPress: (_) {},
            strokeWidth: 6,
            borderColor: const ui.Color(0xFFFFFFFF),
            borderWidth: 3,
            hitTolerance: 2),
        MapPolyline(points: _zigzag(40, 8, 20), interactive: true),
        const MapPolyline(points: [
          LatLng(latitude: 0, longitude: -20),
          LatLng(latitude: 0, longitude: 20),
        ]),
        MapPolyline(
            points: [
              const LatLng(latitude: 0, longitude: -5),
              const LatLng(latitude: 89, longitude: 5), // not projectable
            ],
            interactive: true),
        MapPolyline(
            points: _zigzag(9, 3, 6)
              ..addAll(_zigzag(3, 0, 0)), // duplicate vertices
            interactive: true,
            hitTolerance: 7),
      ];

      final taps = <ui.Offset>[
        for (var i = 0; i < dense.length; i += 31)
          manager.latLngToScreen(dense[i]),
        for (final line in lines) ...[
          for (final point in line.points)
            manager.latLngToScreen(point) + const ui.Offset(3, 3),
        ],
        for (var i = 0; i < 60; i++)
          ui.Offset(rng.nextDouble() * 260 - 30, rng.nextDouble() * 260 - 30),
      ];

      final cache = ShapeGeometryCache();
      for (final tap in taps) {
        for (final longPress in [false, true]) {
          for (final enableAll in [false, true]) {
            final direct = hitTestPolylines(lines, manager, tap,
                longPress: longPress, enableAll: enableAll);
            final cached = hitTestPolylines(lines, manager, tap,
                longPress: longPress,
                enableAll: enableAll,
                cache: cache);
            if (direct == null) {
              expect(cached, isNull,
                  reason: 'longPress=$longPress enableAll=$enableAll '
                      'tap=$tap');
              continue;
            }
            expect(cached, isNotNull,
                reason: 'longPress=$longPress enableAll=$enableAll '
                    'tap=$tap');
            expect(identical(cached!.polyline, direct.polyline), isTrue);
            expect(cached.segmentIndex, direct.segmentIndex,
                reason: 'tap=$tap');
            expect(cached.distancePixels, direct.distancePixels,
                reason: 'tap=$tap');
            expect(cached.nearestPoint, direct.nearestPoint,
                reason: 'tap=$tap');
            expect(cached.point, direct.point);
          }
        }
      }
    });

    test('boundary-distance taps agree at the acceptance edge', () {
      final manager = _manager(zoom: 10);
      addTearDown(manager.dispose);
      // Horizontal route at a known screen row; radius is a clean integer.
      final y = 100.0;
      final a = manager.screenToLatLng(ui.Offset(30, y));
      final b = manager.screenToLatLng(ui.Offset(170, y));
      final line = MapPolyline(
          points: [a, b], interactive: true, strokeWidth: 8, hitTolerance: 2);
      final radius = 8 / 2 + 2; // 6
      final cache = ShapeGeometryCache();
      for (final delta in [
        -(radius - 1e-9),
        -radius,
        -(radius + 1e-9),
        -0.0,
        radius - 1e-9,
        radius,
        radius + 1e-9,
      ]) {
        final tap = ui.Offset(100, y + delta);
        final direct = hitTestPolylines([line], manager, tap);
        final cached = hitTestPolylines([line], manager, tap, cache: cache);
        expect(cached == null, direct == null, reason: 'delta=$delta');
        if (direct != null) {
          expect(cached!.segmentIndex, direct.segmentIndex);
          expect(cached.distancePixels, direct.distancePixels);
          expect(cached.nearestPoint, direct.nearestPoint);
        }
      }
    });

    test('prefers the topmost eligible route with identical answers', () {
      final manager = _manager();
      addTearDown(manager.dispose);
      final lower = MapPolyline(
          points: [
            manager.screenToLatLng(const ui.Offset(0, 100)),
            manager.screenToLatLng(const ui.Offset(200, 100)),
          ],
          interactive: true);
      final top = MapPolyline(
          points: [
            manager.screenToLatLng(const ui.Offset(0, 104)),
            manager.screenToLatLng(const ui.Offset(200, 104)),
          ],
          interactive: true);
      final cache = ShapeGeometryCache();
      const tap = ui.Offset(100, 102);
      final direct = hitTestPolylines([lower, top], manager, tap)!;
      final cached =
          hitTestPolylines([lower, top], manager, tap, cache: cache)!;
      expect(identical(cached.polyline, direct.polyline), isTrue);
      expect(identical(direct.polyline, top), isTrue);
      expect(cached.segmentIndex, direct.segmentIndex);
      expect(cached.distancePixels, direct.distancePixels);
    });
  });

  group('hitTestPolygons parity', () {
    test('indexed selection matches the direct scan exactly', () {
      final manager = _manager();
      addTearDown(manager.dispose);
      final rng = math.Random(31);

      LatLng at(double x, double y) => manager.screenToLatLng(ui.Offset(x, y));
      List<LatLng> square(double x0, double y0, double x1, double y1) => [
            at(x0, y0),
            at(x1, y0),
            at(x1, y1),
            at(x0, y1),
          ];

      final denseRing = _circle(800, 20);
      final polygons = <MapPolygon>[
        MapPolygon(points: square(20, 20, 180, 180), interactive: true),
        MapPolygon(
            points: square(40, 40, 160, 160),
            holes: [square(90, 90, 110, 110)],
            interactive: true,
            hitTolerance: 3),
        MapPolygon(
            points: denseRing,
            borderWidth: 5,
            borderColor: const ui.Color(0xFF000000),
            interactive: true,
            hitTolerance: 4),
        MapPolygon(points: square(150, 150, 190, 190)), // decorative
        MapPolygon(
            points: [
              // Not projectable — both paths must skip it.
              const LatLng(latitude: 0, longitude: 200),
              const LatLng(latitude: 1, longitude: 1),
              const LatLng(latitude: 2, longitude: 2),
            ],
            interactive: true),
      ];

      final taps = <ui.Offset>[
        const ui.Offset(100, 100), // hole interior
        const ui.Offset(60, 60), // interior
        const ui.Offset(10, 100), // outside
        const ui.Offset(39, 100), // near border
        const ui.Offset(41, 100),
        const ui.Offset(19, 100), // outer border tolerance edge
        const ui.Offset(21, 100),
        for (var i = 0; i < 200; i++)
          ui.Offset(rng.nextDouble() * 240 - 20, rng.nextDouble() * 240 - 20),
        for (final point in denseRing) manager.latLngToScreen(point),
        for (final point in denseRing)
          manager.latLngToScreen(point) + const ui.Offset(4, 0),
      ];

      final cache = ShapeGeometryCache();
      for (final tap in taps) {
        for (final longPress in [false, true]) {
          for (final enableAll in [false, true]) {
            final direct = hitTestPolygons(polygons, manager, tap,
                longPress: longPress, enableAll: enableAll);
            final cached = hitTestPolygons(polygons, manager, tap,
                longPress: longPress,
                enableAll: enableAll,
                cache: cache);
            if (direct == null) {
              expect(cached, isNull, reason: 'tap=$tap longPress=$longPress');
              continue;
            }
            expect(cached, isNotNull, reason: 'tap=$tap longPress=$longPress');
            expect(identical(cached!.polygon, direct.polygon), isTrue,
                reason: 'tap=$tap');
            expect(cached.point, direct.point);
          }
        }
      }
    });
  });

  group('paint culling parity', () {
    Future<Uint8List> renderToBytes(
        WidgetTester tester, void Function(ui.Canvas, ui.Size) paint) async {
      final bytes = await tester.runAsync<Uint8List>(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        paint(canvas, _size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
            _size.width.toInt(), _size.height.toInt());
        picture.dispose();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      return bytes!;
    }

    /// Spec mirror of the original solid painter: full path, border then
    /// main stroke, identical stroke parameters, no culling.
    ui.Paint referenceStroke(MapPolyline polyline, double width, ui.Color color) =>
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = polyline.strokeCap
          ..strokeJoin = polyline.strokeJoin
          ..strokeMiterLimit = polyline.strokeMiterLimit
          ..color = color
          ..isAntiAlias = true;

    void referenceSolid(
        ui.Canvas canvas, ui.Size size, MapPolyline polyline, TileManager manager) {
      canvas.save();
      canvas.clipRect(ui.Offset.zero & size);
      final path = ui.Path();
      var first = true;
      for (final point in polyline.points) {
        final offset = manager.latLngToScreen(point);
        if (first) {
          path.moveTo(offset.dx, offset.dy);
          first = false;
        } else {
          path.lineTo(offset.dx, offset.dy);
        }
      }
      if (polyline.borderColor != null && polyline.borderWidth > 0) {
        canvas.drawPath(
            path,
            referenceStroke(polyline,
                polyline.strokeWidth + 2 * polyline.borderWidth,
                polyline.borderColor!));
      }
      canvas.drawPath(
          path, referenceStroke(polyline, polyline.strokeWidth, polyline.color));
      canvas.restore();
    }

    testWidgets('solid culling is pixel-identical to a full-path reference',
        (tester) async {
      final manager = _manager(zoom: 5);
      final routes = <MapPolyline>[
        // Thick miter/square-cap route: only a slice is onscreen.
        MapPolyline(
          points: _zigzag(400, 2, 40),
          color: const ui.Color(0xFFCC0000),
          strokeWidth: 14,
          borderColor: const ui.Color(0xFF0000CC),
          borderWidth: 6,
          strokeJoin: ui.StrokeJoin.miter,
          strokeMiterLimit: 6,
          strokeCap: ui.StrokeCap.square,
        ),
        // Zigzag repeatedly crossing the viewport edges.
        MapPolyline(
          points: _zigzag(300, 30, 3,
              center: const LatLng(latitude: 20, longitude: 0)),
          color: const ui.Color(0xFF00AA00),
          strokeWidth: 9,
        ),
        // Fully offscreen route.
        MapPolyline(
          points: _zigzag(50, 1, 2,
              center: const LatLng(latitude: 60, longitude: 120)),
          color: const ui.Color(0xFF0000FF),
          strokeWidth: 30,
        ),
      ];
      for (final route in routes) {
        final painted = await renderToBytes(tester, (canvas, size) {
          PolylinePainter(
                  polylines: [route],
                  manager: manager,
                  cache: ShapeGeometryCache())
              .paint(canvas, size);
        });
        final reference =
            await renderToBytes(tester, (canvas, size) {
          referenceSolid(canvas, size, route, manager);
        });
        if (!kIsWeb) {
          expect(painted, equals(reference),
              reason:
                  'culled solid path must match the full path for width '
                  '${route.strokeWidth}');
          continue;
        }
        // CanvasKit rasterizes a path split into subpaths differently from
        // one continuous contour: identical visible geometry can shift
        // anti-aliased coverage by small amounts (observed channel deltas
        // up to 68 on border/main color boundaries). The contract that
        // must hold everywhere: no pixel may appear or disappear, and
        // channel deltas stay within sub-pixel AA noise. The software
        // rasterizer used on the VM is byte-exact (asserted above).
        var alphaFlips = 0;
        var maxDelta = 0;
        for (var i = 0; i < painted.length; i += 4) {
          if ((painted[i + 3] == 0) != (reference[i + 3] == 0)) {
            alphaFlips++;
          }
          for (var c = 0; c < 4; c++) {
            final delta = (painted[i + c] - reference[i + c]).abs();
            if (delta > maxDelta) maxDelta = delta;
          }
        }
        expect(alphaFlips, 0,
            reason:
                'culling must never add or remove visible geometry (width '
                '${route.strokeWidth})');
        expect(maxDelta, lessThanOrEqualTo(96),
            reason:
                'web deltas must stay within sub-pixel AA noise (width '
                '${route.strokeWidth})');
      }
      manager.dispose();
    });

    testWidgets('cached painter output is pixel-identical to direct projection',
        (tester) async {
      final manager = _manager(zoom: 4);
      final routes = <MapPolyline>[
        MapPolyline(
          points: _zigzag(240, 4, 60),
          strokeWidth: 16,
          borderColor: const ui.Color(0xFF101010),
          borderWidth: 4,
          strokeJoin: ui.StrokeJoin.miter,
          strokeCap: ui.StrokeCap.square,
        ),
        MapPolyline(
          points: _zigzag(200, 6, 40),
          pattern: const MapPolylinePattern.dashed(
              dashLength: 11, gapLength: 7, offset: -3),
          strokeWidth: 7,
          borderColor: const ui.Color(0xFFFFFFFF),
          borderWidth: 3,
        ),
        MapPolyline(
          points: _zigzag(180, 5, 30),
          pattern: const MapPolylinePattern.dotted(spacing: 9, offset: 4),
          strokeWidth: 6,
          borderColor: const ui.Color(0xFFFFFFFF),
          borderWidth: 2,
        ),
      ];
      for (final route in routes) {
        final direct = await renderToBytes(tester, (canvas, size) {
          PolylinePainter(polylines: [route], manager: manager)
              .paint(canvas, size);
        });
        final cached = await renderToBytes(tester, (canvas, size) {
          PolylinePainter(
                  polylines: [route],
                  manager: manager,
                  cache: ShapeGeometryCache())
              .paint(canvas, size);
        });
        expect(cached, equals(direct),
            reason: 'cached projection must match latLngToScreen pixels for '
                '${route.pattern.runtimeType}');
      }
      manager.dispose();
    });

    testWidgets('culling appends only the visible band of segments',
        (tester) async {
      final manager = _manager(zoom: 6);
      // A 20,000-point route spanning ±60° longitude: the 200 px viewport
      // only ever sees a narrow band of it.
      final points = _zigzag(20000, 0.02, 120);
      final route = MapPolyline(points: points, strokeWidth: 8);
      PolylinePainter.debugSolidSegments = 0;
      await renderToBytes(tester, (canvas, size) {
        PolylinePainter(
                polylines: [route],
                manager: manager,
                cache: ShapeGeometryCache())
            .paint(canvas, size);
      });
      final culled = PolylinePainter.debugSolidSegments;
      expect(culled, greaterThan(0));
      expect(culled, lessThan(points.length ~/ 4),
          reason: 'mostly offscreen routes must not append every segment');

      // A route fully inside the viewport keeps every segment.
      final local = _zigzag(50, 0.3, 1);
      PolylinePainter.debugSolidSegments = 0;
      await renderToBytes(tester, (canvas, size) {
        PolylinePainter(polylines: [MapPolyline(points: local)], manager: manager)
            .paint(canvas, size);
      });
      expect(PolylinePainter.debugSolidSegments, local.length - 1);
      manager.dispose();
    });

    testWidgets('polygon bounds culling skips offscreen polygons and keeps '
        'pixels identical', (tester) async {
      final manager = _manager(zoom: 3);
      LatLng at(double x, double y) => manager.screenToLatLng(ui.Offset(x, y));
      List<LatLng> square(double x0, double y0, double x1, double y1) => [
            at(x0, y0),
            at(x1, y0),
            at(x1, y1),
            at(x0, y1),
          ];
      final polygons = <MapPolygon>[
        MapPolygon(
          points: square(30, 30, 150, 150),
          holes: [square(80, 80, 100, 100)],
          color: const ui.Color(0x80FF0000),
          borderColor: const ui.Color(0xFFFF0000),
          borderWidth: 5,
        ),
        // Offscreen (far east) — must be skipped entirely.
        MapPolygon(
          points: square(3000, 3000, 3200, 3200),
          color: const ui.Color(0x800000FF),
        ),
        // Dense ring partially onscreen, thick border.
        MapPolygon(
          points: _circle(800, 20),
          color: const ui.Color(0x4000FF00),
          borderColor: const ui.Color(0xFF00FF00),
          borderWidth: 6,
        ),
      ];

      PolygonPainter.debugPaintedPolygons = 0;
      final painted = await renderToBytes(tester, (canvas, size) {
        PolygonPainter(
                polygons: polygons,
                manager: manager,
                cache: ShapeGeometryCache())
            .paint(canvas, size);
      });
      expect(PolygonPainter.debugPaintedPolygons, 2,
          reason: 'the offscreen polygon must not project or build a path');

      // Reference: original uncached projectPolygon flow without culling.
      final reference = await renderToBytes(tester, (canvas, size) {
        canvas.save();
        canvas.clipRect(ui.Offset.zero & size);
        for (final polygon in polygons) {
          final projected = projectPolygon(polygon, manager);
          if (projected == null) continue;
          canvas.drawPath(projected.path, ui.Paint()..color = polygon.color);
          if (polygon.borderWidth > 0) {
            canvas.drawPath(
                projected.path,
                ui.Paint()
                  ..color = polygon.borderColor
                  ..style = ui.PaintingStyle.stroke
                  ..strokeWidth = polygon.borderWidth
                  ..strokeJoin = ui.StrokeJoin.round);
          }
        }
        canvas.restore();
      });
      expect(painted, equals(reference));

      // The uncached painter (bounds computed from projected rings) must
      // produce the same pixels as the cached one.
      final direct = await renderToBytes(tester, (canvas, size) {
        PolygonPainter(polygons: polygons, manager: manager).paint(canvas, size);
      });
      expect(direct, equals(painted));
      manager.dispose();
    });
  });
}
