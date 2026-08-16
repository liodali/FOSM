import 'package:flutter/foundation.dart';

import '../vector/mvt/vector_tile.dart';

/// Decodes raw MVT bytes into a [DecodedVectorTile].
///
/// - **Native** (iOS/Android/macOS/Linux): `compute()` spawns a real
///   isolate on a background thread — protobuf parsing never touches
///   the main thread.
/// - **Web**: `compute()` runs on the same thread (Dart isolates aren't
///   supported on web), but the caller already yields between decode
///   stages in [VectorTileRuntime], so the UI stays responsive.
///
/// When [useIsolate] is false, parsing runs synchronously on the
/// current thread. Used in tests where the Flutter test framework
/// doesn't drain isolate messages properly.
Future<DecodedVectorTile> decodeMvtAsync(Uint8List bytes, {bool useIsolate = true}) async {
  if (!useIsolate) return decodeVectorTile(bytes);
  return compute(decodeVectorTile, bytes);
}

/// Whether MVT decoding runs on a separate OS thread.
/// `true` on native, `false` on web.
bool get isMvtDecodeThreaded => !kIsWeb;
