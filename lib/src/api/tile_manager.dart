import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Size;
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
  static const int maxMemoryCachedTiles = 192;
  static const Duration failureBackoff = Duration(seconds: 5);

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
