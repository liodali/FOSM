// Standalone payload server for the vector-render baseline benchmark
// (plan .plan/vector_render_improvement/01_baseline_and_attribution.md).
//
// Serves the deterministic synthetic style + MVT payloads (and a raster
// control image) over plain HTTP so the *same* loopback/LAN transport,
// disk cache and deduplication paths run as with a production provider.
//
// Start it before the benchmark app:
//
//   dart run tool/vector_payload_server.dart --host 0.0.0.0 --port 8787
//
// Then run the app with
//   --dart-define=BENCHMARK_VECTOR_BASE=http://<server-ip>:8787
// (and --dart-define=BENCHMARK_MARKER_URL=http://<server-ip>:8787/log
// for browser runs, where app stdout cannot reach the flutter console;
// markers POST to /log and the server appends them to a per-label file
// under --marker-log-dir).
//
// The app never talks to this tool beyond HTTP; payloads are a pure
// function of (z, x, y, profile, seed), so payload identity is the
// generator version + seed (see lib/benchmark/vector_payloads.dart).
//
// Endpoints:
//   GET /style-a.json, /style-b.json   style variants a/b
//   GET /tiles/{z}/{x}/{y}.mvt         synthetic MVT (?profile=|&seed=)
//   GET /raster/{z}/{x}/{y}.png        raster control tile
//   POST /log?label=<label>            benchmark marker sink (browser)
//   GET /healthz                       liveness probe

import 'dart:io';
import 'dart:typed_data';

import 'package:example/benchmark/vector_bench_style.dart';
import 'package:example/benchmark/vector_payloads.dart';

Future<void> main(List<String> arguments) async {
  var host = '127.0.0.1';
  var port = 8787;
  var profile = BenchProfile.denseCity;
  var seed = BenchPayloads.defaultSeed;
  var markerLogDir = '';
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--host':
        host = arguments[++i];
      case '--port':
        port = int.parse(arguments[++i]);
      case '--profile':
        profile = arguments[++i] == 'suburb'
            ? BenchProfile.suburb
            : BenchProfile.denseCity;
      case '--seed':
        seed = int.parse(arguments[++i]);
      case '--marker-log-dir':
        markerLogDir = arguments[++i];
    }
  }

  final cache = <String, Uint8List>{};
  const cacheCapacity = 2048;
  Uint8List cached(String key, Uint8List Function() build) {
    return cache.putIfAbsent(key, () {
      if (cache.length >= cacheCapacity) cache.remove(cache.keys.first);
      return build();
    });
  }

  final raster = _rasterTileBytes();

  final server = await HttpServer.bind(host, port);
  stderr.writeln('vector payload server listening on '
      '${server.address.address}:${server.port} '
      '(payload ${BenchPayloads.identity}, profile ${profile.name}, '
      'seed $seed)');

  await for (final request in server) {
    try {
      final path = request.uri.pathSegments;
      if (request.method == 'OPTIONS') {
        request.response
          ..statusCode = 204
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..headers
              .set('Access-Control-Allow-Headers', request.headers.value(
                      'Access-Control-Request-Headers') ??
                  '*');
        await request.response.close();
        continue;
      }
      if (request.uri.path == '/healthz') {
        request.response
          ..statusCode = 200
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..write('ok');
        await request.response.close();
        continue;
      }
      if (request.uri.path == '/log') {
        // Browser marker sink: the app cannot print to a console worth
        // relaying under flutter_tools' --disable-extensions Chrome, so
        // it POSTs payload lines here; one file per benchmark label.
        final label = request.uri.queryParameters['label'];
        if (markerLogDir.isEmpty ||
            label == null ||
            label.isEmpty ||
            !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(label)) {
          request.response
            ..statusCode = 400
            ..headers.set('Access-Control-Allow-Origin', '*');
          await request.response.close();
          continue;
        }
        final dir = Directory(markerLogDir)..createSync(recursive: true);
        final sink = File('${dir.path}/markers-$label.log')
            .openWrite(mode: FileMode.append);
        final body = await request.fold<List<int>>(
            <int>[], (buffer, chunk) => buffer..addAll(chunk));
        sink.add(body);
        sink.add(const [10]); // separators per POST
        await sink.flush();
        await sink.close();
        request.response
          ..statusCode = 204
          ..headers.set('Access-Control-Allow-Origin', '*');
        await request.response.close();
        continue;
      }

      // Styles advertise the tile template on the host the client used, so
      // the same server works for loopback (desktop) and LAN (device) runs.
      if (path.length == 1 &&
          (path.single == 'style-a.json' || path.single == 'style-b.json')) {
        final variant = path.single == 'style-b.json' ? 'b' : 'a';
        final hostHeader = request.headers.value(HttpHeaders.hostHeader) ??
            '$host:$port';
        final body = cached(
          'style-$variant-$hostHeader',
          () => _bytes(benchStyleJson('http://$hostHeader', variant: variant)),
        );
        await _respond(request, body, 'application/json');
        continue;
      }

      if (path.length == 4) {
        final family = path[0];
        final z = int.tryParse(path[1]);
        final x = int.tryParse(path[2]);
        final y = int.tryParse(path[3].split('.').first);
        if (z != null && x != null && y != null && z >= 0 && z <= 22) {
          final query = request.uri.queryParameters;
          final tileSeed =
              int.tryParse(query['seed'] ?? '') ?? seed;
          final tileProfile = query['profile'] == 'suburb'
              ? BenchProfile.suburb
              : (query['profile'] == 'denseCity'
                  ? BenchProfile.denseCity
                  : profile);
          if (family == 'tiles') {
            await _respond(
                request,
                cached('mvt/$z/$x/$y/$tileProfile.name/$tileSeed',
                    () => BenchPayloads.tile(z, x, y,
                        profile: tileProfile, seed: tileSeed)),
                'application/vnd.mapbox-vector-tile');
            continue;
          }
          if (family == 'raster') {
            await _respond(request, raster, 'image/png');
            continue;
          }
        }
      }

      request.response
        ..statusCode = 404
        ..headers.set('Access-Control-Allow-Origin', '*');
      await request.response.close();
    } catch (error) {
      stderr.writeln('request failed: $error');
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  }
}

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);

Future<void> _respond(
    HttpRequest request, Uint8List body, String contentType) async {
  request.response
    ..statusCode = 200
    ..headers.set(HttpHeaders.contentTypeHeader, contentType)
    ..headers.set('Cache-Control', 'no-store')
    // Browser runs load tiles/styles cross-origin (dwds serves the app
    // from its own port); native clients ignore the header.
    ..headers.set('Access-Control-Allow-Origin', '*')
    ..contentLength = body.length;
  await request.response.addStream(Stream.value(body).cast<List<int>>());
  await request.response.close();
}

/// 256×256 RGB PNG: light background with a darker grid every 32px — the
/// same motif as the raster benchmark tile, encoded here without Flutter.
Uint8List _rasterTileBytes() {
  const size = 256;
  final rows = <int>[];
  void put(int r, int g, int b) {
    rows..add(r)..add(g)..add(b);
  }

  for (var y = 0; y < size; y++) {
    final onGrid = y % 32 == 0;
    for (var x = 0; x < size; x++) {
      if (onGrid || x % 32 == 0) {
        put(0xb0, 0xc5, 0xa9);
      } else {
        put(0xe7, 0xee, 0xe4);
      }
    }
  }

  final raw = BytesBuilder();
  for (var y = 0; y < size; y++) {
    raw.addByte(0); // filter: none
    final rowStart = y * size * 3;
    raw.add(rows.sublist(rowStart, rowStart + size * 3));
  }

  final idat = _zlibCompress(raw.takeBytes());

  final png = BytesBuilder();
  png.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); // signature
  void chunk(String type, List<int> data) {
    final b = BytesBuilder();
    b.add(_uint32(data.length));
    b.add(type.codeUnits);
    b.add(data);
    final crc = _crc32([...type.codeUnits, ...data]);
    b.add(_uint32(crc));
    png.add(b.takeBytes());
  }

  // IHDR: width, height, bit depth 8, colour type 2 (RGB).
  chunk('IHDR', [
    ..._uint32(size),
    ..._uint32(size),
    8,
    2,
    0,
    0,
    0,
  ]);
  chunk('IDAT', idat);
  chunk('IEND', const []);
  return png.takeBytes();
}

Uint8List _zlibCompress(List<int> data) =>
    Uint8List.fromList(ZLibEncoder(level: 6).convert(data));

List<int> _uint32(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return crc ^ 0xffffffff;
}
