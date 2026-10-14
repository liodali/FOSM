import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/common/cache_tile_mixin.dart';
import 'package:fosm/src/common/disk_tile_cache.dart';
import 'package:hive_ce/hive.dart';

import '../support/cache_directory.dart';

class _TileStore with CacheTiles {}

Map<String, dynamic> _record(int size) => {
      'image': Uint8List.fromList(List.filled(size, 1)),
      'latIndex': 3,
      'lngIndex': 4,
    };

void main() {
  late String directory;
  late Box box;
  late DateTime now;
  late TileDiskCache cache;

  setUpAll(() async {
    directory = await createCacheDirectory();
    Hive.init(directory);
    box = await Hive.openBox('fosm_disk_policy_test');
  });

  setUp(() async {
    await box.clear();
    now = DateTime.utc(2026, 10, 14);
    cache = TileDiskCache(box, now: () => now);
    await cache.initialize();
  });

  tearDownAll(() async {
    await Hive.deleteBoxFromDisk('fosm_disk_policy_test');
    if (MapDiskCache.isInitialized) {
      await MapDiskCache.clear();
      await Hive.deleteBoxFromDisk(CacheTiles.boxCache);
    }
    await Hive.close();
    await removeCacheDirectory(directory);
  });

  test('metadata adoption preserves legacy bytes and old-reader fields',
      () async {
    final legacy = _record(3)..['image'] = base64.encode([1, 2, 3]);
    legacy['custom'] = 'preserve';
    await box.put('legacy', legacy);
    cache = TileDiskCache(box, now: () => now);
    await cache.initialize();
    final value = Map<String, dynamic>.from(box.get('legacy') as Map);
    expect(value['image'], legacy['image']);
    expect(value['custom'], 'preserve');
    expect(value['byteLength'], 3);
    expect(value['cachedAt'], now.millisecondsSinceEpoch);
    final oldReader = Tile.fromJson('legacy', value, sourceTile: null);
    expect(oldReader.latIndex, 3);
    expect(oldReader.lngIndex, 4);
    expect(
        TileDiskCache.extractBytes(cache.read('legacy')!['image']), [1, 2, 3]);
    expect((await cache.stats()).sizeBytes, 3);
  });

  test('reads do not extend absolute expiry; expired reads miss immediately',
      () async {
    await cache
        .configure(const MapDiskCacheOptions(maxAge: Duration(seconds: 2)));
    await cache.store('tile', _record(3));
    final storedAt = (box.get('tile') as Map)['cachedAt'];
    now = now.add(const Duration(seconds: 1));
    expect(cache.read('tile'), isNotNull);
    await cache.stats();
    expect((box.get('tile') as Map)['cachedAt'], storedAt);
    now = now.add(const Duration(seconds: 1));
    expect(cache.contains('tile'), isFalse);
    expect(cache.read('tile'), isNull);
    final stats = await cache.stats();
    expect(stats.entryCount, 0);
    expect(stats.evictions, 1);
    expect(stats.hits, 1);
    expect(stats.misses, 1);
    expect(box.containsKey('tile'), isFalse);
  });

  test('LRU eviction respects payload bytes and same-millisecond reads',
      () async {
    await cache.configure(const MapDiskCacheOptions(maxBytes: 6));
    await cache.store('first', _record(3));
    await cache.store('second', _record(3));
    cache.read('first');
    await cache.store('third', _record(3));
    expect(cache.contains('first'), isTrue);
    expect(cache.contains('second'), isFalse);
    expect(cache.contains('third'), isTrue);
    final stats = await cache.stats();
    expect(stats.sizeBytes, 6);
    expect(stats.entryCount, 2);
    expect(stats.evictions, 1);
  });

  test('startup prunes known expired records and adopts undated ones',
      () async {
    final expired = _record(3)
      ..['cachedAt'] =
          now.subtract(const Duration(days: 8)).millisecondsSinceEpoch;
    await box.put('expired', expired);
    await box.put('undated', _record(3));
    cache = TileDiskCache(box, now: () => now);
    await cache.initialize();
    expect(cache.contains('expired'), isFalse);
    expect(cache.contains('undated'), isTrue);
    expect((await cache.stats()).sizeBytes, 3);
  });

  test('replacement sizes are counted once and oversized tiles are skipped',
      () async {
    await cache.configure(const MapDiskCacheOptions(maxBytes: 6));
    await cache.store('tile', _record(3));
    await cache.store('tile', _record(5));
    expect((await cache.stats()).sizeBytes, 5);
    await cache.store('large', _record(7));
    expect(cache.contains('large'), isFalse);
    expect(cache.contains('tile'), isTrue);
    expect((await cache.stats()).sizeBytes, 5);
  });

  test('runtime shrink and zero budget apply to existing and future writes',
      () async {
    await cache.store('first', _record(3));
    now = now.add(const Duration(seconds: 1));
    await cache.store('second', _record(3));
    await cache.configure(const MapDiskCacheOptions(maxBytes: 3));
    expect(cache.contains('first'), isFalse);
    expect(cache.contains('second'), isTrue);
    await cache.configure(const MapDiskCacheOptions(maxBytes: 0));
    await cache.store('third', _record(3));
    expect((await cache.stats()).sizeBytes, 0);
    expect(box.isEmpty, isTrue);
  });

  test('null age disables expiry and zero age disables storage', () async {
    await cache.configure(const MapDiskCacheOptions(maxAge: null));
    await cache.store('tile', _record(3));
    now = now.add(const Duration(days: 3650));
    expect(cache.read('tile'), isNotNull);
    await cache.configure(const MapDiskCacheOptions(maxAge: Duration.zero));
    await cache.store('tile', _record(3));
    expect((await cache.stats()).entryCount, 0);
  });

  test('restart retains age, usage, and flushed last-access metadata',
      () async {
    await cache.store('first', _record(3));
    now = now.add(const Duration(seconds: 1));
    await cache.store('second', _record(3));
    now = now.add(const Duration(seconds: 1));
    cache.read('first');
    await cache.stats();
    await box.close();
    box = await Hive.openBox('fosm_disk_policy_test');
    cache = TileDiskCache(box,
        now: () => now, options: const MapDiskCacheOptions(maxBytes: 6));
    await cache.initialize();
    await cache.store('third', _record(3));
    expect(cache.contains('first'), isTrue);
    expect(cache.contains('second'), isFalse);
    expect((await cache.stats()).sizeBytes, 6);
    expect((box.get('first') as Map)['cachedAt'],
        now.subtract(const Duration(seconds: 2)).millisecondsSinceEpoch);
  });

  test('queued writes and metadata cannot restore entries after clear',
      () async {
    final write = cache.store('before', _record(3));
    final clear = cache.clear();
    await Future.wait([write, clear]);
    final stats = await cache.stats();
    expect(stats.entryCount, 0);
    expect(stats.sizeBytes, 0);
    expect(stats.hits, 0);
    await cache.store('after', _record(3));
    expect(cache.contains('after'), isTrue);
  });

  test('pruning removes corrupt records without damaging valid payloads',
      () async {
    await cache.store('valid', _record(3));
    await box.put('bad', {'image': 'invalid base64'});
    expect(await cache.prune(), 1);
    expect(cache.contains('valid'), isTrue);
    expect((await cache.stats()).sizeBytes, 3);
  });

  test('public cache API is safe before initialization and across reopening',
      () async {
    expect((await MapDiskCache.stats()).isInitialized, isFalse);
    await MapDiskCache.clear();
    expect(await MapDiskCache.prune(), 0);
    await MapDiskCache.configure(const MapDiskCacheOptions(maxBytes: 6));
    await Future.wait([CacheTiles.initCache(), CacheTiles.initCache()]);
    final store = _TileStore();
    await store.storeTile('tile', Tile(null, 'tile', 3, 4), Uint8List(3));
    expect(await store.storedTileBytes('tile'), Uint8List(3));
    final stats = await MapDiskCache.stats();
    expect(stats.isInitialized, isTrue);
    expect(stats.entryCount, 1);
    expect(stats.options.maxBytes, 6);
    await Hive.box(CacheTiles.boxCache).close();
    expect(MapDiskCache.isInitialized, isFalse);
    await CacheTiles.initCache();
    expect((await MapDiskCache.stats()).entryCount, 1);
    final unrelated = await Hive.openBox('fosm_other_data_test');
    await unrelated.put('preference', 'keep');
    await MapDiskCache.clear();
    expect((await MapDiskCache.stats()).entryCount, 0);
    expect(unrelated.get('preference'), 'keep');
    await Hive.deleteBoxFromDisk('fosm_other_data_test');
    await store.storeTile('new', Tile(null, 'new', 3, 4), Uint8List(3));
    expect(store.hasStoredTile('new'), isTrue);
    await MapDiskCache.configure(const MapDiskCacheOptions(maxBytes: 0));
    expect(store.hasStoredTile('new'), isFalse);
  });

  test('invalid policies fail without changing valid cache contents', () async {
    await cache.store('tile', _record(3));
    expect(
        () => cache.configure(
            const MapDiskCacheOptions(maxAge: Duration(seconds: -1))),
        throwsArgumentError);
    expect(cache.contains('tile'), isTrue);
  });
}
