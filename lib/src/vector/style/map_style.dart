/// Layer kinds in a MapLibre style. [unknown] covers types fosm does not
/// render (hillshade, heatmap, …) — they parse fine but draw nothing.
enum StyleLayerType {
  background,
  fill,
  line,
  symbol,
  circle,
  raster,
  fillExtrusion,
  unknown,
}

/// A `sources` entry from the style document, kept close to its raw form;
/// tile-URL resolution happens later in the style loader.
class StyleSource {
  final String name;

  /// `vector`, `raster`, `geojson`, …
  final String type;

  /// TileJSON URL (OpenFreeMap uses this form) — resolved at load time.
  final String? url;

  /// Inline tile URL templates (`{z}/{x}/{y}` placeholders).
  final List<String>? tiles;

  final int? minZoom;
  final int? maxZoom;
  final int tileSize;
  final String? attribution;

  const StyleSource({
    required this.name,
    required this.type,
    this.url,
    this.tiles,
    this.minZoom,
    this.maxZoom,
    this.tileSize = 256,
    this.attribution,
  });
}

/// One renderable layer. Paint/layout values are kept as raw style
/// expressions and evaluated lazily at render time (see `expression.dart`).
class StyleLayer {
  final String id;
  final StyleLayerType type;

  /// `sources` key this layer reads from (null for background layers).
  final String? source;

  /// MVT layer name within the source (`source-layer`).
  final String? sourceLayer;

  final double minZoom;
  final double maxZoom;

  /// Raw filter (legacy array or expression form).
  final dynamic filter;

  final Map<String, dynamic> layout;
  final Map<String, dynamic> paint;

  const StyleLayer({
    required this.id,
    required this.type,
    this.source,
    this.sourceLayer,
    this.minZoom = 0,
    this.maxZoom = 24,
    this.filter,
    this.layout = const {},
    this.paint = const {},
  });

  bool get isVisible => layout['visibility'] != 'none';
}

/// A parsed MapLibre style document.
class MapStyle {
  final String? name;
  final Map<String, StyleSource> sources;
  final List<StyleLayer> layers;

  /// Glyph PBF endpoint (`{fontstack}` / `{range}`) — unused for now:
  /// labels render through Flutter's text stack instead of SDF glyphs.
  final String? glyphs;

  /// Sprite atlas base URL (append `.json` / `.png`, optional `@2x`).
  final String? sprite;

  const MapStyle({
    this.name,
    this.sources = const {},
    this.layers = const [],
    this.glyphs,
    this.sprite,
  });
}
