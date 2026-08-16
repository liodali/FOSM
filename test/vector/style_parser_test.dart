import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/style/map_style.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

void main() {
  test('parses sources, layers, glyphs and sprite', () {
    final style = parseStyleJson(jsonEncode({
      'version': 8,
      'name': 'liberty-ish',
      'glyphs': 'https://example.com/fonts/{fontstack}/{range}.pbf',
      'sprite': 'https://example.com/sprites/basic',
      'sources': {
        'openmaptiles': {
          'type': 'vector',
          'url': 'https://example.com/tilejson.json',
        },
        'ne2': {
          'type': 'raster',
          'tiles': ['https://example.com/ne2/{z}/{x}/{y}.png'],
          'maxzoom': 6,
        },
      },
      'layers': [
        {
          'id': 'background',
          'type': 'background',
          'paint': {'background-color': '#f0eee8'},
        },
        {
          'id': 'water',
          'type': 'fill',
          'source': 'openmaptiles',
          'source-layer': 'water',
          'minzoom': 0,
          'maxzoom': 24,
          'filter': ['==', ['get', 'class'], 'ocean'],
          'paint': {
            'fill-color': [
              'interpolate', ['linear'], ['zoom'],
              0, '#aaa', 8, '#888',
            ],
          },
        },
        {
          'id': 'hidden',
          'type': 'line',
          'source': 'openmaptiles',
          'source-layer': 'road',
          'layout': {'visibility': 'none'},
        },
        {'id': 'future', 'type': 'hillshade', 'source': 'terrain'},
      ],
    }));

    expect(style.name, 'liberty-ish');
    expect(style.glyphs, contains('{fontstack}'));
    expect(style.sprite, isNotNull);

    expect(style.sources, hasLength(2));
    expect(style.sources['openmaptiles']!.type, 'vector');
    expect(style.sources['openmaptiles']!.url, contains('tilejson'));
    expect(style.sources['ne2']!.tiles!.single, contains('{z}'));
    expect(style.sources['ne2']!.maxZoom, 6);

    expect(style.layers, hasLength(4));
    expect(style.layers[0].type, StyleLayerType.background);
    expect(style.layers[1].type, StyleLayerType.fill);
    expect(style.layers[1].sourceLayer, 'water');
    expect(style.layers[1].isVisible, isTrue);
    expect(style.layers[2].isVisible, isFalse); // visibility: none
    expect(style.layers[3].type, StyleLayerType.unknown); // tolerated
  });

  test('defaults: minzoom 0, maxzoom 24, empty paint/layout', () {
    final style = parseStyleJson(jsonEncode({
      'sources': {'v': {'type': 'vector', 'url': 'https://x/y.json'}},
      'layers': [
        {'id': 'l', 'type': 'fill', 'source': 'v'},
      ],
    }));
    final layer = style.layers.single;
    expect(layer.minZoom, 0);
    expect(layer.maxZoom, 24);
    expect(layer.paint, isEmpty);
    expect(layer.layout, isEmpty);
    expect(layer.isVisible, isTrue);
  });

  test('invalid JSON throws FormatException', () {
    expect(() => parseStyleJson('not json'), throwsFormatException);
  });

  test('layers missing id or type are skipped, not fatal', () {
    final style = parseStyleJson(jsonEncode({
      'sources': {},
      'layers': [
        {'type': 'fill'},
        {'id': 'ok', 'type': 'circle', 'source': 'v'},
      ],
    }));
    expect(style.layers, hasLength(1));
    expect(style.layers.single.id, 'ok');
  });
}
