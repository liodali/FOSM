import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/isolate/http_isolate_native.dart';

void main() {
  late HttpServer server;
  late HttpIsolate worker;
  late String base;

  /// Completes when the client closes the connection of a held request.
  final closedByClient = <String, Completer<void>>{};
  var requestsSeen = 0;

  setUp(() async {
    closedByClient.clear();
    requestsSeen = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      requestsSeen++;
      final path = request.uri.path;
      switch (path) {
        case '/slow-headers':
          // Headers 200 ms late, then a short body.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          request.response.add([1, 2, 3]);
          await request.response.close();
        case '/held-headers':
        case '/held-body':
          final socket =
              await request.response.detachSocket(writeHeaders: false);
          final closed = closedByClient[path]!;
          socket.listen((_) {}, onDone: () {
            if (!closed.isCompleted) closed.complete();
          }, onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          });
          if (path == '/held-body') {
            socket.add(('HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\nabc')
                .codeUnits);
            await socket.flush();
          }
        default:
          request.response.add([9, 9]);
          await request.response.close();
      }
    });
    worker = HttpIsolate();
    await worker.spawn();
  });

  tearDown(() async {
    worker.dispose();
    await server.close(force: true);
  });

  test('fetchUrlTimed reports the time to the first byte', () async {
    final result = await worker.fetchUrlTimed('$base/slow-headers');
    expect(result.bytes, [1, 2, 3]);
    expect(result.firstByte, greaterThanOrEqualTo(const Duration(milliseconds: 150)));
    expect(result.firstByte, lessThan(const Duration(seconds: 3)));
  });

  test('cancelling while the server has not answered closes the connection',
      () async {
    closedByClient['/held-headers'] = Completer<void>();
    final handle = HttpFetchHandle();
    final pending = worker.fetchUrlTimed('$base/held-headers', handle: handle);
    final failure = expectLater(
        pending,
        throwsA(isA<TileLoadException>()
            .having((e) => e.kind, 'kind', TileFailureKind.cancelled)));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    handle.cancel();
    await failure;
    await closedByClient['/held-headers']!.future
        .timeout(const Duration(seconds: 2));
  });

  test('cancelling mid-body closes the connection', () async {
    closedByClient['/held-body'] = Completer<void>();
    final handle = HttpFetchHandle();
    final pending = worker.fetchUrlTimed('$base/held-body', handle: handle);
    final failure = expectLater(
        pending,
        throwsA(isA<TileLoadException>()
            .having((e) => e.kind, 'kind', TileFailureKind.cancelled)));
    // Long enough for the headers and the first bytes to have arrived.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(closedByClient['/held-body']!.isCompleted, isFalse);
    handle.cancel();
    await failure;
    await closedByClient['/held-body']!.future
        .timeout(const Duration(seconds: 2));
  });

  test('a handle cancelled before the request never reaches the server',
      () async {
    final handle = HttpFetchHandle()..cancel();
    await expectLater(
        worker.fetchUrlTimed('$base/never', handle: handle),
        throwsA(isA<TileLoadException>()
            .having((e) => e.kind, 'kind', TileFailureKind.cancelled)));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(requestsSeen, 0);
  });

  test('cancelling after the request finished does nothing', () async {
    final handle = HttpFetchHandle();
    expect(await worker.fetchUrl('$base/ok', handle: handle), [9, 9]);
    handle.cancel();
    expect(await worker.fetchUrl('$base/ok'), [9, 9],
        reason: 'the worker is unharmed');
  });

  test('a cancelled request does not disturb its neighbours', () async {
    closedByClient['/held-headers'] = Completer<void>();
    final handle = HttpFetchHandle();
    final held = worker.fetchUrlTimed('$base/held-headers', handle: handle);
    final held2 = expectLater(held, throwsA(isA<TileLoadException>()));
    final neighbours = [
      for (var i = 0; i < 5; i++) worker.fetchUrl('$base/ok?i=$i'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 100));
    handle.cancel();
    await held2;
    for (final bytes in await Future.wait(neighbours)) {
      expect(bytes, [9, 9]);
    }
  });
}
