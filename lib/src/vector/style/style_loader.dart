import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fosm/src/api/tile_source.dart'
    show downloadDocument, MapRequestSession;
import 'package:fosm/src/api/map_load_state.dart';
import 'package:fosm/src/common/cache_tile_mixin.dart' show MapDiskCache;
import 'package:fosm/src/vector/style/map_style.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

/// Identifies a hosted vector style the map can render.
///
/// [id] namespaces every cache entry (memory, byte and Hive) so tiles from
/// different styles never collide. Instances compare by value so [MapView]
/// can skip reloading when an unchanged style is passed on rebuild.
class VectorMapStyle {
  final String id;
  final String styleUrl;

  const VectorMapStyle({required this.id, required this.styleUrl});

  @override
  bool operator ==(Object other) =>
      other is VectorMapStyle && other.id == id && other.styleUrl == styleUrl;

  @override
  int get hashCode => Object.hash(id, styleUrl);

  @override
  String toString() => 'VectorMapStyle($id, $styleUrl)';
}

/// The OpenFreeMap "Liberty" style — free, no API key, OpenMapTiles schema.
/// See https://openfreemap.org.
const VectorMapStyle openFreeMapLiberty = VectorMapStyle(
  id: 'openfreemap-liberty',
  styleUrl: 'https://tiles.openfreemap.org/styles/liberty',
);

/// Integer tile coordinate.
class TileCoord {
  final int z;
  final int x;
  final int y;

  const TileCoord(this.z, this.x, this.y);

  @override
  bool operator ==(Object other) =>
      other is TileCoord && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

/// A style source with its tile URL template resolved (from inline
/// `tiles` or a fetched TileJSON document).
class ResolvedTileSource {
  final String name;
  final String type; // 'vector' | 'raster'
  final String urlTemplate;
  final int minZoom;
  final int maxZoom;
  final String? attribution;

  const ResolvedTileSource({
    required this.name,
    required this.type,
    required this.urlTemplate,
    this.minZoom = 0,
    this.maxZoom = 22,
    this.attribution,
  });

  /// Maps a *logical* tile request to the source tile that contains it,
  /// applying over-zoom (z above [maxZoom] reads the ancestor tile at
  /// maxZoom) and antimeridian x-wrapping.
  TileCoord resolve(int z, int x, int y) {
    final clampedZ = z.clamp(minZoom, maxZoom);
    final dz = z - clampedZ;
    int sx, sy;
    if (dz >= 0) {
      sx = x >> dz;
      sy = y >> dz;
    } else {
      final scale = 1 << -dz;
      sx = x * scale;
      sy = y * scale;
    }
    final n = 1 << clampedZ;
    final wrappedX = ((sx % n) + n) % n;
    return TileCoord(clampedZ, wrappedX, sy);
  }

  String urlFor(int z, int x, int y) => urlForCoord(resolve(z, x, y));

  String urlForCoord(TileCoord coord) => urlTemplate
      .replaceAll('{z}', '${coord.z}')
      .replaceAll('{x}', '${coord.x}')
      .replaceAll('{y}', '${coord.y}');
}

/// A style document plus its sources resolved to concrete tile URLs.
class LoadedVectorStyle {
  final MapStyle style;
  final Map<String, ResolvedTileSource> sources;

  /// Plain-text attribution (HTML tags stripped) required by the providers.
  final String attribution;

  const LoadedVectorStyle({
    required this.style,
    required this.sources,
    this.attribution = '',
  });

  /// The vector source geometry layers read from. v1 assumes a single
  /// vector source (Liberty has exactly one: `openmaptiles`).
  ResolvedTileSource? get primaryVectorSource {
    for (final layer in style.layers) {
      final source = layer.source;
      if (source != null && sources[source]?.type == 'vector') {
        return sources[source];
      }
    }
    for (final source in sources.values) {
      if (source.type == 'vector') return source;
    }
    return null;
  }
}

/// Fetches the style document, then resolves every source (fetching
/// TileJSON documents as needed). Throws on network/parse failure — the
/// caller decides how to surface that.
///
/// Documents come from the persistent cache while their server says they are
/// still fresh (`Cache-Control: max-age`), skipping the request round trips
/// that otherwise precede the first tile; a stale cached copy is the fallback
/// when the network fails. TileJSON documents are fetched concurrently.
///
/// [onSourceUrl] receives the first source's TileJSON or tile URL as soon as the
/// style names it, before the TileJSON documents are fetched.
Future<LoadedVectorStyle> loadVectorStyle(
  VectorMapStyle vectorStyle, {
  Duration requestTimeout = TileLoadException.defaultRequestTimeout,
  MapRequestSession? requestSession,
  void Function(String url)? onSourceUrl,
}) async {
  final documents = _DocumentLoader(
    requestTimeout: requestTimeout,
    requestSession: requestSession,
  );
  try {
    return await _loadVectorStyle(vectorStyle, documents, onSourceUrl);
  } catch (error) {
    if (!documents.servedFromCache ||
        (error is TileLoadException &&
            error.kind == TileFailureKind.cancelled)) {
      rethrow;
    }
    // A cached document that no longer parses must not wedge the style until
    // it expires: drop what the cache served and load once from the network.
    await documents.discardServed();
    return _loadVectorStyle(
      vectorStyle,
      _DocumentLoader(
        requestTimeout: requestTimeout,
        requestSession: requestSession,
        readCache: false,
      ),
      onSourceUrl,
    );
  }
}

/// Loads one provider document: fresh cache copy, else the network (storing
/// the result), else a stale cache copy when the network failed.
class _DocumentLoader {
  _DocumentLoader({
    required this.requestTimeout,
    required this.requestSession,
    this.readCache = true,
  });

  final Duration requestTimeout;
  final MapRequestSession? requestSession;

  /// Whether cached copies may answer. A retry after a bad copy turns this
  /// off but still writes what it fetched.
  final bool readCache;
  final Set<String> _served = {};

  bool get servedFromCache => _served.isNotEmpty;

  Future<Uint8List> load(String url) async {
    final cached = readCache ? MapDiskCache.readDocument(url) : null;
    if (cached != null && cached.isFresh(DateTime.now())) {
      _served.add(url);
      return cached.bytes;
    }
    try {
      final fetched = await downloadDocument(
        url,
        requestTimeout: requestTimeout,
        requestSession: requestSession,
      );
      unawaited(
        MapDiskCache.storeDocument(
          url,
          fetched.bytes,
          freshFor: fetched.freshFor,
        ).catchError((Object _) {}),
      );
      return fetched.bytes;
    } on TileLoadException catch (error) {
      if (cached != null && error.kind != TileFailureKind.cancelled) {
        _served.add(url);
        return cached.bytes;
      }
      rethrow;
    }
  }

  Future<void> discardServed() async {
    for (final url in _served) {
      await MapDiskCache.deleteDocument(url);
    }
    _served.clear();
  }
}

Future<LoadedVectorStyle> _loadVectorStyle(
  VectorMapStyle vectorStyle,
  _DocumentLoader documents,
  void Function(String url)? onSourceUrl,
) async {
  final style = parseStyleJson(
    utf8.decode(await documents.load(vectorStyle.styleUrl)),
  );

  // Every TileJSON document is requested at once; the sources then resolve in
  // style order below.
  final tileJsonUrls = <String, String>{
    for (final entry in style.sources.entries)
      if ((entry.value.tiles ?? const <String>[]).isEmpty &&
          entry.value.url != null)
        entry.key: entry.value.url!,
  };
  if (onSourceUrl != null) {
    // The style names where its tiles live before the TileJSON answers: tell
    // the caller now so it can connect while the documents download.
    for (final source in style.sources.values) {
      final url = (source.tiles ?? const <String>[]).firstOrNull ?? source.url;
      if (url != null) {
        onSourceUrl(url);
        break;
      }
    }
  }
  final tileJsonBytes = await Future.wait([
    for (final url in tileJsonUrls.values) documents.load(url),
  ]);
  final tileJsonByName = <String, Uint8List>{
    for (final (index, name) in tileJsonUrls.keys.indexed)
      name: tileJsonBytes[index],
  };

  final resolved = <String, ResolvedTileSource>{};
  final attributions = <String>[];

  for (final entry in style.sources.entries) {
    final source = entry.value;
    var templates = source.tiles ?? const <String>[];
    var minZoom = source.minZoom ?? 0;
    var maxZoom = source.maxZoom ?? 22;
    var attribution = source.attribution;

    final tileJsonDocument = tileJsonByName[entry.key];
    if (templates.isEmpty && tileJsonDocument != null) {
      final tileJson = jsonDecode(utf8.decode(tileJsonDocument));
      if (tileJson is Map) {
        final tiles = tileJson['tiles'];
        if (tiles is List) {
          templates = tiles.whereType<String>().toList(growable: false);
        }
        minZoom = tileJson['minzoom'] is num
            ? (tileJson['minzoom'] as num).toInt()
            : minZoom;
        maxZoom = tileJson['maxzoom'] is num
            ? (tileJson['maxzoom'] as num).toInt()
            : maxZoom;
        attribution ??= tileJson['attribution'] is String
            ? tileJson['attribution'] as String
            : null;
      }
    }

    if (templates.isEmpty) continue;

    if (attribution != null) {
      final stripped = _stripHtml(attribution).trim();
      if (stripped.isNotEmpty) attributions.add(stripped);
    }

    resolved[entry.key] = ResolvedTileSource(
      name: entry.key,
      type: source.type,
      urlTemplate: templates.first,
      minZoom: minZoom.clamp(0, 22),
      maxZoom: maxZoom.clamp(0, 22),
      attribution: attribution,
    );
  }

  if (resolved.values.every((s) => s.type != 'vector')) {
    throw const FormatException('style has no vector source');
  }

  return LoadedVectorStyle(
    style: style,
    sources: resolved,
    attribution: attributions.join(' '),
  );
}

String _stripHtml(String html) =>
    html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ');
