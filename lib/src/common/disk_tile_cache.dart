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
    DateTime Function() now = DateTime.now,
  })  : _options = options,
        _now = now {
    options.validate();
  }

  final Box box;
  final DateTime Function() _now;
  MapDiskCacheOptions _options;
  final LinkedHashMap<dynamic, _DiskEntry> _entries = LinkedHashMap();
  final Set<dynamic> _invalidKeys = {};
  Future<void> _pending = Future.value();
  int _bytes = 0;
  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;
  int _accessOrder = 0;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
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
        await _prune();
        await _flushMetadata();
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
    );
    entry.dirty = record['cachedAt'] != entry.storedAt ||
        record['lastAccessedAt'] != entry.accessedAt ||
        record['byteLength'] != bytes.length;
    _invalidKeys.remove(key);
    _entries[key] = entry;
    _bytes += entry.size;
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
  }

  Future<int> _prune() async {
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
      final lru = _entries.entries.toList()
        ..sort((a, b) {
          final time = a.value.accessedAt.compareTo(b.value.accessedAt);
          return time != 0
              ? time
              : a.value.accessOrder.compareTo(b.value.accessOrder);
        });
      for (final entry in lru) {
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

  Future<void> _flushMetadata() async {
    final records = <dynamic, Map>{};
    final changed = <_DiskEntry, int>{};
    for (final pair in _entries.entries) {
      final entry = pair.value;
      if (!entry.dirty) continue;
      final record = box.get(pair.key);
      if (record is! Map) continue;
      records[pair.key] = Map.of(record)..addAll(entry.metadata);
      changed[entry] = entry.accessedAt;
    }
    if (records.isEmpty) return;
    await box.putAll(records);
    for (final pair in changed.entries) {
      // A synchronous read can touch an entry during the Hive commit.
      if (pair.key.accessedAt == pair.value) pair.key.dirty = false;
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
      {this.payload});
  final int size;
  final int storedAt;
  int accessedAt;
  int accessOrder;
  final Object? payload;
  bool dirty = false;
  Map<String, int> get metadata => {
        'cachedAt': storedAt,
        'lastAccessedAt': accessedAt,
        'byteLength': size,
      };
}
