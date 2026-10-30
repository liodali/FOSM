import 'dart:convert';

import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

/// Shared fixture for span/attribution tests: the same minimal style
/// shape the pipeline tests use (red background, blue water fill on the
/// `water` source-layer, one text label layer). All tile URLs point at
/// an invalid host — nothing here touches the network. Pair with
/// `buildTestTile()` from mvt_builder.dart.
LoadedVectorStyle buildLoadedStyle() {
  final style = parseStyleJson(jsonEncode({
    'version': 8,
    'sources': {
      'openmaptiles': {
        'type': 'vector',
        'tiles': ['https://example.invalid/{z}/{x}/{y}.pbf'],
        'maxzoom': 12,
      },
    },
    'layers': [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#ff0000'},
      },
      {
        'id': 'water',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'paint': {'fill-color': '#0000ff'},
      },
      {
        'id': 'water-labels',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'layout': {
          'text-field': ['get', 'class'],
        },
      },
    ],
  }));
  return LoadedVectorStyle(
    style: style,
    sources: const {
      'openmaptiles': ResolvedTileSource(
        name: 'openmaptiles',
        type: 'vector',
        urlTemplate: 'https://example.invalid/{z}/{x}/{y}.pbf',
        maxZoom: 12,
      ),
    },
  );
}
