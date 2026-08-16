import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Size, Offset;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../common/cache_tile_mixin.dart';
import '../common/osm_transformation_utilities.dart';
import '../common/utils.dart';
import 'geo_point.dart';
import '../isolate/preload_isolate.dart'
    if (dart.library.io) '../isolate/preload_isolate_native.dart'
    if (dart.library.js_interop) '../isolate/preload_isolate_web.dart';
import 'tile.dart';
import 'tile_source.dart';

// ─── Tile manager ────────────────────────────────────────────────────────────

/// Manages the visible tile grid, in-memory image cache, and network
/// fetches for an OSM map view.
class TileManager with CacheTiles {
  static const int maxMemoryCachedTiles = 200;
  static const int maxByteCacheBytes = 50 * 1024 * 1024; // 50MB compressed
  static const Duration failureBackoff = Duration(seconds: 5);
  static const int defaultTilePadding = 2;

  /// How long to wait after the user stops panning before pre-loading
  /// adjacent zoom tiles. Prevents flooding the network during active drag.
  /// Set to [Duration.zero] to disable debouncing (useful for tests).
  final Duration preloadDebounce;

  /// Maximum number of concurrent pre-load fetches.
  static const int maxConcurrentPreloads = 20;

  final TileFetcher _fetcher;

  /// Turns fetched bytes into a [ui.Image] — the raster codec by default,
  /// the vector parse+render pipeline in vector mode.
  final TileDecoder _decoder;

  /// Prefix for all cache keys (memory, byte and Hive). Vector styles set
  /// this to the style id so their entries never collide with raster ones.
  final String cacheNamespace;

  // ── Grid geometry ───────────────────────────────────────────────────
  late int horizontalTileCount;
  late int verticalTileCount;
  late int leftColumnTilesLngIndex;
  late int topRowTilesLatIndex;
  late double leftColumnTilesCanvasX;
  late double topRowTilesCanvasY;

  // ── Center ──────────────────────────────────────────────────────────
  double centerTileLng = 0;
  double centerTileLat = 0;
  double centerCanvasX = 0;
  double centerCanvasY = 0;
  double width;
  double height;
  LatLng centerLatLng;
  int zoom;

  // ── Visible slots ───────────────────────────────────────────────────
  final List<Tile> _renderTiles = [];
  List<Tile> get renderTiles => _renderTiles;

  // ── Caches ──────────────────────────────────────────────────────────

  /// Decoded images for visible tiles. LRU via LinkedHashMap.
  final LinkedHashMap<String, ui.Image> _memoryCache = LinkedHashMap();

  /// Compressed PNG bytes for pre-loaded adjacent zoom tiles.
  /// Checked in [_scheduleLoad] for instant decode when a tile becomes visible.
  final LinkedHashMap<String, Uint8List> _byteCache = LinkedHashMap();
  int _byteCacheSize = 0;

  /// Tile keys currently being fetched or decoded.
  final Set<String> _inFlight = {};

  /// Tiles that failed recently; retried only after [failureBackoff].
  final Map<String, DateTime> _failedUntil = {};

  // ── Padding & pre-loading ───────────────────────────────────────────
  final int tilePadding;
  final bool preloadAdjacentZoom;

  /// Debounce timer for adjacent zoom pre-loading.
  Timer? _preloadTimer;

  /// How many pre-load fetches are currently in flight.
  int _activePreloads = 0;

  /// The zoom level that was last pre-loaded for.
  int _lastPreloadedZoom = -1;

  /// The tile coords of the center when pre-loading last ran.
  int _lastPreloadCenterX = 0;
  int _lastPreloadCenterY = 0;

  // ── Pre-load worker ─────────────────────────────────────────────────
  final PreloadIsolateImpl _preloadIsolate = PreloadIsolateImpl();

  /// Whether to use the persistent isolate for pre-load fetches.
  /// Only enabled when using the default OSM fetcher — custom fetchers
  /// go through the regular async path (which may already use compute).
  /// On web, the isolate is a no-op so [isReady] is always false.
  final bool _usePreloadIsolate;

  // ── Lifecycle ───────────────────────────────────────────────────────
  bool _disposed = false;
  int _revision = 0;
  int get revision => _revision;

  VoidCallback? onTilesChanged;

  TileManager.init({
    required this.width,
    required this.height,
    required this.centerLatLng,
    required this.zoom,
    TileFetcher? fetcher,
    TileDecoder? decoder,
    this.cacheNamespace = '',
    this.tilePadding = defaultTilePadding,
    this.preloadAdjacentZoom = true,
    this.preloadDebounce = const Duration(milliseconds: 500),
  })  : _fetcher = fetcher ?? osmTileFetcher,
        _decoder = decoder ?? _decodeRasterTile,
        _usePreloadIsolate =
            identical(fetcher ?? osmTileFetcher, osmTileFetcher) {
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
    setCenterTile();

    // Spawn the pre-load isolate only for the default OSM fetcher.
    // On web, this is a no-op (PreloadIsolateImpl.isReady stays false).
    if (_usePreloadIsolate) {
      _preloadIsolate.spawn();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _preloadTimer?.cancel();
    _preloadTimer = null;
    _preloadIsolate.dispose();
    onTilesChanged = null;
    _renderTiles.clear();
    _inFlight.clear();
    for (final image in _memoryCache.values) {
      image.dispose();
    }
    _memoryCache.clear();
    _byteCache.clear();
    _byteCacheSize = 0;
  }

  // ── Center helpers ──────────────────────────────────────────────────

  void setCenterTile({LatLng? latLng}) {
    if (latLng != null) centerLatLng = latLng;
    final lat = clampLatitude(centerLatLng.latitude);
    final lng = clampLongitude(centerLatLng.longitude);
    centerLatLng = LatLng(latitude: lat, longitude: lng);
    centerTileLng = lon2TileX(lng, zoom);
    centerTileLat = lat2TileY(lat, zoom);
    _clampTileCoords();
  }

  void setCenterFromTileCoords(double tileLng, double tileLat) {
    final n = math.pow(2, zoom).toDouble();
    centerTileLng = tileLng.clamp(0.0, n);
    centerTileLat = tileLat.clamp(0.0, n);
    centerLatLng = LatLng(
      latitude: tileY2Lat(centerTileLat, zoom),
      longitude: tileX2Lng(centerTileLng, zoom),
    );
  }

  void _clampTileCoords() {
    final n = math.pow(2, zoom).toDouble();
    centerTileLng = centerTileLng.clamp(0.0, n);
    centerTileLat = centerTileLat.clamp(0.0, n);
  }

  void resize(Size size) {
    width = size.width;
    height = size.height;
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
  }

  void setZoom(int newZoom) {
    if (newZoom == zoom) return;
    zoom = newZoom;
    setCenterTile();
    calculate();
  }

  void setZoomWithFocalPoint(int newZoom, Offset focalLocal, int oldZoom) {
    if (newZoom == zoom || newZoom == oldZoom) return;

    final focalTileLng =
        centerTileLng + (focalLocal.dx - centerCanvasX) / tileWidth;
    final focalTileLat =
        centerTileLat + (focalLocal.dy - centerCanvasY) / tileHeight;
    final focalLng = tileX2Lng(focalTileLng, oldZoom);
    final focalLat = tileY2Lat(focalTileLat, oldZoom);

    final newFocalTileLng = lon2TileX(focalLng, newZoom);
    final newFocalTileLat = lat2TileY(focalLat, newZoom);

    final newCenterTileLng = newFocalTileLng -
        (focalLocal.dx - centerCanvasX) / tileWidth;
    final newCenterTileLat = newFocalTileLat -
        (focalLocal.dy - centerCanvasY) / tileHeight;

    zoom = newZoom;
    setCenterFromTileCoords(newCenterTileLng, newCenterTileLat);
    calculate();
  }

  // ── Grid computation ────────────────────────────────────────────────

  /// Rebuilds the visible tile grid. Cheap and synchronous — call on
  /// every pan frame.
  void calculate() {
    if (_disposed) return;

    final centerPointTileX = (centerTileLng % 1) * tileWidth;
    final centerPointTileY = (centerTileLat % 1) * tileHeight;

    final centerCanvasTileX = centerCanvasX - centerPointTileX;
    final centerCanvasTileY = centerCanvasY - centerPointTileY;

    final leftColumnsBeforeCenterCount =
        (centerCanvasTileX / tileWidth).ceil();
    leftColumnTilesCanvasX =
        centerCanvasTileX - leftColumnsBeforeCenterCount * tileWidth;

    final topRowsBeforeCenterCount =
        (centerCanvasTileY / tileHeight).ceil();
    topRowTilesCanvasY =
        centerCanvasTileY - topRowsBeforeCenterCount * tileHeight;

    final centerTileLngIndex = centerTileLng.floor();
    leftColumnTilesLngIndex =
        centerTileLngIndex - leftColumnsBeforeCenterCount;

    final centerTileLatIndex = centerTileLat.floor();
    topRowTilesLatIndex =
        centerTileLatIndex - topRowsBeforeCenterCount;

    horizontalTileCount =
        ((width + -leftColumnTilesCanvasX) / tileWidth).ceil();
    verticalTileCount =
        ((height + -topRowTilesCanvasY) / tileHeight).ceil();

    // Expand by [tilePadding] on each side.
    final paddedHCount = horizontalTileCount + 2 * tilePadding;
    final paddedVCount = verticalTileCount + 2 * tilePadding;
    final paddedLeftLng = leftColumnTilesLngIndex - tilePadding;
    final paddedTopLat = topRowTilesLatIndex - tilePadding;
    final paddedLeftCanvasX =
        leftColumnTilesCanvasX - tilePadding * tileWidth;
    final paddedTopCanvasY =
        topRowTilesCanvasY - tilePadding * tileHeight;

    horizontalTileCount = paddedHCount;
    verticalTileCount = paddedVCount;
    leftColumnTilesLngIndex = paddedLeftLng;
    topRowTilesLatIndex = paddedTopLat;
    leftColumnTilesCanvasX = paddedLeftCanvasX;
    topRowTilesCanvasY = paddedTopCanvasY;

    _renderTiles.clear();

    // First pass: build render list and collect tiles that need loading.
    // We sort pending loads center-first so the user sees the middle of
    // the map before the edges — critical for vector mode where each
    // decode is expensive.
    final pending = <({String key, int lng, int lat, double dist})>[];

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;
      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileLatIndex = topRowTilesLatIndex + vIndex;
        final key = _key(zoom, tileLngIndex, tileLatIndex);

        // Synchronous memory-cache hit → no flicker.
        final cached = _memoryCache.remove(key);
        if (cached != null) {
          _memoryCache[key] = cached; // refresh LRU
          _renderTiles.add(Tile(cached, key, tileLatIndex, tileLngIndex));
          continue;
        }

        _renderTiles.add(Tile(null, key, tileLatIndex, tileLngIndex));
        // Squared distance from center (no sqrt needed for ordering).
        final dx = tileLngIndex - centerTileLng;
        final dy = tileLatIndex - centerTileLat;
        pending.add((
          key: key,
          lng: tileLngIndex,
          lat: tileLatIndex,
          dist: dx * dx + dy * dy,
        ));
      }
    }

    // Schedule loads center-first.
    pending.sort((a, b) => a.dist.compareTo(b.dist));
    for (final p in pending) {
      _scheduleLoad(p.key, zoom, p.lng, p.lat);
    }

    _trimMemoryCache();
    _revision++;

    // Debounce adjacent zoom pre-loading — only after user stops panning.
    if (preloadAdjacentZoom) {
      _scheduleAdjacentZoomPreloadDebounced();
    }
  }

  // ── Async tile loading ──────────────────────────────────────────────

  void _scheduleLoad(String key, int z, int x, int y) {
    final n = 1 << z;
    if (y < 0 || y >= n) return;
    if (_inFlight.contains(key)) return;

    final failedUntil = _failedUntil[key];
    if (failedUntil != null && DateTime.now().isBefore(failedUntil)) return;

    // Check byte cache first (instant decode, no network).
    final bytes = _byteCache[key];
    if (bytes != null) {
      _inFlight.add(key);
      _decodeFromByteCache(key, bytes, z, x, y);
      return;
    }

    _inFlight.add(key);

    if (hasStoredTile(key)) {
      _loadFromDisk(key);
    } else {
      _loadFromNetwork(key, z, x, y);
    }
  }

  Future<void> _decodeFromByteCache(
    String key, Uint8List bytes, int z, int x, int y) async {
    try {
      final image = await _decoder(bytes, z, x, y);
      _complete(key, Tile(image, key, y, x));
    } catch (_) {
      _byteCache.remove(key);
      _inFlight.remove(key);
      _loadFromNetwork(key, z, x, y);
    }
  }

  Future<void> _loadFromDisk(String key) async {
    Uint8List? bytes;
    try {
      bytes = await storedTileBytes(key);
    } catch (_) {
      bytes = null;
    }

    if (bytes != null && bytes.isNotEmpty) {
      // Keys may carry a style namespace ("style/z/x/y") — always read
      // the coordinates from the tail.
      final parts = key.split('/');
      final z = int.tryParse(parts[parts.length - 3]);
      final x = int.tryParse(parts[parts.length - 2]);
      final y = int.tryParse(parts[parts.length - 1]);
      if (z != null && x != null && y != null) {
        try {
          final image = await _decoder(bytes, z, x, y);
          _complete(key, Tile(image, key, y, x));
          return;
        } catch (_) {
          await deleteStoredTile(key); // corrupt entry — re-download
        }
      }
    } else {
      try {
        await deleteStoredTile(key);
      } catch (_) {}
    }

    if (_disposed) {
      _inFlight.remove(key);
      return;
    }
    _inFlight.remove(key);
    final parts = key.split('/');
    _scheduleLoad(
      key,
      int.tryParse(parts[parts.length - 3]) ?? zoom,
      int.tryParse(parts[parts.length - 2]) ?? 0,
      int.tryParse(parts[parts.length - 1]) ?? 0,
    );
  }

  Future<void> _loadFromNetwork(String key, int z, int x, int y) async {
    try {
      final bytes = await _fetcher(z, x, y);
      _storeInByteCache(key, bytes);
      final image = await _decoder(bytes, z, x, y);
      unawaited(storeTile(key, Tile(image, key, y, x), bytes));
      _complete(key, Tile(image, key, y, x));
    } catch (_) {
      _inFlight.remove(key);
      _failedUntil[key] = DateTime.now().add(failureBackoff);
    }
  }

  void _complete(String key, Tile tile) {
    _inFlight.remove(key);
    if (_disposed || tile.sourceTile == null) return;

    _memoryCache.remove(key);
    _memoryCache[key] = tile.sourceTile!;
    _trimMemoryCache();

    final i = _renderTiles.indexWhere((t) => t.index == key);
    if (i == -1) return;
    if (_renderTiles[i].sourceTile != null) return;

    _renderTiles[i] = tile;
    _revision++;
    onTilesChanged?.call();
  }

  // ── Adjacent zoom pre-loading (debounced, bytes-only) ───────────────

  /// Schedules adjacent zoom pre-loading with a debounce timer.
  /// Only fires after the user stops panning for [preloadDebounce].
  void _scheduleAdjacentZoomPreloadDebounced() {
    // If debounce is zero, run immediately (useful for tests).
    if (preloadDebounce == Duration.zero) {
      _checkAndPreload();
      return;
    }

    _preloadTimer?.cancel();

    final cx = centerTileLng.floor();
    final cy = centerTileLat.floor();
    if (_lastPreloadedZoom == zoom &&
        _lastPreloadCenterX == cx &&
        _lastPreloadCenterY == cy) {
      return;
    }

    _preloadTimer = Timer(preloadDebounce, () {
      if (!_disposed) _runAdjacentZoomPreload();
    });
  }

  /// Check if center has moved; if so, run preload immediately.
  void _checkAndPreload() {
    final cx = centerTileLng.floor();
    final cy = centerTileLat.floor();
    if (_lastPreloadedZoom == zoom &&
        _lastPreloadCenterX == cx &&
        _lastPreloadCenterY == cy) {
      return;
    }
    _runAdjacentZoomPreload();
  }

  /// Actually runs the pre-loading. Called only after the debounce timer
  /// fires (user has stopped panning).
  void _runAdjacentZoomPreload() {
    if (_disposed) return;

    _lastPreloadedZoom = zoom;
    _lastPreloadCenterX = centerTileLng.floor();
    _lastPreloadCenterY = centerTileLat.floor();

    // Visible area (before padding).
    final visibleLeftLng = leftColumnTilesLngIndex + tilePadding;
    final visibleTopLat = topRowTilesLatIndex + tilePadding;
    final visibleHCount =
        (horizontalTileCount - 2 * tilePadding).clamp(0, 100);
    final visibleVCount =
        (verticalTileCount - 2 * tilePadding).clamp(0, 100);

    // Only preload ±1 zoom (±2 creates 1000+ tiles that compete with
    // visible tile fetches and freeze the UI, especially in vector mode).
    // Priority: closest zoom levels first.
    final zoomDeltas = <int>[];
    for (final dz in [1, -1]) {
      final z = zoom + dz;
      if (z >= 0 && z <= 19) zoomDeltas.add(dz);
    }

    for (final dz in zoomDeltas) {
      final z = zoom + dz;
      // For zoom-in (dz > 0), one tile at current zoom maps to 2^dz × 2^dz tiles at target zoom.
      // For zoom-out (dz < 0), multiple tiles at current zoom map to one tile at target zoom.
      final tileMultiplier = dz > 0 ? (1 << dz) : 1;

      for (var h = 0; h < visibleHCount; h++) {
        for (var v = 0; v < visibleVCount; v++) {
          final lngIndex = visibleLeftLng + h;
          final latIndex = visibleTopLat + v;

          // Map this tile's top-left corner to the target zoom.
          final lng = tileX2Lng(lngIndex.toDouble(), zoom);
          final lat = tileY2Lat(latIndex.toDouble(), zoom);
          final otherX = lon2TileX(lng, z).floor();
          final otherY = lat2TileY(lat, z).floor();

          // Load all tiles that cover this geographic area at target zoom.
          for (var dx = 0; dx < tileMultiplier; dx++) {
              for (var dy = 0; dy < tileMultiplier; dy++) {
                final tx = otherX + dx;
                final ty = otherY + dy;
                final key = _key(z, tx, ty);

              // Skip if already cached or in-flight.
              if (_memoryCache.containsKey(key)) continue;
              if (_byteCache.containsKey(key)) continue;
              if (_inFlight.contains(key)) continue;
              if (ty < 0 || ty >= (1 << z)) continue;

              // Don't exceed concurrent preload limit.
              if (_activePreloads >= maxConcurrentPreloads) return;

              _preloadTile(key, z, tx, ty);
            }
          }
        }
      }
    }
  }

  /// Pre-loads a single tile.
  ///
  /// On native: fetches via the background isolate (persistent HttpClient,
  /// TCP connection reuse). On web: falls back to the regular [_fetcher]
  /// (browser fetch API with automatic connection pooling).
  ///
  /// Only stores compressed PNG bytes — no image decoding. When a pre-loaded
  /// tile becomes visible, [_scheduleLoad] finds the bytes in [_byteCache]
  /// and decodes on-demand.
  void _preloadTile(String key, int z, int x, int y) {
    if (_inFlight.contains(key)) return;
    _inFlight.add(key);
    _activePreloads++;

    () async {
      Uint8List? bytes;
      try {
        // Check Hive disk cache first (synchronous check).
        if (hasStoredTile(key)) {
          final cached = cachedTileBytes(key);
          if (cached != null) {
            bytes = cached;
          }
        }

        // Fetch bytes — via the persistent isolate when available,
        // otherwise fall back to the regular fetcher (which on web
        // uses the browser's fetch API with connection pooling).
        bytes ??= (_usePreloadIsolate && _preloadIsolate.isReady)
            ? await _preloadIsolate.fetch(z, x, y)
            : await _fetcher(z, x, y);
      } catch (_) {
        _inFlight.remove(key);
        _activePreloads--;
        _failedUntil[key] = DateTime.now().add(failureBackoff);
        return;
      }

      // Store compressed bytes (no decode).
      _storeInByteCache(key, bytes);

      // Persist to Hive disk cache (fire and forget).
      unawaited(storeTile(key, Tile(null, key, y, x), bytes));

      _inFlight.remove(key);
      _activePreloads--;

      // If the tile is currently visible, decode it immediately
      // instead of waiting for the next calculate() call.
      final renderIndex = _renderTiles.indexWhere((t) => t.index == key);
      if (renderIndex != -1 &&
          _renderTiles[renderIndex].sourceTile == null) {
        _inFlight.add(key);
        _decodeFromByteCache(key, bytes, z, x, y);
      }
    }();
  }

  // ── Byte cache management ───────────────────────────────────────────

  void _storeInByteCache(String key, Uint8List bytes) {
    final old = _byteCache.remove(key);
    if (old != null) _byteCacheSize -= old.length;

    _byteCache[key] = bytes;
    _byteCacheSize += bytes.length;
    _trimByteCache();
  }

  void _trimByteCache() {
    while (_byteCacheSize > maxByteCacheBytes && _byteCache.isNotEmpty) {
      final oldestKey = _byteCache.keys.first;
      final oldestBytes = _byteCache.remove(oldestKey);
      if (oldestBytes != null) _byteCacheSize -= oldestBytes.length;
    }
  }

  // ── Memory cache management ─────────────────────────────────────────

  void _trimMemoryCache() {
    while (_memoryCache.length > maxMemoryCachedTiles) {
      final oldestKey = _memoryCache.keys.first;
      final image = _memoryCache.remove(oldestKey);
      final visible = _renderTiles.any((t) => t.index == oldestKey);
      if (!visible) image?.dispose();
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  /// Namespaced cache key — `z/x/y` for raster, `style/z/x/y` in vector
  /// mode so entries from different styles coexist in the caches.
  String _key(int z, int x, int y) =>
      cacheNamespace.isEmpty ? '$z/$x/$y' : '$cacheNamespace/$z/$x/$y';

  static String tileKey(int z, int x, int y) => '$z/$x/$y';

  /// Raster default decoder: the bytes are an encoded image.
  static Future<ui.Image> _decodeRasterTile(
    Uint8List bytes,
    int z,
    int x,
    int y,
  ) =>
      Tile.decodeImage(bytes);
}
