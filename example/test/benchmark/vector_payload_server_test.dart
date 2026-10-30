import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:example/benchmark/vector_payloads.dart';

void main() {
  late Process server;
  late Uri base;
  final client = HttpClient();
  final markerDir = Directory.systemTemp
      .createTempSync('marker-sink-test')
      .path;

  setUpAll(() async {
    // Reserve an ephemeral port, release it, and hand it to the server.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    server = await Process.start('dart', [
      'run',
      'tool/vector_payload_server.dart',
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
      '--marker-log-dir',
      markerDir,
    ]);
    base = Uri.parse('http://127.0.0.1:$port');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final request = await client.getUrl(base.resolve('/healthz'));
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode == 200) return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    fail('payload server did not come up');
  });

  tearDownAll(() async {
    client.close(force: true);
    server.kill();
    await server.exitCode;
    Directory(markerDir).deleteSync(recursive: true);
  });

  Future<(HttpClientResponse, List<int>)> get(String path) async {
    final request = await client.getUrl(base.resolve(path));
    final response = await request.close();
    final bytes =
        await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return (response, bytes);
  }

  group('vector payload server', () {
    test('/log sink appends posted payloads per label', () async {
      // The browser capture relies on the app POSTing whole payload
      // lines: marker files must accumulate in posted order and reject
      // unsafe labels.
      Future<HttpClientResponse> postLog(String label, String body) async {
        final request = await client
            .postUrl(base.resolve('/log?label=$label'));
        request.add(utf8.encode(body));
        await request.flush();
        return request.close();
      }

      final first =
          await postLog('r1', 'FOSM_BENCHMARK_META {"label":"r1"}');
      final second = await postLog(
          'r1', 'FOSM_BENCHMARK_RESULT {"label":"r1","valid":true}');
      expect(first.statusCode, 204);
      expect(second.statusCode, 204);
      final bad = await postLog('../escape', 'nope');
      expect(bad.statusCode, 400);
      final file = File('$markerDir/markers-r1.log');
      final text = file.readAsStringSync();
      expect(text.contains('FOSM_BENCHMARK_META {"label":"r1"}'), isTrue);
      expect(
          text.contains('FOSM_BENCHMARK_RESULT {"label":"r1","valid":true}'),
          isTrue);
      expect(File('$markerDir/markers-escape.log').existsSync(), isFalse);
    });

    test('styles advertise the tile template on the request host',
        () async {
      final (response, bytes) = await get('/style-a.json');
      expect(response.statusCode, 200);
      final style =
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final tiles = (style['sources'] as Map)['bench']
          as Map<String, dynamic>;
      expect((tiles['tiles'] as List).single,
          'http://127.0.0.1:${base.port}/tiles/{z}/{x}/{y}.mvt');
    });

    test('serves byte-identical deterministic tiles', () async {
      final (response, bytes) = await get('/tiles/14/8600/5740.mvt');
      expect(response.statusCode, 200);
      final expected = BenchPayloads.tile(14, 8600, 5740);
      expect(bytes, equals(expected));
    });

    test('seed and profile query parameters change the payload', () async {
      final (_, defaultBytes) = await get('/tiles/14/8600/5740.mvt');
      final (_, seeded) =
          await get('/tiles/14/8600/5740.mvt?seed=42');
      final (_, suburb) =
          await get('/tiles/14/8600/5740.mvt?profile=suburb');
      expect(seeded, isNot(equals(defaultBytes)));
      expect(suburb,
          equals(BenchPayloads.tile(14, 8600, 5740,
              profile: BenchProfile.suburb)));
    });

    test('raster control tile is a valid PNG', () async {
      final (response, bytes) = await get('/raster/10/512/340.png');
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'image/png');
      // PNG signature.
      expect(bytes.sublist(0, 8),
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      // IHDR declares 256×256.
      expect(bytes.sublist(16, 20), [0, 0, 1, 0]);
      expect(bytes.sublist(20, 24), [0, 0, 1, 0]);
    });

    test('unknown paths are 404', () async {
      final (response, _) = await get('/nope.json');
      expect(response.statusCode, 404);
    });
  });
}
