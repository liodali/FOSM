import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/map_load_state.dart'
    show TileFailureKind, TileLoadException;
import 'package:fosm/src/api/tile_source.dart' show downloadDocument;

void main() {
  test(
      'downloadDocument accepts repeated cache-control headers '
      '(OpenFreeMap serves max-age and public as two lines)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final served = Completer<void>();
    late final HttpServer bound = server;
    server.listen((request) async {
      // Two separate header lines with the same name — what dart:io turns
      // into a multi-valued header, and what dio's Headers.value throws on.
      request.response.headers.add('cache-control', 'max-age=86400');
      request.response.headers.add('cache-control', 'public');
      request.response.headers.add('age', '120');
      request.response.add(
          Uint8List.fromList('{"version":8,"sources":{}}'.codeUnits));
      await request.response.close();
      if (!served.isCompleted) served.complete();
    });

    try {
      final doc = await downloadDocument(
          'http://127.0.0.1:${bound.port}/styles/liberty');
      expect(doc.bytes, isNotEmpty);
      // max-age=86400 less the Age header, joining 'public' harmlessly.
      expect(doc.freshFor, const Duration(seconds: 86400 - 120));
    } finally {
      await served.future;
      await server.close(force: true);
    }
  });

  test('a bodyless 200 reports an http failure, not a crash', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final served = Completer<void>();
    server.listen((request) async {
      request.response.statusCode = 204;
      await request.response.close();
      if (!served.isCompleted) served.complete();
    });
    try {
      await expectLater(
        downloadDocument('http://127.0.0.1:${server.port}/empty'),
        throwsA(isA<TileLoadException>()
            .having((e) => e.kind, 'kind', TileFailureKind.http)),
      );
    } finally {
      await served.future;
      await server.close(force: true);
    }
  });

  test('wrapped failures carry their cause for diagnostics', () {
    final error = TileLoadException.from(StateError('something broke underneath'),
        fallback: TileFailureKind.style);
    expect(error.cause, isA<StateError>());
    expect(error.toString(), contains('StateError'));
  });
}
