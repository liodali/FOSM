import 'package:flutter/foundation.dart';

import '../vector/mvt/vector_tile.dart';

/// Decodes raw MVT bytes into a [DecodedVectorTile] using `compute()`.
///
/// - **Native** (iOS/Android/macOS/Linux): `compute()` spawns a real
///   isolate on a background thread — protobuf parsing never touches
///   the main thread.
/// - **Web**: `compute()` runs on the same thread (Dart isolates aren't
///   supported on web), but the caller already yields between decode
///   stages in [VectorTileRuntime], so the UI stays responsive.
///
/// This replaces the previous JS Web Worker approach — no duplicated
/// protobuf code, no JS interop, no Blob URLs. The Dart [decodeVectorTile]
/// is pure Dart with no `dart:ui` dependency, so it works everywhere.
Future<DecodedVectorTile> decodeMvtAsync(Uint8List bytes) async {
  return compute(decodeVectorTile, bytes);
}

/// Whether `compute()` runs on a separate OS thread.
/// `true` on native, `false` on web.
bool get isMvtDecodeThreaded => !kIsWeb;
