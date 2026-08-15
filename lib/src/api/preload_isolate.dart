// Stub fallback — only parsed when neither dart.library.io nor
// dart.library.js_interop is available (shouldn't happen in practice).
// The real implementations live in preload_isolate_native.dart and
// preload_isolate_web.dart, selected via conditional import.

import 'dart:async';
import 'dart:typed_data';

/// Web/wasm no-op implementation (also used as stub fallback).
///
/// On web, isolates aren't available. [spawn] is a no-op and [isReady]
/// always returns `false`, so the tile manager falls back to the regular
/// async fetcher path (which uses the browser's fetch API on web).
class PreloadIsolateImpl {
  bool get isReady => false;

  Future<void> spawn() async {}

  Future<Uint8List> fetch(int z, int x, int y) {
    throw UnsupportedError('PreloadIsolate is not supported on this platform');
  }

  void dispose() {}
}
