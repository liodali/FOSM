import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';

import 'mvt_builder.dart';

void main() {
  group('MVT decoder', () {
    test('decodes layer metadata, tags and geometry kinds', () {
      final tile = decodeVectorTile(buildTestTile());

      expect(tile.layers, hasLength(1));
      final layer = tile.layers.single;
      expect(layer.name, 'water');
      expect(layer.extent, 4096);
      expect(layer.features, hasLength(3));

      // layerByName lookup
      expect(tile.layerByName('water'), same(layer));
      expect(tile.layerByName('nope'), isNull);
    });

    test('resolves tag indexes into properties', () {
      final tile = decodeVectorTile(buildTestTile());
      final polygon = tile.layers.single.features.first;

      expect(polygon.id, 42);
      expect(polygon.geomType, MvtGeomType.polygon);
      expect(polygon.properties, {'class': 'sea', 'rank': 3});
    });

    test('decodes a closed polygon ring', () {
      final tile = decodeVectorTile(buildTestTile());
      final polygon = tile.layers.single.features.first;

      expect(polygon.geometry, hasLength(1));
      final ring = polygon.geometry.single;
      // 4 corners + repeated first point after ClosePath = 5 pairs.
      expect(ring.length, 10);
      expect(ring[0], 0); // x0
      expect(ring[1], 0); // y0
      expect(ring[2], 4096); // x1
      expect(ring[3], 0); // y1
      expect(ring[8], 0); // ClosePath repeats x0
      expect(ring[9], 0);
    });

    test('decodes point and linestring geometry', () {
      final tile = decodeVectorTile(buildTestTile());
      final features = tile.layers.single.features;

      final point = features[1];
      expect(point.geomType, MvtGeomType.point);
      expect(point.geometry.single, Float32List.fromList([100, 200]));

      final line = features[2];
      expect(line.geomType, MvtGeomType.lineString);
      expect(line.geometry.single,
          Float32List.fromList([10, 10, 1000, 10, 1000, 2000]));
    });

    test('decodes a point feature split across two MoveTo pairs', () {
      final builder = MvtBuilder()
        ..addLayer(
          name: 'places',
          features: [
            TestFeature(
              id: 1,
              type: TestGeomType.point,
              geometryCommands: [
                1 | (2 << 3), // MoveTo ×2
                // Deltas are cumulative: (10,20) then (10+30, 20+40).
                zz(10), zz(20), zz(30), zz(40),
              ],
            ),
          ],
        );
      final tile = decodeVectorTile(builder.build());
      final feature = tile.layers.single.features.single;

      expect(feature.geometry, hasLength(2));
      expect(feature.geometry[0], Float32List.fromList([10, 20]));
      expect(feature.geometry[1], Float32List.fromList([40, 60]));
    });

    test('handles non-default extent', () {
      final builder = MvtBuilder()
        ..addLayer(
          name: 'small',
          extent: 256,
          features: [
            TestFeature(
              id: 1,
              type: TestGeomType.point,
              geometryCommands: pointCommands(128, 64),
            ),
          ],
        );
      final tile = decodeVectorTile(builder.build());
      expect(tile.layers.single.extent, 256);
    });

    test('returns empty layers for empty input', () {
      final tile = decodeVectorTile(Uint8List(0));
      expect(tile.layers, isEmpty);
    });

    test('real-world smoke: decoded tile from bytes is self-consistent',
        () {
      // A tile with several layers — ensure unknown layers skip cleanly.
      final builder = MvtBuilder()
        ..addLayer(name: 'boundary', features: const [])
        ..addLayer(
          name: 'water',
          features: [
            TestFeature(
              id: 9,
              type: TestGeomType.polygon,
              geometryCommands: polygonRingCommands(
                const [(0, 0), (2048, 0), (2048, 2048), (0, 2048)],
              ),
            ),
          ],
        );
      final tile = decodeVectorTile(builder.build());
      expect(tile.layers, hasLength(2));
      expect(tile.layerByName('boundary')!.features, isEmpty);
      expect(tile.layerByName('water')!.features, hasLength(1));
    });
  });
}
