import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/tile_source.dart';

void main() {
  group('downloadTileBytes', () {
    late HttpServer server;
    late Uint8List servedBytes;

    setUp(() async {
      servedBytes = Uint8List.fromList(List.generate(64, (i) => i));
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.headers.contentType = ContentType(
          'image', 'png',
        );
        request.response.add(servedBytes);
        request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('returns raw bytes from the server', () async {
      // Point downloadTileBytes at our local server instead of OSM.
      final url =
          'http://${server.address.host}:${server.port}/7/67/44.png';
      final bytes = await downloadTileBytes(url);
      expect(bytes, servedBytes);
    });
  });

  group('tileUrl', () {
    test('builds correct OSM URL', () {
      expect(
        tileUrl(7, 67, 44),
        'https://tile.openstreetmap.org/7/67/44.png',
      );
    });

    test('wraps x across antimeridian', () {
      // At z=7, n=128. x=130 should wrap to 2.
      expect(
        tileUrl(7, 130, 44),
        'https://tile.openstreetmap.org/7/2/44.png',
      );
    });

    test('wraps negative x', () {
      // At z=7, n=128. x=-1 should wrap to 127.
      expect(
        tileUrl(7, -1, 44),
        'https://tile.openstreetmap.org/7/127/44.png',
      );
    });
  });
}
