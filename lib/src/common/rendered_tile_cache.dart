import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Point-in-time attribution of one [RenderedTileCache]'s contents.
///
/// [bytes] is estimated RGBA pixel memory. Entries protected by the active
/// grid or a pin are counted in [protectedBytes]; the remainder is
/// immediately evictable. All values are point-in-time and change with
/// every grid rebuild, pin release or trim.
class RenderedTileCacheStats {
  const RenderedTileCacheStats({
    required this.entries,
    required this.bytes,
    required this.protectedEntries,
    required this.protectedBytes,
  });

  const RenderedTileCacheStats.empty()
      : entries = 0,
        bytes = 0,
        protectedEntries = 0,
        protectedBytes = 0;

  /// Total retained entries, protected ones included.
  final int entries;

  /// Estimated RGBA pixel bytes, protected images included.
  final int bytes;

  /// Entries protected by the active grid and/or at least one pin.
  final int protectedEntries;

  /// Estimated pixel bytes of the protected entries.
  final int protectedBytes;

  /// Entries evictable right now (not active, not pinned).
  int get evictableEntries => entries - protectedEntries;

  /// Estimated pixel bytes of the evictable entries.
  int get evictableBytes => bytes - protectedBytes;
}

/// Owns decoded tile images, retaining unused tiles briefly for return pans
/// and zooms. Active grid and snapshot images are never evicted. Their memory
/// can exceed the budget; unused images are evicted first in LRU order.
class RenderedTileCache {
  static const int defaultMaxBytes = 50 * 1024 * 1024;
  static const Duration defaultRetention = Duration(seconds: 20);

  RenderedTileCache({
    int maxBytes = defaultMaxBytes,
    Duration retention = defaultRetention,
    DateTime Function() now = DateTime.now,
  })  : _maxBytes = maxBytes,
        _retention = retention,
        _now = now {
    _validate(maxBytes, retention);
  }

  final LinkedHashMap<String, _CachedImage> _entries = LinkedHashMap();
  Set<String> _activeKeys = {};
  int _maxBytes;
  Duration _retention;
  final DateTime Function() _now;
  int _bytes = 0;
  Timer? _expiryTimer;
  bool _disposed = false;

  /// Estimated RGBA pixel memory, including protected images.
  int get bytes => _bytes;
  int get length => _entries.length;

  /// Point-in-time attribution of retained images, splitting protected
  /// (active grid + pinned) from evictable memory.
  RenderedTileCacheStats get stats {
    var protectedEntries = 0;
    var protectedBytes = 0;
    for (final entry in _entries.entries) {
      if (_activeKeys.contains(entry.key) || entry.value.pins > 0) {
        protectedEntries++;
        protectedBytes += entry.value.bytes;
      }
    }
    return RenderedTileCacheStats(
      entries: _entries.length,
      bytes: _bytes,
      protectedEntries: protectedEntries,
      protectedBytes: protectedBytes,
    );
  }

  bool containsKey(String key) => _entries.containsKey(key);

  ui.Image? get(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    entry.lastUsed = _now();
    _entries[key] = entry;
    return entry.image;
  }

  /// Takes ownership of [image]. An existing image is reused when two
  /// completions target the same key, disposing the redundant handle.
  ui.Image put(String key, ui.Image image) {
    final existing = get(key);
    if (existing != null) {
      if (!identical(existing, image)) image.dispose();
      return existing;
    }
    assert(!_disposed);
    final entry = _CachedImage(image, _now());
    _entries[key] = entry;
    _bytes += entry.bytes;
    trim();
    return image;
  }

  void updatePolicy({required int maxBytes, required Duration retention}) {
    _validate(maxBytes, retention);
    _maxBytes = maxBytes;
    _retention = retention;
    trim();
  }

  /// Call before rebuilding the grid so newly visible cache hits are
  /// protected before the old grid loses protection.
  void setActiveKeys(Set<String> keys) {
    final now = _now();
    for (final key in _activeKeys.difference(keys)) {
      _entries[key]?.lastUsed = now;
    }
    _activeKeys = keys;
    trim();
  }

  /// Protects the images currently held by a snapshot. The returned callback
  /// releases that protection exactly once, including after cache disposal.
  VoidCallback pin(Iterable<String> keys) {
    final entries = keys.toSet().map((key) => _entries[key]).nonNulls.toList();
    for (final entry in entries) {
      entry.pins++;
    }
    trim();
    var released = false;
    return () {
      if (released || _disposed) return;
      released = true;
      final now = _now();
      for (final entry in entries) {
        entry.pins--;
        entry.lastUsed = now;
      }
      trim();
    };
  }

  /// Evicts every entry that is neither protected by the active grid nor
  /// pinned, regardless of budget and retention — the deliberate response
  /// to system memory pressure. Protected images survive; everything else
  /// is rebuildable from the persistent cache or the network.
  ///
  /// Afterwards no expiry timer runs: the remaining entries are all
  /// protected, and protection is lifted only through [setActiveKeys] or
  /// pin release, both of which re-run [trim].
  void flushUnused() {
    if (_disposed) return;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    for (final key in _entries.keys.toList()) {
      final entry = _entries[key]!;
      if (_activeKeys.contains(key) || entry.pins > 0) continue;
      _entries.remove(key);
      _bytes -= entry.bytes;
      entry.image.dispose();
    }
  }

  void trim() {
    if (_disposed) return;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final now = _now();
    Duration? nextExpiry;
    for (final key in _entries.keys.toList()) {
      final entry = _entries[key]!;
      if (_activeKeys.contains(key) || entry.pins > 0) continue;
      final remaining = _retention - now.difference(entry.lastUsed);
      if (_bytes > _maxBytes || remaining <= Duration.zero) {
        _entries.remove(key);
        _bytes -= entry.bytes;
        entry.image.dispose();
      } else if (nextExpiry == null || remaining < nextExpiry) {
        nextExpiry = remaining;
      }
    }
    if (nextExpiry != null) {
      _expiryTimer = Timer(nextExpiry, trim);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _activeKeys.clear();
    _bytes = 0;
  }

  static void _validate(int maxBytes, Duration retention) {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be nonnegative');
    }
    if (retention.isNegative) {
      throw ArgumentError.value(retention, 'retention', 'must be nonnegative');
    }
  }
}

class _CachedImage {
  _CachedImage(this.image, this.lastUsed)
      : bytes = image.width * image.height * 4;

  final ui.Image image;
  final int bytes;
  DateTime lastUsed;
  int pins = 0;
}
