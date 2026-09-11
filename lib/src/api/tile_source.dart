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

/// Builds the canonical source identity of a *logical* tile.
///
/// Two logical tiles that map to the same identity (wrapped X across the
/// antimeridian, or several over-zoom children reading one ancestor source
/// tile) share a single network request and a single stored source-byte
/// record. The decoded image still differs per logical tile, because the
/// renderer projects each child into its own sub-rect.
///
/// The first job to request a resource supplies the coordinates the fetcher
/// sees, so a builder that collapses over-zoom siblings must be paired with a
/// fetcher that resolves those coordinates to the same URL.
typedef TileResourceKeyBuilder = String Function(int z, int x, int y);

/// Thrown by a [TileDecoder] when it aborts because the tile became
/// irrelevant before an expensive stage (parse/render/`toImage`).
///
/// This is not a failure: callers must not back off or retry, and any
/// already-fetched bytes should be retained for a future pan.
class TileDecodeAborted implements Exception {
  const TileDecodeAborted();
}

/// Thrown by a [TileDecoder] when the supplied bytes are malformed and can
/// never produce an image (corrupt cache entry, truncated download, invalid
/// protobuf, …).
///
/// Callers use this to invalidate the corresponding cache/disk entry and
/// recover from the network. Decoder failures that are *not* this type are
/// treated as transient — the same bytes are kept and retried after backoff
/// instead of being deleted and refetched, because a style/render/runtime
/// error says nothing about the payload.
class TilePayloadException implements Exception {
  const TilePayloadException([this.message]);

  final String? message;

  @override
  String toString() => message == null
      ? 'TilePayloadException'
      : 'TilePayloadException: $message';
}

// Shared Dio — reused within a single isolate. Inside [compute] a fresh
// isolate is spawned per call, so the cache is per-request there, but on
// Web (same isolate) it saves connection setup cost.
Dio? _sharedDio;

Dio get _dio => _sharedDio ??= Dio(BaseOptions(
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

/// Default [TileFetcher]: downloads from OpenStreetMap. Used as fallback
/// on web where isolates aren't available. On native, [TileManager] uses
/// the persistent HTTP isolate instead (better TCP connection reuse).
Future<Uint8List> osmTileFetcher(int z, int x, int y) {
  return downloadTileBytes(tileUrl(z, x, y));
}
