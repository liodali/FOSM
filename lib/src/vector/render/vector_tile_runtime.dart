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

  /// Logical `z/x/y` tiles currently awaiting each shared source parse. A
  /// shared parse aborts only when *every* waiter has left the viewport, so
  /// one over-zoom sibling going stale never cancels another's parse.
  final Map<TileCoord, Set<String>> _parseRequesters = {};

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

  /// Optional decode priority supplied by [TileManager]. Higher values are
  /// dispatched first when the presentation lane frees up. Evaluated at
  /// selection time, so a camera change re-ranks already-queued work
  /// (newest generation, then visible before padding, then centre-most).
  int Function(int z, int x, int y)? tilePriority;

  bool _disposed = false;

  /// Number of images disposed because label preparation failed after
  /// `toImage` created them (test hook). Retained for compatibility; base
  /// images are now published before labels, so this stays at zero.
  @visibleForTesting
  int debugDisposedImages = 0;

  /// Fires when a tile's labels finish preparing after its base image was
  /// already published. The label surface listens so label-only updates
  /// repaint without rebuilding the base tiles, markers, or controls.
  final _LabelsNotifier _labelsNotifier = _LabelsNotifier();
  Listenable get labelsNotifier => _labelsNotifier;

  /// Lower-priority, single-lane label-preparation queue. Kept separate from
  /// the vector presentation lane so labels never delay base images.
  final List<_LabelJob> _labelQueue = [];
  final Set<String> _labelQueued = {};
  bool _activeLabelPrep = false;
  Timer? _labelPumpTimer;

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

  /// Test override for [maxConcurrentDecodes] so the demand-aware waiter
  /// queue can be exercised deterministically (tests run with the native
  /// concurrency of 3 otherwise).
  @visibleForTesting
  static int? debugMaxConcurrentDecodesOverride;

  int get _maxConcurrentDecodes =>
      debugMaxConcurrentDecodesOverride ?? maxConcurrentDecodes;

  int _activeDecodes = 0;

  /// Demand-aware decode waiters. When the presentation lane frees up the
  /// highest-priority still-relevant waiter runs next; waiters whose tile
  /// left the viewport are released immediately without touching CPU.
  final List<_DecodeWaiter> _decodeWaiters = [];

  /// Coordinates of tiles whose decode slot was acquired, in order (test
  /// hook for verifying latest-demand ordering).
  @visibleForTesting
  final List<String> debugDecodeOrder = [];

  /// Invoked once a decode slot is acquired, before the job runs. Tests use
  /// it to hold the single lane open deterministically.
  @visibleForTesting
  Future<void> Function(int z, int x, int y)? debugOnDecodeStarted;

  /// Number of tiles currently waiting for a presentation slot (test hook).
  @visibleForTesting
  int get debugWaiterCount => _decodeWaiters.length;

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
  /// through a demand-aware concurrency gate to keep frames responsive.
  TileDecoder get decoder => (bytes, z, x, y) =>
      _gated(z, x, y, () => _decodeAndRender(bytes, z, x, y));

  Future<T> _gated<T>(int z, int x, int y, Future<T> Function() job) async {
    while (_activeDecodes >= _maxConcurrentDecodes && !_disposed) {
      // A tile that scrolled away while queued must not occupy the lane.
      if (!_isRelevant(z, x, y)) throw const TileDecodeAborted();
      _pruneStaleWaiters();
      final waiter = _DecodeWaiter(z, x, y);
      _decodeWaiters.add(waiter);
      await waiter.completer.future;
      // Released by [dispose] or [releaseNext]: if the tile went stale while
      // waiting, drop out before spending any CPU.
      if (!_isRelevant(z, x, y)) throw const TileDecodeAborted();
    }
    if (_disposed) throw const TileDecodeAborted();
    _activeDecodes++;
    if (debugDecodeOrder.length > 4096) debugDecodeOrder.clear();
    debugDecodeOrder.add('$z/$x/$y');
    try {
      await debugOnDecodeStarted?.call(z, x, y);
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

  /// Releases the highest-priority still-relevant waiter, or nothing when
  /// the queue is empty. Stale waiters are completed and discarded first.
  void _releaseNext() {
    _pruneStaleWaiters();
    if (_decodeWaiters.isEmpty) return;
    var best = 0;
    var bestPriority = _decodePriority(_decodeWaiters[0]);
    for (var i = 1; i < _decodeWaiters.length; i++) {
      final priority = _decodePriority(_decodeWaiters[i]);
      if (priority > bestPriority) {
        best = i;
        bestPriority = priority;
      }
    }
    _decodeWaiters.removeAt(best).completer.complete();
  }

  /// Drops waiters whose tile is no longer relevant, releasing their futures
  /// so the callers can unwind without running any presentation work.
  void _pruneStaleWaiters() {
    if (isTileRelevant == null) return;
    _decodeWaiters.removeWhere((waiter) {
      if (_isRelevant(waiter.z, waiter.x, waiter.y)) return false;
      if (!waiter.completer.isCompleted) waiter.completer.complete();
      return true;
    });
  }

  int _decodePriority(_DecodeWaiter waiter) {
    final priority = tilePriority;
    return priority == null ? 0 : priority(waiter.z, waiter.x, waiter.y);
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

  /// Queues label preparation for [z]/[x]/[y] after its base image has been
  /// published. Deduplicated so a tile re-decoded while its labels are still
  /// queued does not prepare twice.
  void _scheduleLabels(int z, int x, int y) {
    if (_disposed) return;
    final key = '$z/$x/$y';
    if (!_labelQueued.add(key)) return;
    _labelQueue.add(_LabelJob(z, x, y, key));
    _pumpLabels();
  }

  void _pumpLabels() {
    if (_disposed ||
        _activeLabelPrep ||
        _labelPumpTimer != null ||
        _labelQueue.isEmpty) {
      return;
    }

    // Labels are intentionally deferred to a later event-loop turn. Calling
    // prepare directly here would execute its synchronous prefix before the
    // decoder can publish the already-created base image.
    _labelPumpTimer = Timer(Duration.zero, () {
      _labelPumpTimer = null;
      if (_disposed || _activeLabelPrep) return;
      _labelQueue.removeWhere((job) {
        final stale = !_isRelevant(job.z, job.x, job.y);
        if (stale) _labelQueued.remove(job.key);
        return stale;
      });
      if (_labelQueue.isEmpty) return;
      _labelQueue
          .sort((a, b) => _labelPriority(b).compareTo(_labelPriority(a)));
      _activeLabelPrep = true;
      unawaited(_runLabelPrep(_labelQueue.removeAt(0)));
    });
  }

  int _labelPriority(_LabelJob job) {
    final priority = tilePriority;
    return priority == null ? 0 : priority(job.z, job.x, job.y);
  }

  Future<void> _runLabelPrep(_LabelJob job) async {
    try {
      await labelOverlay.prepare(
        job.z,
        job.x,
        job.y,
        isRelevant: () => _isRelevant(job.z, job.x, job.y),
      );
      if (_isRelevant(job.z, job.x, job.y)) {
        _labelsNotifier.notifyLabelsUpdated();
      }
    } catch (_) {
      // Stale or failed label preparation: the base image is already
      // published, so these labels are simply skipped.
    } finally {
      _labelQueued.remove(job.key);
      _activeLabelPrep = false;
      if (!_disposed) _pumpLabels();
    }
  }

  /// Bridges the vector pipeline's [VectorTileCancelled] to the package's
  /// [TileDecodeAborted], which [TileManager] treats as a stale (non-failing)
  /// outcome so bytes are retained for a later pan.
  Future<ui.Image> _decodeAndRender(
      Uint8List bytes, int z, int x, int y) async {
    try {
      return await _decodeAndRenderInner(bytes, z, x, y);
    } on VectorTileCancelled {
      throw const TileDecodeAborted();
    }
  }

  Future<ui.Image> _decodeAndRenderInner(
      Uint8List bytes, int z, int x, int y) async {
    if (_disposed) throw StateError('runtime disposed');
    _checkRelevant(z, x, y);
    final source = vectorSource;
    try {
      final coord = source.resolve(z, x, y);
      final ParsedVectorTile parsed;
      try {
        parsed = _parsedTileFor(coord) ??
            await _parseAndStoreDedup(bytes, coord, z, x, y);
      } on TileDecodeAborted {
        rethrow;
      } on VectorTileCancelled {
        // The parser aborted because the camera moved. This is stale work,
        // not a corrupt payload: rethrow so `_decodeAndRender` bridges it to
        // `TileDecodeAborted` and the freshly fetched bytes are retained.
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
        isRelevant: () => _isRelevant(z, x, y),
      );
      try {
        // Skip the `toImage` snapshot too if the tile went stale while
        // rendering — it is the single most expensive stage.
        _checkRelevant(z, x, y);
        // Enter a new event-loop turn before toImage. On CanvasKit/SkWasm
        // this snapshot can take 5-15ms; a real timer gives an already
        // scheduled browser/desktop frame a chance to run first.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        // The tile may have gone stale during the delay; never enter
        // `toImage` (the single most expensive stage) for a stale tile.
        _checkRelevant(z, x, y);
        final image = await picture.toImage(256, 256);
        // Publish the base image immediately. Label preparation runs on a
        // separate lower-priority lane afterwards and notifies only the label
        // surface when it finishes, so visible coverage and zoom readiness
        // never wait for feature scanning and text layout.
        _scheduleLabels(z, x, y);
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
      Uint8List bytes, TileCoord coord, int z, int x, int y) {
    final requester = '$z/$x/$y';
    final existing = _inFlightParses[coord];
    if (existing != null) {
      (_parseRequesters[coord] ??= <String>{}).add(requester);
      return existing;
    }
    _parseRequesters[coord] = <String>{requester};
    final future = _parseAndStore(
      bytes,
      coord,
      isRelevant: () => _anyRequesterRelevant(coord),
    );
    _inFlightParses[coord] = future;
    // Remove the in-flight entry once it settles so later cache misses
    // (after an LRU eviction) can parse again. Use an explicit error handler:
    // `whenComplete()` forwards the error to the returned future, which is
    // unhandled here and would surface as an uncaught async error whenever a
    // shared parse is cancelled.
    unawaited(future.then<void>(
      (_) => _clearParseBookkeeping(coord),
      onError: (Object _, StackTrace __) => _clearParseBookkeeping(coord),
    ));
    return future;
  }

  void _clearParseBookkeeping(TileCoord coord) {
    _inFlightParses.remove(coord);
    _parseRequesters.remove(coord);
  }

  /// True while at least one logical tile waiting on [coord] is still
  /// relevant. A shared parse may only abort when every waiter left the
  /// viewport (or the runtime was disposed).
  bool _anyRequesterRelevant(TileCoord coord) {
    if (_disposed) return false;
    final predicate = isTileRelevant;
    if (predicate == null) return true;
    final requesters = _parseRequesters[coord];
    if (requesters == null || requesters.isEmpty) return true;
    for (final key in requesters) {
      final parts = key.split('/');
      if (parts.length != 3) continue;
      final z = int.tryParse(parts[0]);
      final x = int.tryParse(parts[1]);
      final y = int.tryParse(parts[2]);
      if (z == null || x == null || y == null) continue;
      if (predicate(z, x, y)) return true;
    }
    return false;
  }

  Future<ParsedVectorTile> _parseAndStore(Uint8List bytes, TileCoord coord,
      {bool Function()? isRelevant}) async {
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
        isRelevant: isRelevant,
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
    _labelPumpTimer?.cancel();
    _labelPumpTimer = null;
    _labelQueue.clear();
    _labelQueued.clear();
    _labelsNotifier.dispose();
    _labelOverlay?.dispose();
    _labelOverlay = null;
    _inFlightUrls.clear();
    _inFlightParses.clear();
    _parseRequesters.clear();
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
      final waiter = _decodeWaiters.removeAt(0);
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
  }
}

/// Exposes label-change notifications without leaking `notifyListeners`.
class _LabelsNotifier extends ChangeNotifier {
  void notifyLabelsUpdated() => notifyListeners();
}

/// A tile waiting for the lower-priority label-preparation lane.
class _LabelJob {
  final int z;
  final int x;
  final int y;
  final String key;

  _LabelJob(this.z, this.x, this.y, this.key);
}

/// A logical tile waiting for one of the runtime's presentation slots.
/// Carries its coordinates so priority and relevance can be evaluated when
/// the lane frees up, not when it was queued.
class _DecodeWaiter {
  final int z;
  final int x;
  final int y;
  final Completer<void> completer = Completer<void>();

  _DecodeWaiter(this.z, this.x, this.y);
}
