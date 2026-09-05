import 'package:flutter/foundation.dart';

import '../vector/mvt/vector_tile.dart';

/// Decodes raw MVT bytes into a [DecodedVectorTile].
///
/// - **Native** (iOS/Android/macOS/Linux): `compute()` spawns a real
///   isolate on a background thread — protobuf parsing never touches
///   the main thread.
/// - **Web**: decoding runs on the main thread, restricted to style-used
///   layers and cooperatively yielding between layer messages.
///
/// When [useIsolate] is false, parsing runs synchronously on the
/// current thread. Used in tests where the Flutter test framework
/// doesn't drain isolate messages properly.
Future<DecodedVectorTile> decodeMvtAsync(
  Uint8List bytes, {
  bool useIsolate = true,
  Set<String>? sourceLayers,
}) async {
  if (!useIsolate) {
    return decodeVectorTile(bytes, sourceLayers: sourceLayers);
  }
  if (kIsWeb) {
    return decodeVectorTileAsync(bytes, sourceLayers: sourceLayers);
  }
  return compute(
    decodeMvtRequest,
    MvtDecodeRequest(bytes, sourceLayers),
  );
}

/// Whether MVT decoding runs on a separate OS thread.
/// `true` on native, `false` on web.
bool get isMvtDecodeThreaded => !kIsWeb;
