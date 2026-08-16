import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Fetches raw image bytes for a single map tile.
///
/// The signature is intentionally injectable so apps can plug in custom tile
/// servers (Mapbox, Esri, self-hosted, etc.) and so tests can stub the
/// network layer.
typedef TileFetcher = Future<Uint8List> Function(int z, int x, int y);

/// Turns fetched tile bytes into a displayable image.
///
/// Raster tiles decode via an image codec; vector tiles run the
/// parse → style → rasterize pipeline. Injectable so the vector runtime can
/// replace it and tests can stub decoding.
typedef TileDecoder = Future<ui.Image> Function(
  Uint8List bytes,
  int z,
  int x,
  int y,
);

// Shared Dio — reused within a single isolate. Inside [compute] a fresh
// isolate is spawned per call, so the cache is per-request there, but on
// Web (same isolate) it saves connection setup cost.
Dio? _sharedDio;

Dio get _dio =>
    _sharedDio ??= Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: const {
        'User-Agent': 'fosm/0.0.1 (Flutter OSM map; +https://github.com/fosm)',
      },
    ));

/// Low-level download: fetches [url] as raw bytes. Throws [DioException] on
/// any non-2xx status, so the caller can distinguish "tile not found" from
/// "server error" instead of silently decoding garbage.
Future<Uint8List> downloadTileBytes(String url) async {
  final response = await _dio.get<List<int>>(
    url,
    options: Options(responseType: ResponseType.bytes),
  );
  return Uint8List.fromList(response.data!);
}

/// Builds the canonical OSM tile URL for ([z], [x], [y]).
/// [x] is wrapped to [0, 2^z) so panning past the antimeridian still
/// resolves to valid tiles.
String tileUrl(int z, int x, int y) {
  final n = 1 << z;
  final wrappedX = ((x % n) + n) % n;
  return 'https://tile.openstreetmap.org/$z/$wrappedX/$y.png';
}

/// Default [TileFetcher]: downloads from OpenStreetMap inside an isolate
/// ([compute]) so the main thread is never blocked by network/decode work.
Future<Uint8List> osmTileFetcher(int z, int x, int y) {
  return compute(downloadTileBytes, tileUrl(z, x, y));
}
