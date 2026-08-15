import 'dart:async';
import 'dart:typed_data';

/// Web/wasm no-op implementation.
///
/// Isolates aren't available on web. [spawn] is a no-op and [isReady]
/// always returns `false`, so the tile manager falls back to the regular
/// async fetcher path (which uses the browser's fetch API on web).
class PreloadIsolateImpl {
  bool get isReady => false;

  Future<void> spawn() async {}

  Future<Uint8List> fetch(int z, int x, int y) {
    throw UnsupportedError('PreloadIsolate is not supported on web');
  }

  void dispose() {}
}
