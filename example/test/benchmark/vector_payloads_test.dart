import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';

import 'package:example/benchmark/vector_payloads.dart' hide MvtGeomType;

void main() {
  group('BenchPayloads determinism', () {
    test('same inputs produce byte-identical tiles', () {
      final a = BenchPayloads.tile(14, 8600, 5740);
      final b = BenchPayloads.tile(14, 8600, 5740);
      expect(a, equals(b));
    });

    test('different coordinates and seeds produce different tiles', () {
      final base = BenchPayloads.tile(14, 8600, 5740);
      expect(BenchPayloads.tile(14, 8601, 5740), isNot(equals(base)));
      expect(
        BenchPayloads.tile(14, 8600, 5740, seed: BenchPayloads.defaultSeed + 1),
        isNot(equals(base)),
      );
      expect(
        BenchPayloads.tile(14, 8600, 5740, profile: BenchProfile.suburb),
        isNot(equals(base)),
      );
    });

    test('payload bytes are stable across profile defaults', () {
      // The identity contract: explicit defaults equal implicit ones.
      expect(
        BenchPayloads.tile(10, 512, 340,
            profile: BenchProfile.denseCity, seed: BenchPayloads.defaultSeed),
        equals(BenchPayloads.tile(10, 512, 340)),
      );
    });
  });

  group('BenchPayloads decode with the package decoder', () {
    late Uint8List bytes;
    late DecodedVectorTile decoded;

    setUpAll(() {
      bytes = BenchPayloads.tile(14, 8600, 5740);
      decoded = decodeVectorTile(bytes);
    });

    test('contains every layer the benchmark style references', () {
      final names = decoded.layers.map((layer) => layer.name).toSet();
      expect(names, containsAll(['water', 'landuse', 'building',
          'transportation', 'poi']));
    });

    test('dense city feature counts match the profile', () {
      int count(String name) => decoded.layerByName(name)!.features.length;
      expect(count('water'), 3);
      expect(count('landuse'), 14);
      expect(count('building'), 1400);
      // 46 major + 260 minor + 140 service roads.
      expect(count('transportation'), 446);
      expect(count('poi'), 110);
    });

    test('suburb profile shrinks the dense layers', () {
      final suburb = decodeVectorTile(
          BenchPayloads.tile(14, 8600, 5740, profile: BenchProfile.suburb));
      expect(suburb.layerByName('building')!.features.length, 260);
      expect(suburb.layerByName('transportation')!.features.length,
          14 + 70 + 40);
    });

    test('transportation properties resolve to styled values', () {
      final roads = decoded.layerByName('transportation')!;
      final classes = <String>{};
      var named = 0;
      var ranked = 0;
      for (final feature in roads.features) {
        final roadClass = feature.properties['class'];
        expect(roadClass, isA<String>(),
            reason: 'every road must carry a class the style filters on');
        classes.add(roadClass as String);
        if (feature.properties['name'] is String) named++;
        if (feature.properties['rank'] is int) ranked++;
      }
      // All five styled classes must appear (major/minor/service layers).
      expect(classes, containsAll(['primary', 'secondary', 'trunk', 'minor',
          'service']));
      expect(named, greaterThan(0), reason: 'some roads must be nameable');
      expect(ranked, roads.features.length,
          reason: 'every road carries a rank for data-driven styling');
    });

    test('major roads carry long multi-point geometry', () {
      final roads = decoded.layerByName('transportation')!;
      final majors = roads.features
          .where((f) => ['primary', 'secondary', 'trunk']
              .contains(f.properties['class']))
          .toList();
      expect(majors.length, 46);
      for (final feature in majors) {
        expect(feature.geomType, MvtGeomType.lineString);
        final points = feature.geometry.fold<int>(
            0, (total, part) => total + part.length ~/ 2);
        expect(points, greaterThan(8),
            reason: 'major roads must be multi-segment for dash/metrics work');
      }
    });

    test('buildings and landuse are polygons, pois are points', () {
      for (final feature in decoded.layerByName('building')!.features) {
        expect(feature.geomType, MvtGeomType.polygon);
      }
      for (final feature in decoded.layerByName('landuse')!.features) {
        expect(feature.geomType, MvtGeomType.polygon);
        expect(feature.properties['class'], isA<String>());
      }
      for (final feature in decoded.layerByName('poi')!.features) {
        expect(feature.geomType, MvtGeomType.point);
        expect(feature.properties['name'], isA<String>(),
            reason: 'poi labels resolve text from the name property');
      }
    });
  });
}
