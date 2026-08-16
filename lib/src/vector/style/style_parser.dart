import 'dart:convert';

import 'map_style.dart';

/// Parses a MapLibre style JSON document. Tolerant by design: unknown
/// properties are ignored, missing ones fall back to spec defaults, and a
/// malformed layer is skipped rather than failing the whole style.
MapStyle parseStyleJson(String json) {
  final Map<String, dynamic> root;
  try {
    root = jsonDecode(json) as Map<String, dynamic>;
  } on FormatException {
    throw const FormatException('style document is not valid JSON');
  }

  final sources = <String, StyleSource>{};
  final sourcesJson = root['sources'];
  if (sourcesJson is Map) {
    for (final entry in sourcesJson.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final source = _parseSource(entry.key.toString(), value);
      if (source != null) sources[entry.key.toString()] = source;
    }
  }

  final layers = <StyleLayer>[];
  final layersJson = root['layers'];
  if (layersJson is List) {
    for (final layerJson in layersJson) {
      if (layerJson is! Map) continue;
      final layer = _parseLayer(layerJson);
      if (layer != null) layers.add(layer);
    }
  }

  return MapStyle(
    name: root['name'] is String ? root['name'] as String : null,
    sources: sources,
    layers: layers,
    glyphs: root['glyphs'] is String ? root['glyphs'] as String : null,
    sprite: root['sprite'] is String ? root['sprite'] as String : null,
  );
}

StyleSource? _parseSource(String name, Map json) {
  final type = json['type'];
  if (type is! String) return null;

  final tilesJson = json['tiles'];
  return StyleSource(
    name: name,
    type: type,
    url: json['url'] is String ? json['url'] as String : null,
    tiles: tilesJson is List
        ? tilesJson.whereType<String>().toList(growable: false)
        : null,
    minZoom: json['minzoom'] is num ? (json['minzoom'] as num).toInt() : null,
    maxZoom: json['maxzoom'] is num ? (json['maxzoom'] as num).toInt() : null,
    tileSize: json['tileSize'] is num ? (json['tileSize'] as num).toInt() : 256,
    attribution:
        json['attribution'] is String ? json['attribution'] as String : null,
  );
}

StyleLayer? _parseLayer(Map json) {
  final id = json['id'];
  final type = json['type'];
  if (id is! String || type is! String) return null;

  return StyleLayer(
    id: id,
    type: switch (type) {
      'background' => StyleLayerType.background,
      'fill' => StyleLayerType.fill,
      'line' => StyleLayerType.line,
      'symbol' => StyleLayerType.symbol,
      'circle' => StyleLayerType.circle,
      'raster' => StyleLayerType.raster,
      'fill-extrusion' => StyleLayerType.fillExtrusion,
      _ => StyleLayerType.unknown,
    },
    source: json['source'] is String ? json['source'] as String : null,
    sourceLayer:
        json['source-layer'] is String ? json['source-layer'] as String : null,
    minZoom: json['minzoom'] is num
        ? (json['minzoom'] as num).toDouble()
        : 0.0,
    maxZoom: json['maxzoom'] is num
        ? (json['maxzoom'] as num).toDouble()
        : 24.0,
    filter: json['filter'],
    layout: json['layout'] is Map
        ? Map<String, dynamic>.from(json['layout'] as Map)
        : const {},
    paint: json['paint'] is Map
        ? Map<String, dynamic>.from(json['paint'] as Map)
        : const {},
  );
}
