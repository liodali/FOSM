import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/isolate/http_isolate_native.dart';

void main() {
  late HttpServer server;
  late HttpIsolate worker;
  late String base;

  // Client port of the connection every request arrived on.
  final headPorts = <int>[];
  final getPorts = <int>[];
  final connections = <int>{};

  setUp(() async {
    headPorts.clear();
    getPorts.clear();
    connections.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final port = request.connectionInfo!.remotePort;
      connections.add(port);
      (request.method == 'HEAD' ? headPorts : getPorts).add(port);
      // A tile takes a moment, so concurrent requests need their own socket.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (request.method != 'HEAD') request.response.add([1, 2, 3]);
      await request.response.close();
    });
    worker = HttpIsolate();
  });

  tearDown(() async {
    worker.dispose();
    await server.close(force: true);
  });

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('warmUp opens the requested number of connections', () async {
    await worker.warmUp('$base/12/1/2.pbf', connections: 4);
    await until(() => headPorts.length >= 4);
    expect(headPorts.toSet(), hasLength(4));
  });

  test('a first wave of tiles reuses the warmed connections', () async {
    await worker.warmUp('$base/12/1/2.pbf', connections: 4);
    await until(() => headPorts.length >= 4);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await Future.wait([
      for (var i = 0; i < 4; i++) worker.fetchUrl('$base/12/$i/2.pbf'),
    ]);

    expect(getPorts, hasLength(4));
    expect(headPorts.toSet().containsAll(getPorts), isTrue,
        reason: 'no tile request needed a new connection');
    expect(connections, hasLength(4));
  });

  test('without a warm-up the same wave opens its own connections', () async {
    await worker.spawn();
    await Future.wait([
      for (var i = 0; i < 4; i++) worker.fetchUrl('$base/12/$i/2.pbf'),
    ]);
    expect(headPorts, isEmpty);
    expect(connections, hasLength(4));
  });

  test('warmUp starts the worker when it is not running yet', () async {
    expect(worker.isReady, isFalse);
    await worker.warmUp('$base/12/1/2.pbf', connections: 1);
    expect(worker.isReady, isTrue);
  });

  test('warmUp never throws: bad URL, dead host, disposed worker', () async {
    await worker.warmUp('not a url', connections: 2);
    await worker.warmUp('http://127.0.0.1:1/x', connections: 2);
    await worker.warmUp('$base/x', connections: 0);
    worker.dispose();
    await worker.warmUp('$base/x');
  });
}
