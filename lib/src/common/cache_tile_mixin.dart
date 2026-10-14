import 'dart:typed_data';

import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/common/disk_tile_cache.dart';
import 'package:hive_ce/hive.dart';

/// Persistent (Hive) tile cache.
///
/// Tiles are stored as raw `Uint8List` bytes (no base64 overhead). Legacy
/// entries that were base64-encoded by older versions are transparently
/// decoded when read.
mixin CacheTiles {
  static const String boxCache = 'osmTiles';

  /// Whether the Hive box has been opened. Safe to check before any
  /// read/write — avoids [LateInitializationError] if [initCache] was
  /// skipped.
  static bool get isCacheReady => MapDiskCache.isInitialized;

  /// Opens the tile cache box. Idempotent — calling twice is a no-op.
  static Future<void> initCache({MapDiskCacheOptions? options}) =>
      MapDiskCache._open(options);

  /// Persist a tile's raw PNG bytes under [cacheKey].
  Future<void> storeTile(
      String cacheKey, Tile tile, Uint8List imageBytes) async {
    if (!isCacheReady) return;
    await MapDiskCache._cache!.store(cacheKey, tile.toTileJson(imageBytes));
  }

  /// Returns the cached [Tile] (with decoded image) for [cacheKey], or
  /// `null` if absent / corrupt.
  Future<Tile?> storedTile(String cacheKey) async {
    if (!isCacheReady) return null;
    final tileJson = MapDiskCache._cache!.read(cacheKey);
    if (tileJson == null) return null;

    Uint8List? bytes = TileDiskCache.extractBytes(tileJson['image']);
    if (bytes == null || bytes.isEmpty) return null;

    final image = await Tile.decodeImage(bytes);
    return Tile.fromJson(
      cacheKey,
      Map<String, dynamic>.from(tileJson),
      sourceTile: image,
    );
  }

  /// Returns raw cached bytes for [cacheKey] without decoding — the caller
  /// applies its own decoder (raster codec or vector pipeline).
  Future<Uint8List?> storedTileBytes(String cacheKey) async {
    if (!isCacheReady) return null;
    return cachedTileBytes(cacheKey);
  }

  /// Returns raw cached bytes for [cacheKey] without decoding the image.
  /// Useful when we want to persist-then-decode in one shot.
  Uint8List? cachedTileBytes(String cacheKey) {
    if (!isCacheReady) return null;
    final tileJson = MapDiskCache._cache!.read(cacheKey);
    if (tileJson == null) return null;
    return TileDiskCache.extractBytes(tileJson['image']);
  }

  bool hasStoredTile(String cacheKey) =>
      isCacheReady && MapDiskCache._cache!.contains(cacheKey);

  /// Removes a corrupt cache entry so the next pass re-downloads.
  Future<void> deleteStoredTile(String cacheKey) async {
    if (!isCacheReady) return;
    await MapDiskCache._cache!.delete(cacheKey);
  }
}

/// Controls the persistent tile cache shared by all FOSM maps. Call [initMap]
/// first to open it. Clearing leaves rendered/compressed memory caches intact;
/// subsequent map activity can store tiles again.
class MapDiskCache {
  MapDiskCache._();

  static TileDiskCache? _cache;
  static Future<void>? _opening;
  static MapDiskCacheOptions _options = const MapDiskCacheOptions();

  static bool get isInitialized => _cache?.box.isOpen ?? false;

  static Future<void> _open(MapDiskCacheOptions? options) async {
    options?.validate();
    final opening = _opening;
    if (opening != null) await opening;
    if (isInitialized) {
      if (options != null) await configure(options);
      return;
    }
    if (options != null) _options = options;
    final future = (() async {
      final box = Hive.isBoxOpen(CacheTiles.boxCache)
          ? Hive.box(CacheTiles.boxCache)
          : await Hive.openBox(CacheTiles.boxCache);
      final cache = TileDiskCache(box, options: _options);
      await cache.initialize();
      _cache = cache;
    })();
    _opening = future;
    try {
      await future;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  /// Updates the global policy and immediately prunes excess/expired entries.
  /// Before initialization, saves the policy for the next [initMap] call.
  static Future<void> configure(MapDiskCacheOptions options) async {
    options.validate();
    final opening = _opening;
    if (opening != null) await opening;
    if (isInitialized) {
      await _cache!.configure(options);
    }
    _options = options;
  }

  /// Returns usage after pruning expired entries. Byte totals count compressed
  /// tile payloads, not Hive's metadata, append log, or browser storage overhead.
  /// Writes and maintenance flush last-access metadata for future restarts.
  static Future<MapDiskCacheStats> stats() async {
    final opening = _opening;
    if (opening != null) await opening;
    if (isInitialized) return _cache!.stats();
    return MapDiskCacheStats(
      isInitialized: false,
      entryCount: 0,
      sizeBytes: 0,
      options: _options,
      hits: 0,
      misses: 0,
      evictions: 0,
    );
  }

  /// Clears only FOSM's persistent tile box, including all vector namespaces.
  /// Waits for previously queued writes and resets session counters.
  static Future<void> clear() async {
    final opening = _opening;
    if (opening != null) await opening;
    if (isInitialized) await _cache!.clear();
  }

  /// Applies expiry/LRU eviction and compacts Hive storage where supported.
  /// Returns the number of removed entries; zero before initialization.
  static Future<int> prune() async {
    final opening = _opening;
    if (opening != null) await opening;
    if (!isInitialized) return 0;
    return _cache!.prune();
  }
}
