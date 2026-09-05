import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fosm/src/vector/mvt/vector_tile.dart';

/// Persistent MVT decode isolate (native implementation).
///
/// Spawns a single long-lived isolate that decodes MVT bytes into
/// [DecodedVectorTile]s. This replaces the per-tile `compute()` spawn
/// that initialized a fresh isolate for every tile — the profiled
/// baseline showed ≈81 isolate initializations for an 80-tile load.
///
/// The response ([DecodedVectorTile]) is a plain-data object graph
/// (lists, maps, ints, strings) so it is deep-copied across the isolate
/// boundary, exactly as `compute()` already does.
///
/// Protocol (main → isolate): `[SendPort replyPort, Uint8List bytes]`
/// Protocol (isolate → main): `DecodedVectorTile` on success, `String`
/// on error.
///
/// Input bytes are sent via a normal [SendPort.send] (copy) rather than
/// [TransferableTypedData] because the same byte buffer is retained by
/// [TileManager]'s byte cache, and transferring it would invalidate that
/// reference.
class MvtIsolate {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  bool _ready = false;

  /// Guards against concurrent spawn() calls.
  Future<void>? _spawnFuture;

  bool get isReady => _ready;

  /// Spawns the background isolate and waits for the handshake.
  Future<void> spawn() => _spawnFuture ??= _doSpawn();

  Future<void> _doSpawn() async {
    if (_ready) return;

    _receivePort = ReceivePort();
    final completer = Completer<SendPort>();
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _ready = true;
        if (!completer.isCompleted) completer.complete(message);
      }
    });

    _isolate = await Isolate.spawn(_entryPoint, _receivePort!.sendPort);
    await completer.future;
  }

  /// Decodes [bytes] on the background isolate and returns the parsed
  /// tile. Each call uses a one-shot [ReceivePort] for its reply,
  /// matching the [HttpIsolate] pattern.
  Future<DecodedVectorTile> decode(Uint8List bytes) {
    if (!_ready) {
      throw StateError('MvtIsolate not ready — call spawn() first');
    }
    final responsePort = ReceivePort();
    _sendPort!.send([responsePort.sendPort, bytes]);
    return responsePort.first.then((response) {
      responsePort.close();
      if (response is DecodedVectorTile) return response;
      throw response is String ? response : 'Unknown error';
    });
  }

  /// Kills the isolate and cleans up ports. Safe to call multiple times.
  void dispose() {
    _ready = false;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _spawnFuture = null;
  }

  // ── Isolate entry point (runs on the background thread) ─────────────

  static void _entryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
      final parts = message as List;
      final replyPort = parts[0] as SendPort;
      final bytes = parts[1] as Uint8List;

      try {
        replyPort.send(decodeVectorTile(bytes));
      } catch (e) {
        replyPort.send(e.toString());
      }
    });
  }
}
