import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/render/vector_trace.dart';

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
/// Protocol (main → isolate):
/// `[SendPort replyPort, Uint8List bytes, Set<String>? sourceLayers]`
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

  /// Completes the spawn handshake. [dispose] may run before the worker
  /// sends its [SendPort]; without failing this completer the returned
  /// [spawn] future — and everything awaiting it — would hang forever.
  Completer<SendPort>? _handshake;

  /// Outstanding decodes by their reply port. [dispose] kills the worker,
  /// so their replies can never arrive — each is completed with
  /// [VectorTileCancelled] and its port closed instead of hanging forever.
  final Map<ReceivePort, Completer<DecodedVectorTile>> _pending = {};

  bool get isReady => _ready;

  /// Spawns the background isolate and waits for the handshake.
  Future<void> spawn() => _spawnFuture ??= _doSpawn();

  Future<void> _doSpawn() async {
    if (_ready) return;

    _receivePort = ReceivePort();
    final handshake = Completer<SendPort>();
    _handshake = handshake;
    // Keep an error handler attached from creation: dispose may complete
    // the handshake with an error while this routine is still suspended
    // at `await Isolate.spawn`, and a transiently listener-less errored
    // future is reported as unhandled even though the await below
    // receives it on the next event turn.
    handshake.future.ignore();
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _ready = true;
        if (!handshake.isCompleted) handshake.complete(message);
      }
    });

    try {
      _isolate = await Isolate.spawn(_entryPoint, _receivePort!.sendPort);
      await handshake.future;
    } catch (_) {
      // A failed spawn (or one aborted by dispose) must not pin
      // _spawnFuture: clear it so a later spawn() can retry.
      _spawnFuture = null;
      rethrow;
    } finally {
      if (identical(_handshake, handshake)) _handshake = null;
    }
  }

  /// Decodes [bytes] on the background isolate and returns the parsed
  /// tile. Each call uses a one-shot [ReceivePort] for its reply,
  /// matching the [HttpIsolate] pattern. The future completes with
  /// [VectorTileCancelled] when [dispose] runs before the reply lands.
  Future<DecodedVectorTile> decode(
    Uint8List bytes, {
    Set<String>? sourceLayers,
  }) {
    if (!_ready) {
      throw StateError('MvtIsolate not ready — call spawn() first');
    }
    final responsePort = ReceivePort();
    final completer = Completer<DecodedVectorTile>();
    _pending[responsePort] = completer;
    responsePort.listen((response) {
      _pending.remove(responsePort);
      responsePort.close();
      if (completer.isCompleted) return;
      if (response is DecodedVectorTile) {
        completer.complete(response);
      } else {
        completer
            .completeError(response is String ? response : 'Unknown error');
      }
    });
    VectorTrace.sync('parseDispatch',
        () => _sendPort!.send([responsePort.sendPort, bytes, sourceLayers]));
    return completer.future;
  }

  /// Kills the isolate and cleans up ports. Safe to call multiple times.
  /// Outstanding decodes complete with [VectorTileCancelled] — the worker
  /// is dead, so waiting for their replies would hang the callers (and the
  /// runtime's parse bookkeeping) forever.
  void dispose() {
    _ready = false;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _spawnFuture = null;
    // A spawn aborted mid-handshake can never complete: fail it so
    // spawn()'s future (and its awaiters) unwind instead of hanging.
    final handshake = _handshake;
    _handshake = null;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(StateError('MvtIsolate disposed during spawn'));
    }
    final pending = Map.of(_pending);
    _pending.clear();
    for (final entry in pending.entries) {
      entry.key.close();
      if (!entry.value.isCompleted) {
        entry.value.completeError(const VectorTileCancelled());
      }
    }
  }

  // ── Isolate entry point (runs on the background thread) ─────────────

  static void _entryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
      final parts = message as List;
      final replyPort = parts[0] as SendPort;
      final bytes = parts[1] as Uint8List;
      final sourceLayers = parts[2] as Set<String>?;

      try {
        final decoded = VectorTrace.sync(
            'parse', () => decodeVectorTile(bytes, sourceLayers: sourceLayers));
        VectorTrace.sync('parseReply', () => replyPort.send(decoded));
      } catch (e) {
        replyPort.send(e.toString());
      }
    });
  }
}
