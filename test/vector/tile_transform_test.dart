import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';
import 'package:fosm/src/vector/style/style_loader.dart';

void main() {
  group('ResolvedTileSource.resolve (over-zoom + wrap)', () {
    const source = ResolvedTileSource(
      name: 'openmaptiles',
      type: 'vector',
      urlTemplate: 'https://t/planet/{z}/{x}/{y}.pbf',
      minZoom: 0,
      maxZoom: 14,
    );

    test('inside range resolves to itself', () {
      expect(source.resolve(10, 539, 372), const TileCoord(10, 539, 372));
    });

    test('above maxzoom resolves to the ancestor at maxzoom', () {
      // z16 tile (6152, 12031) → z14 ancestor (1538, 3007).
      expect(source.resolve(16, 6152, 12031), const TileCoord(14, 1538, 3007));
      // z19 tile (34, 34) → 34 >> 5 = 1 at z14.
      expect(source.resolve(19, 34, 34), const TileCoord(14, 1, 1));
    });

    test('x wraps across the antimeridian', () {
      // 2^3 = 8 columns: x = -1 → 7, x = 8 → 0.
      expect(source.resolve(3, -1, 2).x, 7);
      expect(source.resolve(3, 8, 2).x, 0);
    });

    test('urlFor substitutes the resolved coordinates', () {
      expect(
        source.urlFor(16, 6152, 12031),
        'https://t/planet/14/1538/3007.pbf',
      );
    });
  });

  group('TileTransform (source units → tile pixels)', () {
    test('identity at source zoom with extent 4096', () {
      final t = TileTransform.forLayer(
          z: 10, x: 539, y: 372, srcZ: 10, extent: 4096);
      expect(t.x(0), 0);
      expect(t.x(4096), closeTo(256, 0.001));
      expect(t.y(4096), closeTo(256, 0.001));
    });

    test('quarter-tile offsets at dz = 1', () {
      // z15 children of a z14 tile: each renders half the parent extent.
      // Parent (539, 372)'s children are (1078, ·) left and (1079, ·) right.
      final left = TileTransform.forLayer(
          z: 15, x: 1078, y: 744, srcZ: 14, extent: 4096);
      expect(left.scale, closeTo(256 / 2048, 0.0001));
      expect(left.offsetX, 0);
      expect(left.x(0), 0);
      expect(left.x(2048), closeTo(256, 0.001));
      expect(left.y(0), 0);
      expect(left.y(2048), closeTo(256, 0.001));

      // The right child maps the parent's 2048 mark to its own origin;
      // parent coordinates below that fall off-canvas to the left.
      final right = TileTransform.forLayer(
          z: 15, x: 1079, y: 745, srcZ: 14, extent: 4096);
      expect(right.offsetX, 2048);
      expect(right.x(2048), 0);
      expect(right.x(4096), closeTo(256, 0.001));
      expect(right.x(0), closeTo(-256, 0.001));
    });

    test('non-4096 extents work at dz = 2', () {
      // z12 tile x=4 with z10 parent x=1: relX = 0, 512 of 2048 units per
      // child tile → scale 0.5 px per source unit.
      final t = TileTransform.forLayer(
          z: 12, x: 4, y: 3, srcZ: 10, extent: 2048);
      expect(t.scale, closeTo(0.5, 0.0001));
      expect(t.x(0), 0);
      expect(t.x(512), closeTo(256, 0.001));
    });
  });
}
