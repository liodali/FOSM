import 'dart:ui' as ui;
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fosm/src/api/map_load_state.dart';
import 'package:fosm/src/isolate/http_fetch.dart';

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

/// Owns active Dio requests without letting one request's timeout cancel its
/// siblings or later retries. Completed requests are removed immediately.
class MapRequestSession {
  final Set<CancelToken> _requests = {};
  bool _cancelled = false;
  void add(CancelToken token) {
    if (_cancelled) {
      token.cancel('Map disposed');
    } else {
      _requests.add(token);
    }
  }

  void remove(CancelToken token) => _requests.remove(token);
  void cancel([Object? reason]) {
    _cancelled = true;
    for (final token in _requests.toList()) {
      token.cancel(reason);
    }
    _requests.clear();
  }
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

/// A downloaded document and how long its server says it stays fresh.
class FetchedDocument {
  const FetchedDocument(this.bytes, this.freshFor);

  final Uint8List bytes;

  /// Remaining freshness from `Cache-Control: max-age` less the `Age` a CDN
  /// reports. Zero when the server asks for revalidation (`no-store`,
  /// `no-cache`, `max-age=0`) or sends no usable directive.
  final Duration freshFor;
}

/// Remaining freshness announced by response headers. Only `max-age` is
/// honoured; every other case reads as not fresh so a document is revalidated
/// exactly as before.
@visibleForTesting
Duration freshnessFromHeaders({String? cacheControl, String? age}) {
  if (cacheControl == null) return Duration.zero;
  int? maxAge;
  for (final raw in cacheControl.split(',')) {
    final directive = raw.trim().toLowerCase();
    if (directive == 'no-store' || directive == 'no-cache') {
      return Duration.zero;
    }
    if (directive.startsWith('max-age=')) {
      maxAge = int.tryParse(directive.substring(8).replaceAll('"', ''));
    }
  }
  if (maxAge == null || maxAge <= 0) return Duration.zero;
  final elapsed = int.tryParse(age?.trim() ?? '') ?? 0;
  final remaining = maxAge - (elapsed < 0 ? 0 : elapsed);
  return remaining <= 0 ? Duration.zero : Duration(seconds: remaining);
}

/// Downloads bytes with a deadline covering connection, headers, and body.
/// Throws [TileLoadException] rather than leaking transport-specific errors.
Future<Uint8List> downloadTileBytes(
  String url, {
  Duration requestTimeout = TileLoadException.defaultRequestTimeout,
  MapRequestSession? requestSession,
  HttpFetchHandle? handle,
}) async =>
    (await downloadDocument(
      url,
      requestTimeout: requestTimeout,
      requestSession: requestSession,
      handle: handle,
    ))
        .bytes;

/// [downloadTileBytes] that also reports the response's freshness.
Future<FetchedDocument> downloadDocument(
  String url, {
  Duration requestTimeout = TileLoadException.defaultRequestTimeout,
  MapRequestSession? requestSession,
  HttpFetchHandle? handle,
}) async {
  validateRequestTimeout(requestTimeout);
  final cancel = CancelToken();
  requestSession?.add(cancel);
  handle?.attach(() => cancel.cancel('Request no longer needed'));
  try {
    final response = await _dio
        .get<List<int>>(
      url,
      cancelToken: cancel,
      options: Options(responseType: ResponseType.bytes),
    )
        .timeout(requestTimeout, onTimeout: () {
      cancel.cancel('Map request deadline exceeded');
      throw const TileLoadException(
          TileFailureKind.timeout, 'Map request timed out');
    });
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw TileLoadException(TileFailureKind.http,
          'Map server rejected the request',
          statusCode: response.statusCode);
    }
    return FetchedDocument(
      Uint8List.fromList(bytes),
      freshnessFromHeaders(
        cacheControl: _joinedHeader(response.headers, 'cache-control'),
        age: _joinedHeader(response.headers, 'age'),
      ),
    );
  } on DioException catch (error) {
    final kind = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        TileFailureKind.timeout,
      DioExceptionType.badResponse => TileFailureKind.http,
      DioExceptionType.cancel => TileFailureKind.cancelled,
      _ => TileFailureKind.network,
    };
    throw TileLoadException(
        kind,
        switch (kind) {
          TileFailureKind.timeout => 'Map request timed out',
          TileFailureKind.http => 'Map server rejected the request',
          TileFailureKind.cancelled => 'Map request cancelled',
          _ => 'Unable to download map data',
        },
        statusCode: error.response?.statusCode,
        cause: error);
  } catch (error) {
    throw TileLoadException.from(error);
  } finally {
    handle?.detach();
    requestSession?.remove(cancel);
  }
}

/// Joins every value a response carries for [name]: servers may repeat a
/// header — Cloudflare currently answers OpenFreeMap documents with
/// `cache-control: max-age=…` next to its own `cache-control: public` — and
/// dio's [Headers.value] throws on those. Joined values parse the same way:
/// [freshnessFromHeaders] splits directives on commas.
String? _joinedHeader(Headers headers, String name) {
  final values = headers[name];
  if (values == null || values.isEmpty) return null;
  return values.join(', ');
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
