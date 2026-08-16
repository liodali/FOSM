import 'package:flutter/foundation.dart';


import '../vector/mvt/vector_tile.dart';

/// Decodes MVT bytes in a separate isolate via [compute].
/// The protobuf decoder is pure Dart (no `dart:ui`), so it transfers
/// cleanly across isolate boundaries.
Future<DecodedVectorTile> decodeMvtAsync(Uint8List bytes) async {
  return compute(decodeVectorTile, bytes);
}

/// Native `compute()` always runs on a separate thread.
bool get isMvtDecodeThreaded => true;
