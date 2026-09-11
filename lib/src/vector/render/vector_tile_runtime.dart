import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:fosm/src/api/tile.dart' show Tile;
import 'package:fosm/src/api/tile_source.dart'
    show
        TileDecodeAborted,
        TileDecoder,
        TileFetcher,
        TilePayloadException,
        TileResourceKeyBuilder,
        downloadTileBytes;
import 'package:fosm/src/isolate/mvt_isolate.dart'
    if (dart.library.io) 'package:fosm/src/isolate/mvt_isolate_native.dart';
import 'package:fosm/src/isolate/mvt_worker.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/style/map_style.dart' show StyleLayerType;
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/render/label_overlay.dart';
import 'package:fosm/src/vector/render/sprite_atlas.dart';
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';

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

  /// Whether to use the platform's asynchronous parse path: a persistent
  /// worker on native or cooperative chunking on web. Set to `false` in
  /// tests that require fully synchronous parsing.
  final bool parseOffThread;

  VectorTileRuntime({
    required this.loaded,
    required this.namespace,
    this.parseOffThread = true,
  }) {
    _loadSprite();
    // Spawn the persistent MVT decode isolate on native so per-tile
    // `compute()` spawns are avoided. On web [MvtIsolate] is a stub
    // whose spawn() is a no-op and isReady stays false.
    if (parseOffThread) {
      _mvtSpawn = _mvtIsolate.spawn();
    }
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

  // ── Persistent MVT decode isolate ───────────────────────────────────
  final MvtIsolate _mvtIsolate = MvtIsolate();
  Future<void>? _mvtSpawn;

  /// Source layers referenced by this style. Other protobuf layer messages
  /// can be skipped without decoding their features or geometry.
  late final Set<String> _sourceLayers = {
    for (final layer in loaded.style.layers)
      if (layer.isVisible &&
          layer.source == vectorSource.name &&
          layer.sourceLayer != null)
        layer.sourceLayer!,
  };

  /// In-flight parses keyed by the resolved source [TileCoord]. Over-zoom
  /// siblings (e.g. four z15 tiles reading one z14 source tile) share one
  /// parse future instead of starting duplicate decodes before the first
  /// result lands in the parsed-tile LRU.
  final Map<TileCoord, Future<ParsedVectorTile>> _inFlightParses = {};

  SpriteAtlas? sprite;
  Future<void>? _spriteLoading;

  /// The single label overlay for this runtime, created lazily and kept
  /// for the lifetime of the loaded style. Returning a fresh overlay on
  /// every rebuild (the old behaviour) discarded all prepared-label and
  /// `TextPainter` caches on each tile arrival, making label preparation
  /// grow ~quadratically during progressive loading.
  LabelOverlay? _labelOverlay;

  /// The stable label overlay owned by this runtime. Created once and
  /// preserved across tile-arrival rebuilds so cached `TextPainter`s
  /// survive. Disposed in [dispose].
  LabelOverlay get labelOverlay => _labelOverlay ??= LabelOverlay(this);

  /// Optional stale-work predicate set by [TileManager]. When it returns
  /// `false` for a logical tile, an in-progress decode aborts with
  /// [TileDecodeAborted] before the next expensive stage (parse, style
  /// evaluation, vector render, `Picture.toImage`) instead of wasting a
  /// render slot on an off-screen tile.
  bool Function(int z, int x, int y)? isTileRelevant;

  bool _disposed = false;

  /// Number of images disposed because label preparation failed after
  /// `toImage` created them (test hook).
  @visibleForTesting
  int debugDisposedImages = 0;

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

  /// URL builder for [TileManager]'s HTTP isolate. Builds the vector
  /// tile URL with over-zoom applied.
  String Function(int z, int x, int y) get urlBuilder =>
      (z, x, y) => vectorSource.urlFor(z, x, y);

  /// Canonical source identity for [TileManager]: the source name plus the
  /// resolved (over-zoomed, wrapped) coordinate. This keeps persistent keys
  /// opaque — no URL, query string, or token is ever stored.
  TileResourceKeyBuilder get resourceKeyBuilder => (z, x, y) {
        final coord = vectorSource.resolve(z, x, y);
        return '${vectorSource.name}/${coord.z}/${coord.x}/${coord.y}';
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

  /// Whether the logical tile still justifies further work: not disposed
  /// and, when a predicate is installed, still relevant.
  bool _isRelevant(int z, int x, int y) {
    if (_disposed) return false;
    final predicate = isTileRelevant;
    return predicate == null || predicate(z, x, y);
  }

  /// Aborts the current decode when [isTileRelevant] reports the logical
  /// tile is no longer needed. No-op when no predicate is installed.
  void _checkRelevant(int z, int x, int y) {
    if (!_isRelevant(z, x, y)) {
      throw const TileDecodeAborted();
    }
  }

  Future<ui.Image> _decodeAndRender(
      Uint8List bytes, int z, int x, int y) async {
    if (_disposed) throw StateError('runtime disposed');
    _checkRelevant(z, x, y);
    final source = vectorSource;
    try {
      final coord = source.resolve(z, x, y);
      final ParsedVectorTile parsed;
      try {
        parsed =
            _parsedTileFor(coord) ?? await _parseAndStoreDedup(bytes, coord);
      } on TileDecodeAborted {
        rethrow;
      } catch (error) {
        // The protobuf payload itself could not be parsed. Report it as a
        // corrupt payload so the caller invalidates and refetches instead of
        // retrying the same bytes forever.
        throw TilePayloadException('$error');
      }

      // The tile can become stale while waiting for the shared parse.
      _checkRelevant(z, x, y);

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

      // Last relevance gate before the two most expensive stages.
      _checkRelevant(z, x, y);

      // Yield before the heavy Canvas path-building step.
      if (kIsWeb) await Future<void>.delayed(Duration.zero);

      // Use the time-budgeted renderer. It cooperatively yields between
      // layers, features, and large geometry batches on every platform.
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
        // Skip the `toImage` snapshot too if the tile went stale while
        // rendering — it is the single most expensive stage.
        _checkRelevant(z, x, y);
        // Enter a new event-loop turn before toImage. On CanvasKit/SkWasm
        // this snapshot can take 5-15ms; a real timer gives an already
        // scheduled browser/desktop frame a chance to run first.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final image = await picture.toImage(256, 256);
        // Prepare this tile's labels before publishing it, so the next paint
        // only runs viewport collision and drawing instead of feature
        // scanning and text layout. Preparation is cooperative and aborts
        // when the tile goes stale; dispose the image on any failure so it
        // can never leak.
        try {
          await labelOverlay.prepare(
            z,
            x,
            y,
            isRelevant: () => _isRelevant(z, x, y),
          );
        } catch (_) {
          debugDisposedImages++;
          image.dispose();
          rethrow;
        }
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

  /// Deduplicates in-flight parses by resolved source [TileCoord]. When
  /// over-zoom siblings request the same source tile before the first
  /// parse completes, they all share one future (and one decode) instead
  /// of each spawning their own.
  Future<ParsedVectorTile> _parseAndStoreDedup(
      Uint8List bytes, TileCoord coord) {
    final existing = _inFlightParses[coord];
    if (existing != null) return existing;
    final future = _parseAndStore(bytes, coord);
    _inFlightParses[coord] = future;
    // Remove the in-flight entry once it settles so later cache misses
    // (after an LRU eviction) can parse again.
    future.whenComplete(() {
      _inFlightParses.remove(coord);
    });
    return future;
  }

  Future<ParsedVectorTile> _parseAndStore(
      Uint8List bytes, TileCoord coord) async {
    // On native, route through the persistent MVT isolate (one long-lived
    // worker) instead of spawning a fresh `compute()` isolate per tile.
    // On web, or when parseOffThread is false (tests), decode on the
    // current thread.
    final DecodedVectorTile decoded;
    if (parseOffThread) {
      try {
        await _mvtSpawn;
      } catch (_) {
        // A worker startup failure falls back to one-shot compute below.
      }
    }
    if (parseOffThread && _mvtIsolate.isReady) {
      decoded = await _mvtIsolate.decode(
        bytes,
        sourceLayers: _sourceLayers,
      );
    } else {
      decoded = await decodeMvtAsync(
        bytes,
        useIsolate: parseOffThread,
        sourceLayers: _sourceLayers,
      );
    }
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
  Future<void> get spriteReady => _spriteLoading ?? Future<void>.value();

  /// Returns the stable label overlay owned by this runtime.
  ///
  /// Kept for backwards compatibility with callers that expect a factory
  /// method; new code should prefer the [labelOverlay] getter. Either way
  /// the same instance is returned for the lifetime of the runtime, so
  /// prepared labels and `TextPainter`s survive tile-arrival rebuilds.
  LabelOverlay createLabelOverlay() => labelOverlay;

  void dispose() {
    _disposed = true;
    _labelOverlay?.dispose();
    _labelOverlay = null;
    _inFlightUrls.clear();
    _inFlightParses.clear();
    _mvtIsolate.dispose();
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
