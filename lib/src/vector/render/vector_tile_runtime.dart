import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../api/tile.dart' show Tile;
import '../../api/tile_source.dart'
    show TileDecoder, TileFetcher, downloadTileBytes;
import '../mvt/vector_tile.dart';
import '../style/map_style.dart' show StyleLayerType;
import '../style/style_loader.dart';
import 'label_overlay.dart';
import 'sprite_atlas.dart';
import 'vector_tile_renderer.dart';

/// A parsed source tile, shared by every logical tile that over-zooms from
/// it (e.g. four z15 tiles reading one z14 source tile parse it once).
class ParsedVectorTile {
  final DecodedVectorTile decoded;

  /// Zoom of the actual source tile ([decoded]'s coordinates).
  final int srcZ;

  ParsedVectorTile({required this.decoded, required this.srcZ});
}

/// Owns everything stateful for rendering one vector style: parsed-tile
/// LRU, raster-source tiles, sprite atlas, and the fetch/decode closures
/// handed to [TileManager].
class VectorTileRuntime {
  final LoadedVectorStyle loaded;
  final String namespace;

  /// Parse MVT bytes in an isolate (native only — `compute` is a no-op
  /// wrapper on the platform thread on web).
  final bool parseInIsolate;

  VectorTileRuntime({
    required this.loaded,
    required this.namespace,
    this.parseInIsolate = !kIsWeb,
  }) {
    _loadSprite();
  }

  ResolvedTileSource get vectorSource {
    final source = loaded.primaryVectorSource;
    if (source == null) {
      throw StateError('style has no vector source');
    }
    return source;
  }

  // ── Parsed source tiles (LRU, shared across over-zoom siblings) ──────
  static const int maxParsedTiles = 32;
  final LinkedHashMap<String, ParsedVectorTile> _parsedTiles = LinkedHashMap();

  // ── Raster source tiles (for raster layers like natural earth relief) ─
  static const int maxRasterTiles = 24;
  final LinkedHashMap<String, ui.Image> _rasterTiles = LinkedHashMap();

  // ── Network ─────────────────────────────────────────────────────────
  /// In-flight byte fetches by URL — over-zoom siblings share one download.
  final Map<String, Future<Uint8List>> _inFlightUrls = {};

  SpriteAtlas? sprite;
  Future<void>? _spriteLoading;

  bool _disposed = false;

  // ── Decode/render gating ────────────────────────────────────────────
  // Switching to vector mode schedules every visible tile at once; on web
  // the parse runs on the main thread, so doing them back-to-back freezes
  // the UI (and can exhaust CanvasKit's wasm heap). A small worker pool
  // spreads the work across frames.
  //
  // On web only 1 decode at a time — each decode involves heavy CPU work
  // (protobuf parse + Canvas path building + toImage) that already takes
  // a full frame. Running more than one concurrently just piles them up
  // on the event loop and freezes the UI.
  static final int maxConcurrentDecodes = kIsWeb ? 1 : 3;
  int _activeDecodes = 0;
  final Queue<Completer<void>> _decodeWaiters = Queue();

  /// Tile fetcher for [TileManager]: returns raw MVT bytes for a logical
  /// tile, transparently over-zooming to the source's max zoom.
  TileFetcher get fetcher => (z, x, y) async {
        final source = vectorSource;
        return _fetchShared(source.urlFor(z, x, y));
      };

  /// Tile decoder for [TileManager]: parses MVT bytes, caches the parsed
  /// source tile, and rasterizes the logical 256px tile image. Jobs pass
  /// through a small concurrency gate to keep frames responsive.
  TileDecoder get decoder =>
      (bytes, z, x, y) => _gated(() => _decodeAndRender(bytes, z, x, y));

  Future<T> _gated<T>(Future<T> Function() job) async {
    while (_activeDecodes >= maxConcurrentDecodes && !_disposed) {
      final waiter = Completer<void>();
      _decodeWaiters.addLast(waiter);
      await waiter.future;
    }
    _activeDecodes++;
    try {
      if (kIsWeb) {
        // Yield two frames so the browser can paint between decode jobs.
        // One Duration.zero only flushes the microtask queue; a second
        // delay gives the rasterizer a chance to submit the previous frame.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return await job();
    } finally {
      _activeDecodes--;
      _releaseNext();
    }
  }

  void _releaseNext() {
    if (_decodeWaiters.isNotEmpty) {
      _decodeWaiters.removeFirst().complete();
    }
  }

  Future<ui.Image> _decodeAndRender(Uint8List bytes, int z, int x, int y) async {
    if (_disposed) throw StateError('runtime disposed');
    final source = vectorSource;
    try {
      final coord = source.resolve(z, x, y);
      final parsed = _parsedTileFor(coord) ?? await _parseAndStore(bytes, coord);

      // Yield to the event loop between heavy stages so the UI thread
      // can process input and paint. Critical on web where everything
      // runs on the main thread.
      if (kIsWeb) await Future<void>.delayed(Duration.zero);

      // Only fetch raster tiles if there are actually visible raster
      // layers at this zoom. Liberty has one raster layer (natural
      // earth relief) that's only visible at very low zooms — skip
      // the entire loop for the common case.
      final hasVisibleRaster = loaded.style.layers.any((l) =>
          l.type == StyleLayerType.raster &&
          l.isVisible &&
          z >= l.minZoom &&
          z <= l.maxZoom);

      final rasterImages = <String, ui.Image>{};
      final rasterCoords = <String, TileCoord>{};
      if (hasVisibleRaster) {
        for (final layer in loaded.style.layers) {
          if (_disposed) break;
          if (layer.type != StyleLayerType.raster || !layer.isVisible) continue;
          if (z < layer.minZoom || z > layer.maxZoom) continue;
          final sourceName = layer.source;
          if (sourceName == null) continue;
          final rasterSource = loaded.sources[sourceName];
          if (rasterSource == null) continue;

          final rasterCoord = rasterSource.resolve(z, x, y);
          rasterCoords[sourceName] = rasterCoord;
          final image = await _rasterTileFor(rasterSource, rasterCoord);
          if (image != null) rasterImages[sourceName] = image;
        }
      }
      if (_disposed) {
        throw StateError('runtime disposed during decode');
      }

      // Yield before the heavy Canvas path-building step.
      if (kIsWeb) await Future<void>.delayed(Duration.zero);

      // Use the async renderer which yields between layer batches.
      // OpenFreeMap Liberty has ~111 layers (~50-70 visible per zoom);
      // the async renderer chunks them into batches of 8 with frame
      // yields on web, so the browser stays responsive.
      final picture = await VectorTileRenderer(loaded).renderAsync(
        decoded: parsed.decoded,
        srcZ: parsed.srcZ,
        z: z,
        x: x,
        y: y,
        rasterTiles: rasterImages,
        rasterCoords: rasterCoords,
      );
      try {
        // Yield before toImage — on CanvasKit/WASM this is a GPU→CPU
        // readback that can take 5-15ms per tile.
        if (kIsWeb) await Future<void>.delayed(Duration.zero);
        final image = await picture.toImage(256, 256);
        return image;
      } finally {
        picture.dispose();
      }
    } catch (e) {
      rethrow;
    }
  }

  /// The parsed source tile covering a logical tile, or `null` if not
  /// parsed yet. Used by the label overlay to avoid re-parsing.
  ParsedVectorTile? parsedTileFor(int z, int x, int y) {
    try {
      final coord = vectorSource.resolve(z, x, y);
      return _parsedTileFor(coord);
    } catch (_) {
      return null;
    }
  }

  ParsedVectorTile? _parsedTileFor(TileCoord coord) {
    final key = _parsedKey(coord);
    final hit = _parsedTiles.remove(key);
    if (hit != null) {
      _parsedTiles[key] = hit; // refresh LRU
      return hit;
    }
    return null;
  }

  Future<ParsedVectorTile> _parseAndStore(Uint8List bytes, TileCoord coord) async {
    final decoded = parseInIsolate
        ? await compute(decodeVectorTile, bytes)
        : decodeVectorTile(bytes);
    final parsed = ParsedVectorTile(decoded: decoded, srcZ: coord.z);
    if (_disposed) return parsed;

    final key = _parsedKey(coord);
    _parsedTiles
      ..remove(key)
      ..[key] = parsed;
    while (_parsedTiles.length > maxParsedTiles) {
      _parsedTiles.remove(_parsedTiles.keys.first);
    }
    return parsed;
  }

  String _parsedKey(TileCoord coord) => coord.toString();

  Future<Uint8List> _fetchShared(String url) {
    final existing = _inFlightUrls[url];
    if (existing != null) return existing;
    final future = downloadTileBytes(url).whenComplete(() {
      _inFlightUrls.remove(url);
    });
    _inFlightUrls[url] = future;
    return future;
  }

  Future<ui.Image?> _rasterTileFor(
    ResolvedTileSource source,
    TileCoord coord,
  ) async {
    final key = '${source.name}/$coord';
    final hit = _rasterTiles.remove(key);
    if (hit != null) {
      _rasterTiles[key] = hit;
      return hit;
    }
    try {
      final bytes = await _fetchShared(source.urlForCoord(coord));
      final image = await Tile.decodeImage(bytes);
      if (_disposed) {
        image.dispose();
        return null;
      }
      _rasterTiles[key] = image;
      while (_rasterTiles.length > maxRasterTiles) {
        final evicted = _rasterTiles.remove(_rasterTiles.keys.first);
        evicted?.dispose();
      }
      return image;
    } catch (_) {
      return null; // raster layer is decorative — never fail the tile
    }
  }

  Future<void> _loadSprite() async {
    final spriteUrl = loaded.style.sprite;
    if (spriteUrl == null) return;
    _spriteLoading = SpriteAtlas.load(spriteUrl).then((atlas) {
      if (_disposed) {
        atlas?.dispose();
        return;
      }
      sprite = atlas;
    }).catchError((_) {});
  }

  /// Resolves once the sprite attempt (if any) finished — used by tests.
  Future<void> get spriteReady =>
      _spriteLoading ?? Future<void>.value();

  LabelOverlay createLabelOverlay() => LabelOverlay(this);

  void dispose() {
    _disposed = true;
    _inFlightUrls.clear();
    _parsedTiles.clear();
    for (final image in _rasterTiles.values) {
      image.dispose();
    }
    _rasterTiles.clear();
    sprite?.dispose();
    sprite = null;
    // Release queued decodes so their futures complete (and fail fast in
    // the disposed check) instead of hanging forever.
    while (_decodeWaiters.isNotEmpty) {
      _decodeWaiters.removeFirst().complete();
    }
  }
}
