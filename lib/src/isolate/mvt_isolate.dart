// Stub fallback — only parsed when dart.library.io is not available
// (i.e. web). Browser isolates have different constraints, so MVT
// decoding stays on the main event loop there and the caller yields
// between decode stages (see [VectorTileRuntime]).

import 'dart:typed_data';

import 'package:fosm/src/vector/mvt/vector_tile.dart';

/// Persistent MVT decode isolate.
///
/// On native: spawns a long-lived isolate that decodes MVT bytes so the
/// per-tile `compute()` spawn churn (≈81 isolate initializations for an
/// 80-tile load) is eliminated. On web: [isReady] is always `false` and
/// callers fall back to synchronous [decodeVectorTile] on the main
/// thread.
class MvtIsolate {
  bool get isReady => false;

  Future<void> spawn() async {}

  /// Decodes [bytes] into a [DecodedVectorTile] on the background
  /// isolate. Throws if the isolate is not ready.
  Future<DecodedVectorTile> decode(Uint8List bytes) {
    throw UnsupportedError('MvtIsolate is not available on this platform');
  }

  void dispose() {}
}
