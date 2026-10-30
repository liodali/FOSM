import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:example/benchmark/vector_bench_style.dart';

void main() {
  group('benchStyleJson', () {
    test('variant a is a valid style document over one vector source',
        () {
      final style =
          jsonDecode(benchStyleJson('http://192.168.1.5:8787', variant: 'a'))
              as Map<String, dynamic>;
      expect(style['version'], 8);
      final sources = style['sources'] as Map<String, dynamic>;
      expect(sources.keys, ['bench']);
      final source = sources['bench'] as Map<String, dynamic>;
      expect(source['type'], 'vector');
      expect(source['maxzoom'], benchSourceMaxZoom);
      expect(source['minzoom'], benchSourceMinZoom);
      final tiles = (source['tiles'] as List).cast<String>();
      expect(tiles.single,
          'http://192.168.1.5:8787/tiles/{z}/{x}/{y}.mvt');
    });

    test('layers reference payload source-layers with styled roads', () {
      final style =
          jsonDecode(benchStyleJson('http://127.0.0.1:8787', variant: 'a'))
              as Map<String, dynamic>;
      final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
      final byId = {for (final layer in layers) layer['id']: layer};

      // Every non-background layer must read the bench source and a
      // source-layer the payload generator actually emits.
      const emitted = {'water', 'landuse', 'building', 'transportation',
          'poi'};
      for (final layer in layers) {
        if (layer['type'] == 'background') continue;
        expect(layer['source'], 'bench');
        expect(emitted, contains(layer['source-layer']));
      }

      // Dashed line layers exist (minor + service) and differ.
      expect(byId['road-minor']!['paint']!['line-dasharray'], isA<List>());
      expect(byId['road-service']!['paint']!['line-dasharray'], isA<List>());
      expect(
          (byId['road-minor']!['paint']!['line-dasharray'] as List)
              .length,
          2);

      // Symbol layers provide labels: poi text + road line placement.
      expect(byId['poi-label']!['layout']!['text-field'], 'name');
      expect(byId['road-label']!['layout']!['symbol-placement'], 'line');

      // Zoom-gated layers exist so zoom-dependent work is exercised.
      expect(byId['building']!['minzoom'], 13);
    });

    test('variant b changes the style the switch scenario reloads into',
        () {
      final a = jsonDecode(
          benchStyleJson('http://127.0.0.1:8787', variant: 'a'));
      final b = jsonDecode(
          benchStyleJson('http://127.0.0.1:8787', variant: 'b'));
      expect(a, isNot(equals(b)));
      final layersB =
          ((b as Map)['layers'] as List).cast<Map<String, dynamic>>();
      final idsB = layersB.map((layer) => layer['id']).toSet();
      // Same source and road structure; paints must differ somewhere.
      expect(idsB, containsAll(['road-minor', 'road-major', 'water']));
      final waterA = ((a['layers'] as List).cast<Map<String, dynamic>>()
              .firstWhere((l) => l['id'] == 'water')['paint']
          as Map)['fill-color'];
      final waterB = layersB
          .firstWhere((l) => l['id'] == 'water')['paint']['fill-color'];
      expect(waterB, isNot(equals(waterA)));
    });
  });
}
