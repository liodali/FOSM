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
import 'tile.dart';
import 'tile_source.dart';

/// Manages the visible tile grid, in-memory image cache, and network
/// fetches for an OSM map view.
///
/// ### Key design decisions
///
/// - **One [Tile] per visible cell** — the old code added 1024 duplicate
///   placeholders per cell (a JS checkerboard loop ported verbatim). Now
///   the list contains exactly `horizontalTileCount × verticalTileCount`
///   entries, ordered row-major (h outer, v inner).
///
/// - **In-memory LRU cache** ([_memoryCache]) keeps decoded [ui.Image]s
///   across pan updates. Dragging no longer re-downloads or re-decodes
///   tiles every frame — it just reads from the cache.
///
/// - **Pending set** ([_inFlight]) deduplicates fetches so rapid panning
///   can't spawn dozens of parallel requests for the same tile.
///
/// - **Backoff** ([_failedUntil]) prevents hammering the server when a
///   tile 404s or the network is flaky.
///
/// - **Revision counter** ([revision]) lets the painter cheaply decide
///   whether to repaint without comparing tile images by reference.
///
/// - **Race-safe async completion**: when a fetch resolves, we re-lookup
///   the slot by its key instead of trusting a stale list index. If the
///   tile is no longer visible the image is still stored in the memory
///   cache for next time.
class TileManager with CacheTiles {
  static const int maxMemoryCachedTiles = 300;
  static const Duration failureBackoff = Duration(seconds: 5);
  static const int defaultTilePadding = 2;

  /// Injectable tile fetcher. Defaults to [osmTileFetcher].
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

  /// One [Tile] per visible cell, row-major (h outer, v inner).
  List<Tile> get renderTiles => _renderTiles;

  // ── Caches ──────────────────────────────────────────────────────────

  /// Decoded images kept across pans. [LinkedHashMap] iteration order is
  /// insertion order, so removing + re-inserting on access gives us LRU
  /// eviction with O(1) bookkeeping.
  final LinkedHashMap<String, ui.Image> _memoryCache = LinkedHashMap();

  /// Tile keys currently being fetched or decoded.
  final Set<String> _inFlight = {};

  /// Tiles that failed recently; retried only after [failureBackoff].
  final Map<String, DateTime> _failedUntil = {};

  // ── Padding & pre-loading ───────────────────────────────────────────
  
  /// Number of extra tiles to load beyond the visible viewport on each side.
  /// This makes panning feel instant — tiles are already decoded in memory.
  final int tilePadding;
  
  /// Whether to pre-load tiles at adjacent zoom levels (z±1).
  /// This makes zooming in/out feel smooth.
  final bool preloadAdjacentZoom;

  // ── Lifecycle ───────────────────────────────────────────────────────
  bool _disposed = false;
  int _revision = 0;

  /// Bumped every time the visible grid or any tile image changes.
  /// The painter reads this for [shouldRepaint].
  int get revision => _revision;

  /// Called (on the UI thread) whenever a visible tile receives its
  /// image, so the owning widget can [setState].
  VoidCallback? onTilesChanged;

  TileManager.init({
    required this.width,
    required this.height,
    required this.centerLatLng,
    required this.zoom,
    TileFetcher? fetcher,
    this.tilePadding = defaultTilePadding,
    this.preloadAdjacentZoom = true,
  }) : _fetcher = fetcher ?? osmTileFetcher {
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
    setCenterTile();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onTilesChanged = null;
    _renderTiles.clear();
    _inFlight.clear();
    for (final image in _memoryCache.values) {
      image.dispose();
    }
    _memoryCache.clear();
  }

  // ── Center helpers ──────────────────────────────────────────────────

  /// Updates the center from a [LatLng], clamping to the Mercator-valid
  /// range. Call this when the user sets the center programmatically.
  void setCenterTile({LatLng? latLng}) {
    if (latLng != null) centerLatLng = latLng;
    final lat = clampLatitude(centerLatLng.latitude);
    final lng = clampLongitude(centerLatLng.longitude);
    centerLatLng = LatLng(latitude: lat, longitude: lng);
    centerTileLng = lon2TileX(lng, zoom);
    centerTileLat = lat2TileY(lat, zoom);
    _clampTileCoords();
  }

  /// Updates the center from raw tile coordinates (used during panning).
  /// The values are clamped to the Mercator-valid world rectangle.
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

  /// Updates the viewport size (e.g. after rotation). Triggers a full
  /// recalculate on the next [calculate] call.
  void resize(Size size) {
    width = size.width;
    height = size.height;
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
  }

  /// Changes the zoom level and recalculates the grid.
  /// The center geographic point is preserved.
  void setZoom(int newZoom) {
    if (newZoom == zoom) return;
    zoom = newZoom;
    setCenterTile(); // recompute centerTileLng/Lat at new zoom
    calculate();
  }

  /// Changes the zoom level while keeping a specific screen point stationary.
  /// Used during pinch-to-zoom so the geographic point under the fingers
  /// stays under the fingers.
  ///
  /// [focalLocal] is the screen position (in local widget coordinates) that
  /// should remain stationary. [oldZoom] is the zoom level before the change.
  void setZoomWithFocalPoint(int newZoom, Offset focalLocal, int oldZoom) {
    if (newZoom == zoom || newZoom == oldZoom) return;
    
    // Geographic point under the focal point at the old zoom
    final focalTileLng = centerTileLng + (focalLocal.dx - centerCanvasX) / tileWidth;
    final focalTileLat = centerTileLat + (focalLocal.dy - centerCanvasY) / tileHeight;
    final focalLng = tileX2Lng(focalTileLng, oldZoom);
    final focalLat = tileY2Lat(focalTileLat, oldZoom);
    
    // At the new zoom, where is this geographic point in tile coords?
    final newFocalTileLng = lon2TileX(focalLng, newZoom);
    final newFocalTileLat = lat2TileY(focalLat, newZoom);
    
    // New center: focal point stays at focalLocal on screen
    final newCenterTileLng = newFocalTileLng - (focalLocal.dx - centerCanvasX) / tileWidth;
    final newCenterTileLat = newFocalTileLat - (focalLocal.dy - centerCanvasY) / tileHeight;
    
    zoom = newZoom;
    setCenterFromTileCoords(newCenterTileLng, newCenterTileLat);
    calculate();
  }

  // ── Grid computation ────────────────────────────────────────────────

  /// Rebuilds the visible tile grid around the current center and
  /// schedules async loads for any missing tiles.
  ///
  /// This method is **synchronous and cheap** — the grid math is a few
  /// dozen integer operations, and cache hits are O(1) map lookups.
  /// Call it on every pan frame without worry.
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

    // Expand the grid by [tilePadding] tiles on each side for pre-loading.
    // The painter will draw the expanded grid, but tiles outside the viewport
    // are clipped by the canvas bounds. This makes panning feel instant.
    final paddedHCount = horizontalTileCount + 2 * tilePadding;
    final paddedVCount = verticalTileCount + 2 * tilePadding;
    final paddedLeftLng = leftColumnTilesLngIndex - tilePadding;
    final paddedTopLat = topRowTilesLatIndex - tilePadding;
    final paddedLeftCanvasX = leftColumnTilesCanvasX - tilePadding * tileWidth;
    final paddedTopCanvasY = topRowTilesCanvasY - tilePadding * tileHeight;

    // Update the exported geometry to the padded grid.
    // The painter uses these values, so it will draw the expanded grid.
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

        // Synchronous memory-cache hit → no flicker, no fetch.
        final cached = _memoryCache.remove(key);
        if (cached != null) {
          _memoryCache[key] = cached; // refresh LRU position
          _renderTiles.add(Tile(cached, key, tileLatIndex, tileLngIndex));
          continue;
        }

        // Placeholder — will be replaced when the async load completes.
        _renderTiles.add(Tile(null, key, tileLatIndex, tileLngIndex));
        _scheduleLoad(key, zoom, tileLngIndex, tileLatIndex);
      }
    }

    _trimMemoryCache();
    _revision++;
    
    // Pre-load tiles at adjacent zoom levels (z±1) for smooth zooming.
    if (preloadAdjacentZoom) {
      _scheduleAdjacentZoomPreload();
    }
  }

  // ── Async tile loading ──────────────────────────────────────────────

  void _scheduleLoad(String key, int z, int x, int y) {
    final n = 1 << z;
    // Outside the Mercator world (poles) → leave as placeholder.
    if (y < 0 || y >= n) return;

    // Already fetching — deduplicate.
    if (_inFlight.contains(key)) return;

    // Backoff: skip tiles that failed recently.
    final failedUntil = _failedUntil[key];
    if (failedUntil != null && DateTime.now().isBefore(failedUntil)) return;

    _inFlight.add(key);

    if (hasStoredTile(key)) {
      _loadFromDisk(key);
    } else {
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
      // Corrupt entry → remove and fall through to network.
      await deleteStoredTile(key);
    } catch (_) {
      // Hive / decode error → drop the entry.
      try {
        await deleteStoredTile(key);
      } catch (_) {}
    }
    // Fall through to network load.
    if (_disposed) {
      _inFlight.remove(key);
      return;
    }
    _inFlight.remove(key); // remove so _scheduleLoad re-enqueues
    _scheduleLoad(key, zoom,
        int.parse(key.split('/')[1]), int.parse(key.split('/')[2]));
  }

  Future<void> _loadFromNetwork(String key, int z, int x, int y) async {
    try {
      final bytes = await _fetcher(z, x, y);
      final image = await Tile.decodeImage(bytes);
      // Best-effort persistence — don't block the paint path on Hive I/O.
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

    // Insert / refresh in memory cache (LRU).
    _memoryCache.remove(key);
    _memoryCache[key] = tile.sourceTile!;
    _trimMemoryCache();

    // Patch the visible slot — re-lookup by key so we're race-safe.
    final i = _renderTiles.indexWhere((t) => t.index == key);
    if (i == -1) return; // scrolled out of view; image lives in cache
    if (_renderTiles[i].sourceTile != null) return; // already filled

    _renderTiles[i] = tile;
    _revision++;
    onTilesChanged?.call();
  }

  // ── Adjacent zoom pre-loading ────────────────────────────────────────

  /// Pre-loads tiles at z±1 for the visible area (not the padded area).
  /// This makes zooming in/out feel smooth — tiles are already in cache.
  void _scheduleAdjacentZoomPreload() {
    // Only preload for the visible area (not the padded area).
    // The visible area is the original grid before padding was applied.
    final visibleLeftLng = leftColumnTilesLngIndex + tilePadding;
    final visibleTopLat = topRowTilesLatIndex + tilePadding;
    final visibleHCount = horizontalTileCount - 2 * tilePadding;
    final visibleVCount = verticalTileCount - 2 * tilePadding;

    for (final dz in [-1, 1]) {
      final z = zoom + dz;
      if (z < 0 || z > 19) continue; // OSM max zoom is typically 19

      for (var h = 0; h < visibleHCount; h++) {
        for (var v = 0; v < visibleVCount; v++) {
          final lngIndex = visibleLeftLng + h;
          final latIndex = visibleTopLat + v;

          // Convert this tile's geographic extent to the other zoom level.
          // A tile at (z, x, y) covers a geographic rectangle. At z±1, this
          // rectangle maps to a different set of tiles.
          final lng = tileX2Lng(lngIndex.toDouble(), zoom);
          final lat = tileY2Lat(latIndex.toDouble(), zoom);
          final otherLng = lon2TileX(lng, z).floor();
          final otherLat = lat2TileY(lat, z).floor();

          // Also include the adjacent tile at z+1 (since one tile at z
          // maps to 4 tiles at z+1, we need to load all 4).
          final otherKey = tileKey(z, otherLng, otherLat);
          if (!_memoryCache.containsKey(otherKey) && !_inFlight.contains(otherKey)) {
            _schedulePreload(otherKey, z, otherLng, otherLat);
          }

          // For z+1, also load the 3 adjacent tiles (2x2 block).
          if (dz == 1) {
            for (var dx = 0; dx <= 1; dx++) {
              for (var dy = 0; dy <= 1; dy++) {
                if (dx == 0 && dy == 0) continue; // already scheduled
                final adjKey = tileKey(z, otherLng + dx, otherLat + dy);
                if (!_memoryCache.containsKey(adjKey) && !_inFlight.contains(adjKey)) {
                  _schedulePreload(adjKey, z, otherLng + dx, otherLat + dy);
                }
              }
            }
          }
        }
      }
    }
  }

  /// Schedules a tile load that only populates the memory cache (not the
  /// render list). Used for pre-loading adjacent zoom tiles.
  void _schedulePreload(String key, int z, int x, int y) {
    final n = 1 << z;
    if (y < 0 || y >= n) return;
    if (_inFlight.contains(key)) return;
    final failedUntil = _failedUntil[key];
    if (failedUntil != null && DateTime.now().isBefore(failedUntil)) return;

    _inFlight.add(key);

    if (hasStoredTile(key)) {
      _preloadFromDisk(key);
    } else {
      _preloadFromNetwork(key, z, x, y);
    }
  }

  Future<void> _preloadFromDisk(String key) async {
    try {
      final tile = await storedTile(key);
      if (tile?.sourceTile != null) {
        _completePreload(key, tile!);
        return;
      }
      await deleteStoredTile(key);
    } catch (_) {
      try {
        await deleteStoredTile(key);
      } catch (_) {}
    }
    _inFlight.remove(key);
  }

  Future<void> _preloadFromNetwork(String key, int z, int x, int y) async {
    try {
      final bytes = await _fetcher(z, x, y);
      final image = await Tile.decodeImage(bytes);
      unawaited(storeTile(key, Tile(image, key, y, x), bytes));
      _completePreload(key, Tile(image, key, y, x));
    } catch (_) {
      _inFlight.remove(key);
      _failedUntil[key] = DateTime.now().add(failureBackoff);
    }
  }

  void _completePreload(String key, Tile tile) {
    _inFlight.remove(key);
    if (_disposed || tile.sourceTile == null) return;

    // Only store in memory cache — don't update render list.
    _memoryCache.remove(key);
    _memoryCache[key] = tile.sourceTile!;
    _trimMemoryCache();
  }

  // ── Memory cache management ─────────────────────────────────────────

  void _trimMemoryCache() {
    while (_memoryCache.length > maxMemoryCachedTiles) {
      final oldestKey = _memoryCache.keys.first;
      final image = _memoryCache.remove(oldestKey);
      // Only dispose if not currently displayed in the visible grid.
      final visible = _renderTiles.any((t) => t.index == oldestKey);
      if (!visible) image?.dispose();
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  /// Builds a unique cache key for a tile at ([z], [x], [y]).
  static String tileKey(int z, int x, int y) => '$z/$x/$y';
}
