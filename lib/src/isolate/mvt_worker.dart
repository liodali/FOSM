// Stub fallback — only parsed when neither dart.library.io nor
// dart.library.js_interop is available (shouldn't happen in practice).
// The real implementations live in mvt_worker_native.dart and
// mvt_worker_web.dart, selected via conditional import.

import 'dart:typed_data';

import '../vector/mvt/vector_tile.dart';

/// Decodes raw MVT bytes into a [DecodedVectorTile].
///
/// On native: uses `compute()` to parse in a separate isolate.
/// On web: uses a JavaScript Web Worker to parse off the main thread.
/// On stub: parses synchronously on the current thread.
Future<DecodedVectorTile> decodeMvtAsync(Uint8List bytes) async {
  return decodeVectorTile(bytes);
}

/// Whether async MVT decoding runs on a separate thread (isolate or
/// Web Worker) rather than the main thread.
bool get isMvtDecodeThreaded => false;
