import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Size, Offset;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../common/cache_tile_mixin.dart';
import '../common/osm_transformation_utilities.dart';
import '../common/utils.dart';
import 'geo_point.dart';
import 'tile.dart';
import 'tile_source.dart';

// ─── Pre-load isolate ────────────────────────────────────────────────────────

/// Manages a long-lived background isolate dedicated to pre-loading tiles.
///
/// The isolate owns its own [HttpClient] so TCP connections are reused across
/// hundreds of tile requests — much cheaper than spawning a fresh isolate per
/// tile via [compute].
///
/// Protocol (main → isolate):  `[SendPort replyPort, int z, int x, int y]`
/// Protocol (isolate → main):  `Uint8List` on success, `String` on error.
class _PreloadIsolate {
  Isolate? _isolate;
  SendPort? _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  bool _ready = false;

  bool get isReady => _ready;

  /// Spawns the background isolate and waits for the handshake.
  Future<void> spawn() async {
    if (_ready) return;

    final completer = Completer<SendPort>();
    _receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _ready = true;
        if (!completer.isCompleted) completer.complete(message);
      }
    });

    await Isolate.spawn(_entryPoint, _receivePort.sendPort);
    await completer.future;
  }

  /// Sends a fetch command and returns the raw PNG bytes.
  /// Throws a [String] error message on failure.
  Future<Uint8List> fetch(int z, int x, int y) {
    final responsePort = ReceivePort();
    _sendPort!.send([responsePort.sendPort, z, x, y]);
    return responsePort.first.then((response) {
      responsePort.close();
      if (response is Uint8List) return response;
      throw response is String ? response : 'Unknown error';
    });
  }

  /// Kills the isolate and cleans up ports.
  void dispose() {
    _ready = false;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort.close();
    _sendPort = null;
  }

  // ── Isolate entry point (runs on the background thread) ─────────────

  static void _entryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    receivePort.listen((message) async {
      final parts = message as List;
      final replyPort = parts[0] as SendPort;
      final z = parts[1] as int;
      final x = parts[2] as int;
      final y = parts[3] as int;

      try {
        replyPort.send(await _fetchOsmTile(client, z, x, y));
      } catch (e) {
        replyPort.send(e.toString());
      }
    });
  }

  /// Fetches a tile from OpenStreetMap using the isolate's persistent
  /// [HttpClient] (keeps TCP connections alive across requests).
  static Future<Uint8List> _fetchOsmTile(
      HttpClient client, int z, int x, int y) async {
    final n = 1 << z;
    final wrappedX = ((x % n) + n) % n;
    final uri = Uri.parse(
        'https://tile.openstreetmap.org/$z/$wrappedX/$y.png');

    final request = await client.getUrl(uri);
    request.headers.set('User-Agent',
        'fosm/0.0.1 (Flutter OSM map; +https://github.com/fosm)');
    request.headers.set('Accept', 'image/png,image/*');

    final response = await request.close();

    if (response.statusCode != 200) {
      response.drain<void>();
      throw 'HTTP ${response.statusCode}';
    }

    final chunks = <List<int>>[];
    await for (final chunk in response) {
      chunks.add(chunk);
    }
    return Uint8List.fromList(chunks.expand((c) => c).toList());
  }
}

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
  static const int maxConcurrentPreloads = 50;

  final TileFetcher _fetcher;

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

  // ── Pre-load isolate ────────────────────────────────────────────────
  final _PreloadIsolate _preloadIsolate = _PreloadIsolate();

  /// Whether to use the persistent isolate for pre-load fetches.
  /// Only enabled when using the default OSM fetcher — custom fetchers
  /// go through the regular async path (which may already use compute).
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
    this.tilePadding = defaultTilePadding,
    this.preloadAdjacentZoom = true,
    this.preloadDebounce = const Duration(milliseconds: 500),
  })  : _fetcher = fetcher ?? osmTileFetcher,
        _usePreloadIsolate = identical(fetcher ?? osmTileFetcher, osmTileFetcher) {
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
    setCenterTile();

    // Spawn the pre-load isolate only for the default OSM fetcher.
    // Custom fetchers use the regular async path (which may already use
    // compute) — the isolate only benefits the built-in OSM pipeline.
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

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;
      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileLatIndex = topRowTilesLatIndex + vIndex;
        final key = tileKey(zoom, tileLngIndex, tileLatIndex);

        // Synchronous memory-cache hit → no flicker.
        final cached = _memoryCache.remove(key);
        if (cached != null) {
          _memoryCache[key] = cached; // refresh LRU
          _renderTiles.add(Tile(cached, key, tileLatIndex, tileLngIndex));
          continue;
        }

        _renderTiles.add(Tile(null, key, tileLatIndex, tileLngIndex));
        _scheduleLoad(key, zoom, tileLngIndex, tileLatIndex);
      }
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
      final image = await Tile.decodeImage(bytes);
      _complete(key, Tile(image, key, y, x));
    } catch (_) {
      _byteCache.remove(key);
      _inFlight.remove(key);
      _loadFromNetwork(key, z, x, y);
    }
  }

  Future<void> _loadFromDisk(String key) async {
    try {
      final tile = await storedTile(key);
      if (tile?.sourceTile != null) {
        _complete(key, tile!);
        return;
      }
      await deleteStoredTile(key);
    } catch (_) {
      try {
        await deleteStoredTile(key);
      } catch (_) {}
    }
    if (_disposed) {
      _inFlight.remove(key);
      return;
    }
    _inFlight.remove(key);
    _scheduleLoad(key, zoom, int.parse(key.split('/')[1]),
        int.parse(key.split('/')[2]));
  }

  Future<void> _loadFromNetwork(String key, int z, int x, int y) async {
    try {
      final bytes = await _fetcher(z, x, y);
      _storeInByteCache(key, bytes);
      final image = await Tile.decodeImage(bytes);
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

  // ── Adjacent zoom pre-loading (debounced, bytes-only, isolate) ──────

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

    // Only preload ±1 and ±2 (±3 would be 64× tiles per visible tile).
    // Priority: closest zoom levels first.
    final zoomDeltas = <int>[];
    for (final dz in [1, -1, 2, -2]) {
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
              final key = tileKey(z, tx, ty);

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

  /// Pre-loads a single tile via the background isolate.
  ///
  /// The isolate handles the HTTP fetch with a persistent [HttpClient],
  /// keeping TCP connections alive across hundreds of requests. Only raw
  /// PNG bytes are returned — no image decoding happens here.
  ///
  /// When a pre-loaded tile later becomes visible, [_scheduleLoad] finds
  /// the bytes in [_byteCache] and decodes them on-demand.
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
        // otherwise fall back to the main-thread fetcher.
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

  static String tileKey(int z, int x, int y) => '$z/$x/$y';
}
