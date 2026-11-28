import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_source.dart';
import 'package:fosm/src/common/cache_tile_mixin.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:hive_ce/hive.dart';

import '../support/cache_directory.dart';

void main() {
  group('freshnessFromHeaders', () {
    test('reads max-age and subtracts the CDN age', () {
      expect(
        freshnessFromHeaders(cacheControl: 'public, max-age=3600'),
        const Duration(hours: 1),
      );
      expect(
        freshnessFromHeaders(cacheControl: 'max-age=3600', age: '600'),
        const Duration(minutes: 50),
      );
    });

    test('anything but a positive max-age reads as not fresh', () {
      expect(freshnessFromHeaders(), Duration.zero);
      expect(freshnessFromHeaders(cacheControl: 'public'), Duration.zero);
      expect(freshnessFromHeaders(cacheControl: 'max-age=0'), Duration.zero);
      expect(
        freshnessFromHeaders(cacheControl: 'no-store, max-age=60'),
        Duration.zero,
      );
      expect(
        freshnessFromHeaders(cacheControl: 'no-cache, max-age=60'),
        Duration.zero,
      );
      expect(
        freshnessFromHeaders(cacheControl: 'max-age=60', age: '90'),
        Duration.zero,
      );
      expect(freshnessFromHeaders(cacheControl: 'max-age=soon'), Duration.zero);
    });
  });

  group('loadVectorStyle document cache', () {
    late String directory;
    late HttpServer server;
    late String base;
    late VectorMapStyle style;

    final hits = <String, int>{};
    var maxConcurrent = 0;
    var concurrent = 0;
    var tileJsonDelay = Duration.zero;
    var cacheControl = 'public, max-age=3600';
    var failing = false;

    String styleJson() => jsonEncode({
      'version': 8,
      'sources': {
        'one': {'type': 'vector', 'url': '$base/one.json'},
        'two': {'type': 'vector', 'url': '$base/two.json'},
      },
      'layers': <Object>[],
    });

    String tileJson(String name) => jsonEncode({
      'tiles': ['$base/$name/{z}/{x}/{y}.pbf'],
      'minzoom': 0,
      'maxzoom': 14,
    });

    setUpAll(() async {
      directory = await createCacheDirectory();
      Hive.init(directory);
      await CacheTiles.initCache();
    });

    tearDownAll(() async {
      await MapDiskCache.clear();
      await Hive.deleteBoxFromDisk(CacheTiles.boxCache);
      await Hive.close();
      await removeCacheDirectory(directory);
    });

    setUp(() async {
      await MapDiskCache.clear();
      hits.clear();
      maxConcurrent = 0;
      concurrent = 0;
      tileJsonDelay = Duration.zero;
      cacheControl = 'public, max-age=3600';
      failing = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      style = VectorMapStyle(id: 'doc-cache', styleUrl: '$base/style.json');
      server.listen((request) async {
        final path = request.uri.path;
        hits[path] = (hits[path] ?? 0) + 1;
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        try {
          if (failing) {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
            return;
          }
          if (path != '/style.json') await Future<void>.delayed(tileJsonDelay);
          final body = switch (path) {
            '/style.json' => styleJson(),
            '/one.json' => tileJson('one'),
            '/two.json' => tileJson('two'),
            _ => '',
          };
          request.response
            ..headers.set('cache-control', cacheControl)
            ..headers.contentType = ContentType.json
            ..write(body);
          await request.response.close();
        } finally {
          concurrent--;
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test('a fresh cached style and its TileJSON skip the network', () async {
      final first = await loadVectorStyle(style);
      await settle();
      expect(hits, {'/style.json': 1, '/one.json': 1, '/two.json': 1});

      final second = await loadVectorStyle(style);
      expect(hits, {'/style.json': 1, '/one.json': 1, '/two.json': 1});
      expect(second.sources.keys, first.sources.keys);
      expect(second.sources['one']!.urlTemplate, '$base/one/{z}/{x}/{y}.pbf');
      expect(second.sources['two']!.maxZoom, 14);
    });

    test('a document the server wants revalidated is fetched again', () async {
      cacheControl = 'no-cache';
      await loadVectorStyle(style);
      await settle();
      await loadVectorStyle(style);
      expect(hits, {'/style.json': 2, '/one.json': 2, '/two.json': 2});
    });

    test('a stale copy answers when the network fails', () async {
      cacheControl = 'max-age=0';
      final first = await loadVectorStyle(style);
      await settle();
      failing = true;
      final second = await loadVectorStyle(style);
      expect(
        second.sources['one']!.urlTemplate,
        first.sources['one']!.urlTemplate,
      );
      expect(hits['/style.json'], 2);
    });

    test('without a cache copy a network failure still throws', () async {
      failing = true;
      await expectLater(
        loadVectorStyle(style),
        throwsA(isA<TileLoadException>()),
      );
    });

    test('the tile host is announced before any TileJSON is fetched', () async {
      final announced = <String>[];
      final hitsThen = <Map<String, int>>[];
      await loadVectorStyle(style, onSourceUrl: (url) {
        announced.add(url);
        hitsThen.add(Map.of(hits));
      });
      expect(announced, ['$base/one.json']);
      expect(hitsThen.single, {'/style.json': 1});

      // A style answered from the cache announces it too.
      await settle();
      announced.clear();
      await loadVectorStyle(style, onSourceUrl: announced.add);
      expect(announced, ['$base/one.json']);
    });

    test('TileJSON documents are requested concurrently', () async {
      tileJsonDelay = const Duration(milliseconds: 150);
      final watch = Stopwatch()..start();
      await loadVectorStyle(style);
      watch.stop();
      expect(maxConcurrent, 2);
      expect(watch.elapsedMilliseconds, lessThan(290));
    });

    test(
      'a cached document that no longer parses is replaced from the network',
      () async {
        await MapDiskCache.storeDocument(
          style.styleUrl,
          Uint8List.fromList(utf8.encode('not json')),
          freshFor: const Duration(hours: 1),
        );
        final loaded = await loadVectorStyle(style);
        expect(loaded.sources.keys, containsAll(['one', 'two']));
        expect(hits['/style.json'], 1);
        // The bad copy was dropped and the good one stored in its place.
        await settle();
        final cached = MapDiskCache.readDocument(style.styleUrl);
        expect(utf8.decode(cached!.bytes), contains('"sources"'));
      },
    );

    test(
      'a credential in the URL does not change the cache identity',
      () async {
        final a = VectorMapStyle(id: 'k', styleUrl: '$base/style.json?key=one');
        final b = VectorMapStyle(id: 'k', styleUrl: '$base/style.json?key=two');
        await loadVectorStyle(a);
        await settle();
        final before = Map.of(hits);
        await loadVectorStyle(b);
        expect(hits, before);
      },
    );
  });
}
