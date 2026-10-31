import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:flutter/foundation.dart';

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
/// Protocol (main → isolate): sendport reply, bytes, `Set<String>?`
/// sourceLayers, `String?` traceTile, `String?` traceAttempt,
/// `String?` traceSource, int sentAtUs — the last three feed worker
/// trace identity and the `parseHold` backlog measurement (same clock
/// as `fosm.vector.parseDispatch`).
///
/// Protocol (isolate → main): a two-element list, the decoded tile plus
/// the stats piggyback that feeds the main-isolate span log; a bare
/// `String` on error.
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

  /// Guards against concurrent spawn() calls. Cleared by [dispose] and
  /// when a spawn attempt fails, so a later [spawn] can retry.
  Future<void>? _spawnFuture;

  /// Bumped by every [dispose]. A spawn attempt captures the generation
  /// before awaiting `Isolate.spawn`; when the platform call resolves
  /// after a dispose, [dispose] saw a `null` isolate handle and killed
  /// nothing — the late handle must be killed by the spawn itself and
  /// must never be published to [_isolate].
  int _spawnGeneration = 0;

  /// Late worker handles killed because dispose ran while their spawn
  /// was still resolving (test hook; each such worker would otherwise
  /// outlive this [MvtIsolate]).
  @visibleForTesting
  int debugLateSpawnKills = 0;

  /// Completes the spawn handshake. [dispose] may run before the worker
  /// sends its [SendPort]; without failing this completer the returned
  /// [spawn] future — and everything awaiting it — would hang forever.
  Completer<SendPort>? _handshake;

  /// Outstanding decodes by their reply port. [dispose] kills the worker,
  /// so their replies can never arrive — each is completed with
  /// [VectorTileCancelled] and its port closed instead of hanging forever.
  final Map<ReceivePort, _PendingDecode> _pending = {};

  bool get isReady => _ready;

  /// Spawns the background isolate and waits for the handshake.
  Future<void> spawn() {
    final existing = _spawnFuture;
    if (existing != null) return existing;
    late final Future<void> spawnAttempt;
    spawnAttempt = _doSpawn().then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        // A failed or aborted spawn must not pin the cache: clear it so a
        // later spawn() can retry — but never clobber a newer attempt
        // that already replaced this future.
        if (identical(_spawnFuture, spawnAttempt)) _spawnFuture = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _spawnFuture = spawnAttempt;
    return spawnAttempt;
  }

  Future<void> _doSpawn() async {
    if (_ready) return;
    final generation = _spawnGeneration;

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
      final isolate = await Isolate.spawn(_entryPoint, _receivePort!.sendPort);
      if (generation != _spawnGeneration) {
        // dispose() ran while the platform spawn was still resolving: it
        // saw a null isolate handle and killed nothing. Kill the late
        // worker here and never publish it — its handshake is already
        // failed and its reply port was closed by dispose. (A retry that
        // started in the meantime owns the current port fields.)
        debugLateSpawnKills++;
        isolate.kill(priority: Isolate.immediate);
        throw StateError('MvtIsolate disposed during spawn');
      }
      _isolate = isolate;
      await handshake.future;
    } finally {
      if (identical(_handshake, handshake)) _handshake = null;
    }
  }

  /// Decodes [bytes] on the background isolate and returns the parsed
  /// tile. Each call uses a one-shot [ReceivePort] for its reply,
  /// matching the [HttpIsolate] pattern. The future completes with
  /// [VectorTileCancelled] when [dispose] runs before the reply lands.
  ///
  /// [traceTile]/[traceAttempt] correlate the worker's `parse` timeline
  /// events with the requesting attempt (the decode future is shared by
  /// over-zoom siblings — the first requester's attempt is attached).
  /// [traceSource] carries the resolved source tile so worker-side
  /// attribution keeps the shared-parse identity; it also lands in the
  /// span log with the queue/backlog spans.
  ///
  /// Two span-log stages are emitted here (main isolate):
  /// - `parseQueueWait` — decode-call entry to the actual dispatch send,
  ///   i.e. main-isolate event-loop delay plus worker spawn handshake.
  /// - `parseHold` — dispatched to worker parse start (worker-reported
  ///   backlog inside the serial worker's port queue), piggybacked on the
  ///   reply along with the worker's measured `parse` CPU.
  Future<DecodedVectorTile> decode(
    Uint8List bytes, {
    Set<String>? sourceLayers,
    String? traceTile,
    String? traceAttempt,
    String? traceSource,
  }) {
    if (!_ready) {
      throw StateError('MvtIsolate not ready — call spawn() first');
    }
    final responsePort = ReceivePort();
    final completer = Completer<DecodedVectorTile>();
    final pending = _PendingDecode(
      completer,
      tile: traceTile,
      attempt: traceAttempt,
      source: traceSource,
    );
    final entryUs = VectorSpanLog.nowUs();
    _pending[responsePort] = pending;
    responsePort.listen((response) {
      _pending.remove(responsePort);
      responsePort.close();
      if (completer.isCompleted) return;
      if (response is DecodedVectorTile) {
        completer.complete(response);
      } else if (response is List && response.length == 2) {
        _emitWorkerStats(pending, response[1]);
        completer.complete(response[0] as DecodedVectorTile);
      } else {
        completer
            .completeError(response is String ? response : 'Unknown error');
      }
    });
    VectorTrace.sync(
        'parseDispatch',
        () => _sendPort!.send([
              responsePort.sendPort,
              bytes,
              sourceLayers,
              traceTile,
              traceAttempt,
              traceSource,
              developer.Timeline.now,
            ]),
        tile: traceTile,
        attempt: traceAttempt,
        source: traceSource);
    if (VectorSpanLog.enabled) {
      VectorSpanLog.record(
        'parseQueueWait',
        traceTile,
        entryUs,
        VectorSpanLog.nowUs() - entryUs,
        attempt: traceAttempt,
        source: traceSource,
      );
    }
    return completer.future;
  }

  /// Emits the per-decode worker stats a reply carries into the span log.
  /// Both stages are aligned to the reply's receive time: `parse` (worker
  /// CPU, same identity as the triggering attempt) ends receive; `parseHold`
  /// (port-queue backlog before the worker reached this message) sits
  /// before it. Missing keys — a worker that predates the piggyback, or a
  /// lost clock — emit nothing.
  static void _emitWorkerStats(_PendingDecode pending, Object? raw) {
    if (!VectorSpanLog.enabled || raw is! Map) return;
    final receivedUs = VectorSpanLog.nowUs();
    final tile = pending.tile;
    final attempt = pending.attempt;
    final source = pending.source;
    final parseUs = raw['parseUs'];
    if (parseUs is int && parseUs > 0) {
      VectorSpanLog.record('parse', tile, receivedUs - parseUs, parseUs,
          attempt: attempt, source: source);
    }
    final holdUs = raw['holdUs'];
    if (holdUs is int && holdUs > 0 && parseUs is int) {
      VectorSpanLog.record('parseHold', tile, receivedUs - parseUs - holdUs,
          holdUs,
          attempt: attempt, source: source);
    }
  }

  /// Kills the isolate and cleans up ports. Safe to call multiple times.
  /// Outstanding decodes complete with [VectorTileCancelled] — the worker
  /// is dead, so waiting for their replies would hang the callers (and the
  /// runtime's parse bookkeeping) forever.
  void dispose() {
    // Invalidate any in-flight spawn first: its platform call may resolve
    // after this dispose, and the late worker handle must be killed by
    // the spawn itself (see _doSpawn) instead of leaking until a second
    // dispose.
    _spawnGeneration++;
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
      if (!entry.value.completer.isCompleted) {
        entry.value.completer.completeError(const VectorTileCancelled());
      }
    }
  }

  // ── Isolate entry point (runs on the background thread) ─────────────

  static void _entryPoint(SendPort mainSendPort) {
    // Timeline events stay on (the trace arm reads them through the VM
    // timeline); the span log is disabled here so undrained worker-side
    // spans cannot accumulate isolate memory nobody reads.
    VectorSpanLog.enabled = false;
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
      final parts = message as List;
      final replyPort = parts[0] as SendPort;
      final bytes = parts[1] as Uint8List;
      final sourceLayers = parts[2] as Set<String>?;
      final traceTile = parts.length > 3 ? parts[3] as String? : null;
      final traceAttempt = parts.length > 4 ? parts[4] as String? : null;
      final traceSource = parts.length > 5 ? parts[5] as String? : null;
      final sentAtUs = parts.length > 6 && parts[6] is int ? parts[6] as int : 0;
      // How long this message waited in the port queue (or behind the
      // previous parse) before this listener ran — main dispatched it and
      // resumed rendering; that wait is invisible to main without this
      // hop. Measured on the shared VM timeline clock, so main's
      // parseDispatch timestamp is directly comparable.
      final holdUs =
          sentAtUs > 0 ? (developer.Timeline.now - sentAtUs).clamp(0, 1 << 40) : 0;

      try {
        final parseClock = Stopwatch()..start();
        final decoded = VectorTrace.sync(
            'parse', () => decodeVectorTile(bytes, sourceLayers: sourceLayers),
            tile: traceTile, attempt: traceAttempt, source: traceSource);
        parseClock.stop();
        // Reply unravels from the trigger's identity anyway; the stats
        // piggyback (hold + parse CPU) lets the main isolate record the
        // side channels it cannot see (port backlog, worker CPU).
        VectorTrace.sync('parseReply', () {
          replyPort.send([
            decoded,
            <String, Object?>{
              if (holdUs > 0) 'holdUs': holdUs,
              'parseUs': parseClock.elapsedMicroseconds,
            }
          ]);
        }, tile: traceTile, attempt: traceAttempt, source: traceSource);
      } catch (e) {
        replyPort.send(e.toString());
      }
    });
  }
}

/// One outstanding decode and the trace identity to attribute its
/// reply-carried worker stats (port-queue backlog, worker parse CPU) when
/// they land on the main-isolate span log.
class _PendingDecode {
  const _PendingDecode(
    this.completer, {
    this.tile,
    this.attempt,
    this.source,
  });

  final Completer<DecodedVectorTile> completer;
  final String? tile;
  final String? attempt;
  final String? source;
}
