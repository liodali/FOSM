// Stub fallback — only parsed when neither dart.library.io nor
// dart.library.js_interop is available.

import 'dart:typed_data';

/// Persistent HTTP isolate for tile downloads.
///
/// On native: spawns a long-lived isolate with a persistent HttpClient
/// so TCP connections are reused across hundreds of requests.
/// On web: [isReady] is always false — callers fall back to the regular
/// async Dio fetcher (browser fetch API handles connection pooling).
class HttpIsolate {
  bool get isReady => false;

  Future<void> spawn() async {}

  /// Fetches [url] and returns the raw bytes.
  Future<Uint8List> fetchUrl(String url) {
    throw UnsupportedError('HttpIsolate is not available on this platform');
  }

  void dispose() {}
}
