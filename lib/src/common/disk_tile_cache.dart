import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';

/// Policy shared by all raster and vector tiles in the persistent cache.
class MapDiskCacheOptions {
  const MapDiskCacheOptions({
    this.maxBytes = 256 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
  }) : assert(maxBytes >= 0);

  /// Maximum retained compressed payload bytes, excluding Hive overhead.
  /// Zero disables persistent tile storage.
  final int maxBytes;

  /// Absolute lifetime from storage, independent of reads. Null disables
  /// expiry; zero disables storage. Choose a lifetime allowed by the provider.
  final Duration? maxAge;

  void validate() {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be nonnegative');
    }
    if (maxAge?.isNegative ?? false) {
      throw ArgumentError.value(maxAge, 'maxAge', 'must be nonnegative');
    }
  }
}

/// Persistent cache usage and counters for the current session.
class MapDiskCacheStats {
  const MapDiskCacheStats({
    required this.isInitialized,
    required this.entryCount,
    required this.sizeBytes,
    required this.options,
    required this.hits,
    required this.misses,
    required this.evictions,
  });

  final bool isInitialized;
  final int entryCount;
  final int sizeBytes;
  final MapDiskCacheOptions options;

  /// Payload read hits/misses. Availability checks are excluded; a lookup
  /// through canonical and legacy keys can count more than once per tile.
  final int hits;
  final int misses;
  final int evictions;
}

/// Internal owner of a Hive tile box. Mutations are serialized across maps
/// so pruning, metadata updates, and clearing cannot resurrect older records.
class TileDiskCache {
  TileDiskCache(
    this.box, {
    MapDiskCacheOptions options = const MapDiskCacheOptions(),
    this._now = DateTime.now,
  })  : _options = options {
    options.validate();
    _lastMaintenanceMs = _lastMetadataFlushMs = _now().millisecondsSinceEpoch;
  }

  /// Minimum spacing of the full expiry/consistency scan that runs on the
  /// write path. A full pass touches every record, so doing it per write made
  /// each tile store cost milliseconds that grow with the cache.
  static const int _maintenanceIntervalMs = 60 * 1000;

  /// Spacing of write-path metadata flushes, and how stale a persisted
  /// last-access time must be before a read earns a rewrite. The record is
  /// rewritten whole (payload included), so a flush for every read cost one
  /// extra tile-sized write per tile read. In-memory recency stays exact;
  /// only the value kept for the next launch is coarse.
  static const int _lazyFlushIntervalMs = 30 * 1000;
  static const int _touchGranularityMs = 60 * 60 * 1000;

  final Box box;
  final DateTime Function() _now;
  MapDiskCacheOptions _options;

  /// Oldest-first by last access: reads and writes re-insert at the end, and
  /// a full index pass re-sorts adopted records, so LRU eviction takes the
  /// front without sorting.
  final LinkedHashMap<dynamic, _DiskEntry> _entries = LinkedHashMap();
  final Set<dynamic> _invalidKeys = {};
  final Set<dynamic> _dirtyKeys = {};
  bool _adoptedSinceSort = false;
  int _lastMaintenanceMs = 0;
  int _lastMetadataFlushMs = 0;
  Future<void> _pending = Future.value();
  int _bytes = 0;
  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;
  int _accessOrder = 0;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> initialize() => _serialize(() async {
        _syncIndex();
        // Adding metadata leaves the old payload and coordinates untouched.
        // Older readers ignore the extra keys, so rollback needs no rewrite.
        await _flushMetadata();
        await _prune();
      });

  Future<void> configure(MapDiskCacheOptions options) {
    options.validate();
    return _serialize(() async {
      _options = options;
      await _prune();
      await _flushMetadata();
      await box.compact();
    });
  }

  Future<void> store(String key, Map<String, dynamic> record) =>
      _serialize(() async {
        _syncIndex();
        final bytes = extractBytes(record['image']);
        if (bytes == null ||
            bytes.isEmpty ||
            bytes.length > _options.maxBytes ||
            _options.maxAge == Duration.zero) {
          return;
        }
        final now = _now().millisecondsSinceEpoch;
        final entry = _DiskEntry(bytes.length, now, now, ++_accessOrder,
            payload: record['image']);
        final value = Map<String, dynamic>.of(record)..addAll(entry.metadata);
        await box.put(key, value);
        _removeIndex(key);
        _invalidKeys.remove(key);
        _entries[key] = entry;
        _bytes += entry.size;
        // Incremental: evict from the LRU front and only run the full scan
        // now and then. Maintenance calls (stats, prune, configure) still do
        // the complete pass and flush everything.
        await _evictLeastRecentlyUsed();
        if (now - _lastMaintenanceMs >= _maintenanceIntervalMs) {
          await _prune();
        }
        await _flushMetadata(lazy: true);
      });

  /// Reads synchronously for the manager's byte-recovery path. Expired tiles
  /// are cache misses immediately; maintenance removes their stored records.
  Map? read(String key) {
    _indexKey(key);
    final entry = _entries[key];
    if (!box.isOpen || entry == null || _expired(entry)) {
      _misses++;
      return null;
    }
    final record = box.get(key);
    if (record is! Map) {
      _misses++;
      return null;
    }
    _hits++;
    _entries.remove(key);
    entry.accessedAt = _now().millisecondsSinceEpoch;
    entry.accessOrder = ++_accessOrder;
    entry.dirty = true;
    _dirtyKeys.add(key);
    _entries[key] = entry;
    return record;
  }

  bool contains(String key) {
    _indexKey(key);
    final entry = _entries[key];
    return entry != null && !_expired(entry);
  }

  Future<void> delete(String key) => _serialize(() async {
        await box.delete(key);
        _removeIndex(key);
        _invalidKeys.remove(key);
      });

  Future<void> clear() => _serialize(() async {
        await box.clear();
        _entries.clear();
        _invalidKeys.clear();
        _dirtyKeys.clear();
        _bytes = 0;
        _hits = 0;
        _misses = 0;
        _evictions = 0;
      });

  /// Removes expired/invalid/LRU entries and compacts Hive's native file.
  Future<int> prune() => _serialize(() async {
        final removed = await _prune();
        await _flushMetadata();
        await box.compact();
        return removed;
      });

  Future<MapDiskCacheStats> stats() => _serialize(() async {
        await _prune();
        await _flushMetadata();
        return MapDiskCacheStats(
          isInitialized: true,
          entryCount: _entries.length,
          sizeBytes: _bytes,
          options: _options,
          hits: _hits,
          misses: _misses,
          evictions: _evictions,
        );
      });

  bool _expired(_DiskEntry entry) {
    final age = _options.maxAge;
    return age != null &&
        _now().millisecondsSinceEpoch - entry.storedAt >= age.inMilliseconds;
  }

  void _removeIndex(dynamic key) {
    final previous = _entries.remove(key);
    _dirtyKeys.remove(key);
    if (previous != null) _bytes -= previous.size;
  }

  void _indexKey(dynamic key) {
    if (!box.isOpen) return;
    if (!box.containsKey(key)) {
      _removeIndex(key);
      _invalidKeys.remove(key);
      return;
    }
    final record = box.get(key);
    if (record is! Map) {
      _removeIndex(key);
      _invalidKeys.add(key);
      return;
    }
    final existing = _entries[key];
    // Our writes carry metadata; unindexed legacy/external writes are adopted
    // with a fresh age baseline because their original storage time is unknown.
    if (existing != null && identical(existing.payload, record['image'])) {
      return;
    }
    final bytes = extractBytes(record['image']);
    _removeIndex(key);
    if (bytes == null || bytes.isEmpty) {
      _invalidKeys.add(key);
      return;
    }
    final now = _now().millisecondsSinceEpoch;
    final storedAt = record['cachedAt'];
    final accessedAt = record['lastAccessedAt'];
    final entry = _DiskEntry(
      bytes.length,
      storedAt is int && storedAt >= 0 && storedAt <= now ? storedAt : now,
      accessedAt is int && accessedAt >= 0 && accessedAt <= now
          ? accessedAt
          : now,
      ++_accessOrder,
      payload: record['image'],
      // A record without a usable stamp has nothing persisted yet.
      persistedAccessedAt:
          accessedAt is int && accessedAt >= 0 ? accessedAt : -1,
    );
    entry.dirty = record['cachedAt'] != entry.storedAt ||
        record['lastAccessedAt'] != entry.accessedAt ||
        record['byteLength'] != bytes.length;
    if (entry.dirty) _dirtyKeys.add(key);
    _invalidKeys.remove(key);
    _entries[key] = entry;
    _bytes += entry.size;
    _adoptedSinceSort = true;
  }

  void _syncIndex() {
    final keys = box.keys.toSet();
    for (final key in _entries.keys.toList()) {
      if (!keys.contains(key)) _removeIndex(key);
    }
    _invalidKeys.removeWhere((key) => !keys.contains(key));
    for (final key in keys) {
      _indexKey(key);
    }
    if (_adoptedSinceSort) _sortLeastRecentFirst();
  }

  /// Orders [_entries] oldest access first. Adopted records arrive in the
  /// box's key order, which says nothing about recency.
  void _sortLeastRecentFirst() {
    _adoptedSinceSort = false;
    final sorted = _entries.entries.toList()
      ..sort((a, b) {
        final time = a.value.accessedAt.compareTo(b.value.accessedAt);
        return time != 0
            ? time
            : a.value.accessOrder.compareTo(b.value.accessOrder);
      });
    _entries
      ..clear()
      ..addEntries(sorted);
  }

  /// Drops the least recently used records until the payload bytes fit,
  /// without scanning or sorting the index.
  Future<int> _evictLeastRecentlyUsed() async {
    if (_bytes <= _options.maxBytes) return 0;
    final remove = <dynamic>[];
    var remaining = _bytes;
    for (final entry in _entries.entries) {
      if (remaining <= _options.maxBytes) break;
      remove.add(entry.key);
      remaining -= entry.value.size;
    }
    if (remove.isEmpty) return 0;
    await box.deleteAll(remove);
    for (final key in remove) {
      _removeIndex(key);
    }
    _evictions += remove.length;
    return remove.length;
  }

  Future<int> _prune() async {
    _lastMaintenanceMs = _now().millisecondsSinceEpoch;
    _syncIndex();
    final remove = <dynamic>{..._invalidKeys};
    var remainingBytes = _bytes;
    for (final entry in _entries.entries) {
      if (_expired(entry.value)) {
        remove.add(entry.key);
        remainingBytes -= entry.value.size;
      }
    }
    if (remainingBytes > _options.maxBytes) {
      // [_entries] is already oldest-first.
      for (final entry in _entries.entries) {
        if (remainingBytes <= _options.maxBytes) break;
        if (remove.add(entry.key)) remainingBytes -= entry.value.size;
      }
    }
    if (remove.isNotEmpty) {
      await box.deleteAll(remove);
      for (final key in remove) {
        _removeIndex(key);
        _invalidKeys.remove(key);
      }
      _evictions += remove.length;
    }
    return remove.length;
  }

  /// Writes last-access metadata back to the records. A forced flush (every
  /// maintenance call) writes every changed record. The lazy flush on the
  /// write path runs at most every [_lazyFlushIntervalMs] and only for
  /// records whose persisted stamp is [_touchGranularityMs] behind, because
  /// each rewrite carries the tile payload.
  Future<void> _flushMetadata({bool lazy = false}) async {
    if (_dirtyKeys.isEmpty) return;
    final now = _now().millisecondsSinceEpoch;
    if (lazy && now - _lastMetadataFlushMs < _lazyFlushIntervalMs) return;
    final records = <dynamic, Map>{};
    final changed = <dynamic, (_DiskEntry, int)>{};
    for (final key in _dirtyKeys.toList()) {
      final entry = _entries[key];
      if (entry == null || !entry.dirty) {
        _dirtyKeys.remove(key);
        continue;
      }
      if (lazy &&
          entry.persistedAccessedAt >= 0 &&
          entry.accessedAt - entry.persistedAccessedAt < _touchGranularityMs) {
        continue;
      }
      final record = box.get(key);
      if (record is! Map) continue;
      records[key] = Map.of(record)..addAll(entry.metadata);
      changed[key] = (entry, entry.accessedAt);
    }
    _lastMetadataFlushMs = now;
    if (records.isEmpty) return;
    await box.putAll(records);
    for (final pair in changed.entries) {
      final (entry, stamp) = pair.value;
      // A synchronous read can touch an entry during the Hive commit.
      if (entry.accessedAt == stamp) {
        entry.dirty = false;
        entry.persistedAccessedAt = stamp;
        _dirtyKeys.remove(pair.key);
      }
    }
  }

  static Uint8List? extractBytes(Object? raw) {
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    if (raw is String) {
      try {
        return base64.decode(raw);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

class _DiskEntry {
  _DiskEntry(this.size, this.storedAt, this.accessedAt, this.accessOrder,
      {this.payload, int? persistedAccessedAt})
      : persistedAccessedAt = persistedAccessedAt ?? accessedAt;
  final int size;
  final int storedAt;
  int accessedAt;
  int accessOrder;
  final Object? payload;

  /// The last-access stamp stored with the record, or -1 when it has none.
  int persistedAccessedAt;
  bool dirty = false;
  Map<String, int> get metadata => {
        'cachedAt': storedAt,
        'lastAccessedAt': accessedAt,
        'byteLength': size,
      };
}
