// Stub fallback — only parsed when neither dart.library.io nor
// dart.library.js_interop is available.

import 'dart:typed_data';
import 'package:fosm/src/api/map_load_state.dart';
import 'package:fosm/src/isolate/http_fetch.dart';

export 'package:fosm/src/isolate/http_fetch.dart';

/// Persistent HTTP isolate for tile downloads.
///
/// On native: spawns a long-lived isolate with a persistent HttpClient
/// so TCP connections are reused across hundreds of requests.
/// On web: [isReady] is always false — callers fall back to the regular
/// async Dio fetcher (browser fetch API handles connection pooling).
class HttpIsolate {
  bool get isReady => false;

  bool get isStarting => false;

  Future<void> spawn() async {}

  /// Opens connections ahead of the first request. No-op here.
  Future<void> warmUp(String url, {int connections = 6}) async {}

  /// Fetches [url] and returns the raw bytes.
  Future<Uint8List> fetchUrl(
    String url, {
    Duration requestTimeout = TileLoadException.defaultRequestTimeout,
    HttpFetchHandle? handle,
  }) {
    throw UnsupportedError('HttpIsolate is not available on this platform');
  }

  /// Fetches [url] and reports the time to the first byte.
  Future<HttpFetchResult> fetchUrlTimed(
    String url, {
    Duration requestTimeout = TileLoadException.defaultRequestTimeout,
    HttpFetchHandle? handle,
  }) {
    throw UnsupportedError('HttpIsolate is not available on this platform');
  }

  void dispose() {}
}
