// Style documents for the vector-render baseline harness. Two variants
// over the same synthetic source: `a` is the full baseline style; `b`
// differs in paint values and layer set so the style-switch scenario
// exercises a real runtime/style reload with identical payloads.
//
// The source caps at maxzoom 14 so zoom 15+ logical tiles over-zoom from
// z14 source tiles (over-zoom siblings share parses and downloads).

import 'dart:convert';

const int benchSourceMaxZoom = 14;
const int benchSourceMinZoom = 6;

/// Builds the style document served by tool/vector_payload_server.dart.
/// [tilesBase] must include scheme+host+port, e.g. `http://192.168.1.5:8787`.
String benchStyleJson(String tilesBase, {required String variant}) {
  final b = variant == 'b';
  final layers = <Map<String, Object?>>[
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': b ? '#f2efe9' : '#eef2ea'},
    },
    {
      'id': 'water',
      'type': 'fill',
      'source': 'bench',
      'source-layer': 'water',
      'paint': {'fill-color': b ? '#7fb2d9' : '#a5c8e1'},
    },
    {
      'id': 'landuse',
      'type': 'fill',
      'source': 'bench',
      'source-layer': 'landuse',
      'minzoom': 8,
      'paint': {
        'fill-color': [
          'match',
          ['get', 'class'],
          'park',
          b ? '#a9d18e' : '#c3e0ad',
          'residential',
          b ? '#dedad2' : '#e5e0d5',
          '#dcd8cc',
        ],
        'fill-opacity': 0.8,
      },
    },
    {
      'id': 'building',
      'type': 'fill',
      'source': 'bench',
      'source-layer': 'building',
      'minzoom': 13,
      'paint': {
        'fill-color': b ? '#cfc7bd' : '#d9d2c8',
        'fill-opacity': 0.9,
      },
    },
    {
      'id': 'road-service',
      'type': 'line',
      'source': 'bench',
      'source-layer': 'transportation',
      'minzoom': 13,
      'filter': ['==', ['get', 'class'], 'service'],
      'paint': {
        'line-color': '#d0cfc9',
        'line-width': ['interpolate', ['linear'], ['zoom'], 13, 0.5, 16, 1.5],
        'line-dasharray': const [1, 1],
      },
    },
    {
      'id': 'road-minor',
      'type': 'line',
      'source': 'bench',
      'source-layer': 'transportation',
      'minzoom': 11,
      'filter': ['==', ['get', 'class'], 'minor'],
      'paint': {
        'line-color': b ? '#b8b6b0' : '#c6c4bd',
        'line-width': ['interpolate', ['linear'], ['zoom'], 11, 0.6, 16, 2.4],
        'line-dasharray': const [2, 1.5],
      },
    },
    {
      'id': 'road-major',
      'type': 'line',
      'source': 'bench',
      'source-layer': 'transportation',
      'filter': [
        'match',
        ['get', 'class'],
        ['primary', 'secondary', 'trunk'],
        true,
        false,
      ],
      'paint': {
        'line-color': [
          'match',
          ['get', 'class'],
          'primary',
          '#e8a43c',
          'trunk',
          '#dd9d5b',
          b ? '#d9c26a' : '#e3c56b',
        ],
        'line-width': [
          'interpolate',
          ['linear'],
          ['zoom'],
          8,
          0.8,
          11,
          1.8,
          16,
          b ? 3.2 : 4.0,
        ],
      },
    },
    {
      'id': 'poi-label',
      'type': 'symbol',
      'source': 'bench',
      'source-layer': 'poi',
      'minzoom': 14,
      'layout': {
        'text-field': 'name',
        'text-size': ['interpolate', ['linear'], ['zoom'], 14, 10, 16, 12],
      },
      'paint': {
        'text-color': '#3d3d3d',
        'text-halo-color': '#ffffff',
        'text-halo-width': 1.2,
      },
    },
    {
      'id': 'road-label',
      'type': 'symbol',
      'source': 'bench',
      'source-layer': 'transportation',
      'minzoom': 13,
      'filter': ['has', 'name'],
      'layout': {
        'symbol-placement': 'line',
        'text-field': 'name',
        'text-size': 10,
      },
      'paint': {
        'text-color': '#5a5a5a',
        'text-halo-color': '#ffffff',
        'text-halo-width': 1.0,
      },
    },
  ];

  return const JsonEncoder.withIndent('  ').convert({
    'version': 8,
    'name': 'fosm-benchmark-${b ? 'b' : 'a'}',
    'sources': {
      'bench': {
        'type': 'vector',
        'tiles': ['$tilesBase/tiles/{z}/{x}/{y}.mvt'],
        'minzoom': benchSourceMinZoom,
        'maxzoom': benchSourceMaxZoom,
        'attribution': 'Synthetic benchmark payload (fosm example)',
      },
    },
    'layers': layers,
  });
}
