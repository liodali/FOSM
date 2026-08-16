import 'dart:convert';
import 'dart:typed_data';

import 'package:fosm/src/api/tile.dart';
import 'package:hive_ce/hive.dart';

/// Persistent (Hive) tile cache.
///
/// Tiles are stored as raw `Uint8List` bytes (no base64 overhead). Legacy
/// entries that were base64-encoded by older versions are transparently
/// decoded when read.
mixin CacheTiles {
  static const String boxCache = 'osmTiles';
  static Box? _boxTileCache;

  /// Whether the Hive box has been opened. Safe to check before any
  /// read/write — avoids [LateInitializationError] if [initCache] was
  /// skipped.
  static bool get isCacheReady => _boxTileCache?.isOpen ?? false;

  /// Opens the tile cache box. Idempotent — calling twice is a no-op.
  static Future<void> initCache() async {
    if (Hive.isBoxOpen(boxCache)) {
      _boxTileCache ??= Hive.box(boxCache);
      return;
    }
    await Hive.openBox(boxCache);
    _boxTileCache = Hive.box(boxCache);
  }

  /// Persist a tile's raw PNG bytes under [cacheKey].
  Future<void> storeTile(String cacheKey, Tile tile, Uint8List imageBytes) async {
    if (!isCacheReady) return;
    await _boxTileCache!.put(cacheKey, tile.toTileJson(imageBytes));
  }

  /// Returns the cached [Tile] (with decoded image) for [cacheKey], or
  /// `null` if absent / corrupt.
  Future<Tile?> storedTile(String cacheKey) async {
    if (!isCacheReady) return null;
    final tileJson = _boxTileCache!.get(cacheKey);
    if (tileJson is! Map) return null;

    Uint8List? bytes = _extractBytes(tileJson['image']);
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
    final tileJson = _boxTileCache!.get(cacheKey);
    if (tileJson is! Map) return null;
    return _extractBytes(tileJson['image']);
  }

  /// Returns raw cached bytes for [cacheKey] without decoding the image.
  /// Useful when we want to persist-then-decode in one shot.
  Uint8List? cachedTileBytes(String cacheKey) {
    if (!isCacheReady) return null;
    final tileJson = _boxTileCache!.get(cacheKey);
    if (tileJson is! Map) return null;
    return _extractBytes(tileJson['image']);
  }

  bool hasStoredTile(String cacheKey) =>
      isCacheReady && _boxTileCache!.containsKey(cacheKey);

  /// Removes a corrupt cache entry so the next pass re-downloads.
  Future<void> deleteStoredTile(String cacheKey) async {
    if (!isCacheReady) return;
    await _boxTileCache!.delete(cacheKey);
  }

  static Uint8List? _extractBytes(Object? raw) {
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    if (raw is String) {
      try {
        return base64.decode(raw); // legacy base64 entries
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
