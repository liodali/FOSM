import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fosm/src/api/map_load_state.dart';
import 'package:fosm/src/isolate/http_fetch.dart';

export 'package:fosm/src/isolate/http_fetch.dart';

/// Persistent native HTTP worker with bounded requests and owned reply ports.
class HttpIsolate {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  Completer<void>? _startup;
  Future<void>? _spawnFuture;
  final Set<_PendingRequest> _pending = {};
  int _nextRequestId = 0;
  bool _disposed = false;
  bool get isReady => !_disposed && _sendPort != null;

  /// Whether the worker is on its way: [spawn] was called and has not
  /// finished. A request made now can wait for it rather than take another
  /// path (a cold start sends its first wave before the worker is up).
  bool get isStarting =>
      !_disposed && _sendPort == null && _spawnFuture != null;

  Future<void> spawn() => _spawnFuture ??= _doSpawn();

  /// Opens [connections] connections to the host of [url] ahead of the first
  /// tile request. A cold request pays DNS, TCP and TLS before its first byte
  /// (against tiles.openfreemap.org: 146 of 187 ms), and a first wave of tiles
  /// pays it once per connection; connections opened here sit in the worker's
  /// pool and the wave reuses them. Best effort: a failure is ignored, the
  /// tile requests then connect for themselves.
  Future<void> warmUp(String url, {int connections = 6}) async {
    try {
      await spawn();
      if (_disposed || connections < 1) return;
      _sendPort?.send(<Object>['warm', url, connections]);
    } catch (_) {}
  }

  Future<void> _doSpawn() async {
    if (_disposed) throw _cancelled;
    final port = ReceivePort();
    _receivePort = port;
    final startup = Completer<void>();
    _startup = startup;
    port.listen((message) {
      if (message is SendPort && !_disposed) {
        _sendPort = message;
        if (!startup.isCompleted) startup.complete();
      }
    });
    try {
      final isolate = await Isolate.spawn(_entryPoint, port.sendPort);
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        throw _cancelled;
      }
      _isolate = isolate;
      await startup.future.timeout(const Duration(seconds: 5));
    } catch (error) {
      dispose();
      throw TileLoadException.from(error);
    }
  }

  Future<Uint8List> fetchUrl(
    String url, {
    Duration requestTimeout = TileLoadException.defaultRequestTimeout,
    HttpFetchHandle? handle,
  }) async =>
      (await fetchUrlTimed(url, requestTimeout: requestTimeout, handle: handle))
          .bytes;

  /// Fetches [url] and reports how long the first byte took. Cancelling
  /// [handle] aborts the request: the connection is closed, the future fails
  /// with a cancelled [TileLoadException] and the request stops using
  /// bandwidth.
  Future<HttpFetchResult> fetchUrlTimed(
    String url, {
    Duration requestTimeout = TileLoadException.defaultRequestTimeout,
    HttpFetchHandle? handle,
  }) async {
    validateRequestTimeout(requestTimeout);
    if (_disposed) throw _cancelled;
    if (!isReady) {
      throw StateError('HttpIsolate not ready — call spawn() first');
    }
    if (handle != null && handle.isCancelled) throw _cancelled;
    final id = _nextRequestId++;
    final pending = _PendingRequest();
    _pending.add(pending);
    pending.port.listen((response) {
      if (pending.result.isCompleted) return;
      if (response is List) {
        pending.result.complete(HttpFetchResult(
            response[0] as Uint8List,
            Duration(microseconds: response[1] as int)));
      } else {
        pending.result.completeError(response is TileLoadException
            ? response
            : const TileLoadException(
                TileFailureKind.network, 'HTTP worker failed'));
      }
    });
    _sendPort!.send(<Object>[pending.port.sendPort, url, requestTimeout, id]);
    // Attach after the request message so a cancel can never overtake it.
    handle?.attach(() {
      // Settle the caller now; the worker closes the socket when it gets the
      // message, which is what frees the bandwidth.
      if (!pending.result.isCompleted) {
        pending.result.completeError(_cancelled);
      }
      _sendPort?.send(<Object>['cancel', id]);
    });
    try {
      // The worker owns the transport deadline. This watchdog also settles
      // callers if a worker exits without replying.
      return await pending.result.future.timeout(
        requestTimeout + const Duration(seconds: 1),
        onTimeout: () => throw const TileLoadException(
            TileFailureKind.timeout, 'Map request timed out'),
      );
    } finally {
      handle?.detach();
      pending.port.close();
      _pending.remove(pending);
    }
  }

  static const _cancelled =
      TileLoadException(TileFailureKind.cancelled, 'Map request cancelled');

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final startup = _startup;
    if (startup != null && !startup.isCompleted) {
      startup.future.ignore();
      startup.completeError(_cancelled);
    }
    for (final request in _pending) {
      if (!request.result.isCompleted) request.result.completeError(_cancelled);
      request.port.close();
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
  }

  static void _entryPoint(SendPort mainPort) {
    final port = ReceivePort();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 30);
    final active = <int, _ActiveFetch>{};
    mainPort.send(port.sendPort);
    port.listen((message) async {
      final parts = message as List;
      if (parts[0] == 'cancel') {
        active[parts[1] as int]?.cancel();
        return;
      }
      if (parts[0] == 'warm') {
        _warm(client, parts[1] as String, parts[2] as int);
        return;
      }
      final reply = parts[0] as SendPort;
      final id = parts[3] as int;
      final fetch = _ActiveFetch();
      active[id] = fetch;
      try {
        final result =
            await _fetch(client, parts[1] as String, parts[2] as Duration, fetch);
        reply.send(<Object>[result, fetch.firstByteUs]);
      } catch (error) {
        reply.send(TileLoadException.from(error));
      } finally {
        active.remove(id);
      }
    });
  }

  /// Opens [count] connections at once with a HEAD for the host's root, and
  /// drains each response so the connection goes back to the pool idle.
  static void _warm(HttpClient client, String url, int count) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return;
    final root = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/',
    );
    for (var i = 0; i < count; i++) {
      unawaited(() async {
        try {
          final request =
              await client.openUrl('HEAD', root).timeout(_warmTimeout);
          final response = await request.close().timeout(_warmTimeout);
          await response.drain<void>().timeout(_warmTimeout);
        } catch (_) {}
      }());
    }
  }

  static const _warmTimeout = Duration(seconds: 5);

  static Future<Uint8List> _fetch(
      HttpClient client, String url, Duration timeout, _ActiveFetch fetch) async {
    final clock = Stopwatch()..start();
    StreamSubscription<List<int>>? body;
    Completer<Uint8List>? bodyResult;
    var timedOut = false;
    const deadline =
        TileLoadException(TileFailureKind.timeout, 'Map request timed out');
    fetch.onCancel = () {
      fetch.request?.abort(_cancelled);
      body?.cancel();
      final result = bodyResult;
      if (result != null && !result.isCompleted) result.completeError(_cancelled);
    };
    Future<Uint8List> download() async {
      final request = await client.getUrl(Uri.parse(url));
      fetch.request = request;
      if (timedOut || fetch.cancelled) {
        // No close() listener exists yet when connection setup finishes late.
        // Consume the aborted request's completion error as well.
        request.done.ignore();
        request.abort(fetch.cancelled ? _cancelled : deadline);
        throw fetch.cancelled ? _cancelled : deadline;
      }
      request.headers.set('User-Agent',
          'fosm/0.0.2 (Flutter OSM map; +https://github.com/fosm)');
      request.headers.set('Accept', '*/*');
      final response = await request.close();
      fetch.firstByteUs = clock.elapsedMicroseconds;
      if (timedOut || fetch.cancelled) {
        await response.listen((_) {}).cancel();
        throw fetch.cancelled ? _cancelled : deadline;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.listen((_) {}).cancel();
        throw TileLoadException(
            TileFailureKind.http, 'Map server rejected the request',
            statusCode: response.statusCode);
      }
      final result = Completer<Uint8List>();
      bodyResult = result;
      final bytes = BytesBuilder(copy: false);
      body =
          response.listen(bytes.add, onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      }, onDone: () {
        if (!result.isCompleted) result.complete(bytes.takeBytes());
      }, cancelOnError: true);
      return result.future;
    }

    try {
      return await Future.any<Uint8List>([
        download(),
        fetch.cancelSignal.future,
      ]).timeout(timeout, onTimeout: () {
        timedOut = true;
        fetch.request?.abort(deadline);
        if (bodyResult != null && !bodyResult!.isCompleted) {
          bodyResult!.completeError(deadline);
        }
        throw deadline;
      });
    } finally {
      await body?.cancel();
    }
  }
}

/// Worker-side state of one request, so a later cancel message can reach it.
class _ActiveFetch {
  HttpClientRequest? request;
  void Function()? onCancel;
  bool cancelled = false;
  int firstByteUs = 0;
  final Completer<Uint8List> cancelSignal = Completer<Uint8List>();

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    cancelSignal.future.ignore();
    if (!cancelSignal.isCompleted) {
      cancelSignal.completeError(HttpIsolate._cancelled);
    }
    onCancel?.call();
  }
}

class _PendingRequest {
  final ReceivePort port = ReceivePort();
  final Completer<HttpFetchResult> result = Completer<HttpFetchResult>();
}
