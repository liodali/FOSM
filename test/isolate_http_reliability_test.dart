import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_source.dart'
    show downloadTileBytes, MapRequestSession;
import 'package:fosm/src/isolate/http_isolate_native.dart';

void main() {
  late HttpServer server;
  late HttpIsolate worker;
  late String base;
  final timers = <Timer>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) {
      switch (request.uri.path) {
        case '/headers':
          break; // Intentionally never send headers.
        case '/body':
          request.response.add([1]);
          request.response.flush().ignore(); // Never finish the body.
        case '/trickle':
          timers.add(Timer.periodic(const Duration(milliseconds: 20), (_) {
            request.response.add([1]);
            request.response.flush().ignore();
          }));
        case '/missing':
          request.response.statusCode = 404;
          request.response.close().ignore();
        default:
          request.response.add([1, 2, 3]);
          request.response.close().ignore();
      }
    });
    worker = HttpIsolate();
    await worker.spawn();
  });

  tearDown(() async {
    for (final timer in timers) {
      timer.cancel();
    }
    timers.clear();
    worker.dispose();
    await server.close(force: true);
  });

  test('worker returns bytes and typed status without exposing URL secrets',
      () async {
    expect(await worker.fetchUrl('$base/ok'), [1, 2, 3]);
    try {
      await worker.fetchUrl('$base/missing?token=secret');
      fail('Expected HTTP failure');
    } on TileLoadException catch (error) {
      expect(error.kind, TileFailureKind.http);
      expect(error.statusCode, 404);
      expect(error.isRetryable, isFalse);
      expect(error.toString(), isNot(contains('secret')));
    }
    expect(await worker.fetchUrl('$base/ok'), [1, 2, 3]);
  });

  for (final path in ['headers', 'body', 'trickle']) {
    test('worker bounds the complete $path request and remains usable',
        () async {
      await expectLater(
          worker.fetchUrl('$base/$path',
              requestTimeout: const Duration(milliseconds: 150)),
          throwsA(isA<TileLoadException>()
              .having((error) => error.kind, 'kind', TileFailureKind.timeout)));
      expect(await worker.fetchUrl('$base/ok'), [1, 2, 3]);
    });
  }

  test('disposing settles outstanding reply futures', () async {
    final pending = worker.fetchUrl('$base/headers');
    final check = expectLater(
        pending,
        throwsA(isA<TileLoadException>()
            .having((error) => error.kind, 'kind', TileFailureKind.cancelled)));
    worker.dispose();
    await check;
    expect(worker.isReady, isFalse);
    worker.dispose();
  });

  test('disposing during startup settles the handshake', () async {
    final starting = HttpIsolate();
    final check = expectLater(
        starting.spawn(),
        throwsA(isA<TileLoadException>()
            .having((error) => error.kind, 'kind', TileFailureKind.cancelled)));
    starting.dispose();
    await check;
    expect(starting.isReady, isFalse);
  });

  test('Dio transport has the same typed status and absolute body deadline',
      () async {
    final session = MapRequestSession();
    await expectLater(
        downloadTileBytes('$base/missing'),
        throwsA(isA<TileLoadException>()
            .having((error) => error.statusCode, 'statusCode', 404)));
    await expectLater(
        downloadTileBytes('$base/trickle',
            requestTimeout: const Duration(milliseconds: 150),
            requestSession: session),
        throwsA(isA<TileLoadException>()
            .having((error) => error.kind, 'kind', TileFailureKind.timeout)));
    expect(await downloadTileBytes('$base/ok', requestSession: session),
        [1, 2, 3]);
    final pending = downloadTileBytes('$base/headers', requestSession: session);
    final check = expectLater(
        pending,
        throwsA(isA<TileLoadException>()
            .having((error) => error.kind, 'kind', TileFailureKind.cancelled)));
    session.cancel();
    await check;
  });
}
