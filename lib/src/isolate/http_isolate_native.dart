import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../api/map_load_state.dart';

/// Persistent native HTTP worker with bounded requests and owned reply ports.
class HttpIsolate {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  Completer<void>? _startup;
  Future<void>? _spawnFuture;
  final Set<_PendingRequest> _pending = {};
  bool _disposed = false;
  bool get isReady => !_disposed && _sendPort != null;

  Future<void> spawn() => _spawnFuture ??= _doSpawn();

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
  }) async {
    validateRequestTimeout(requestTimeout);
    if (_disposed) throw _cancelled;
    if (!isReady) {
      throw StateError('HttpIsolate not ready — call spawn() first');
    }
    final pending = _PendingRequest();
    _pending.add(pending);
    pending.port.listen((response) {
      if (pending.result.isCompleted) return;
      if (response is Uint8List) {
        pending.result.complete(response);
      } else {
        pending.result.completeError(response is TileLoadException
            ? response
            : const TileLoadException(
                TileFailureKind.network, 'HTTP worker failed'));
      }
    });
    _sendPort!.send([pending.port.sendPort, url, requestTimeout]);
    try {
      // The worker owns the transport deadline. This watchdog also settles
      // callers if a worker exits without replying.
      return await pending.result.future.timeout(
        requestTimeout + const Duration(seconds: 1),
        onTimeout: () => throw const TileLoadException(
            TileFailureKind.timeout, 'Map request timed out'),
      );
    } finally {
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
    mainPort.send(port.sendPort);
    port.listen((message) async {
      final parts = message as List;
      final reply = parts[0] as SendPort;
      try {
        reply.send(
            await _fetch(client, parts[1] as String, parts[2] as Duration));
      } catch (error) {
        reply.send(TileLoadException.from(error));
      }
    });
  }

  static Future<Uint8List> _fetch(
      HttpClient client, String url, Duration timeout) async {
    HttpClientRequest? request;
    StreamSubscription<List<int>>? body;
    Completer<Uint8List>? bodyResult;
    var timedOut = false;
    const deadline =
        TileLoadException(TileFailureKind.timeout, 'Map request timed out');
    Future<Uint8List> download() async {
      request = await client.getUrl(Uri.parse(url));
      if (timedOut) {
        // No close() listener exists yet when connection setup finishes late.
        // Consume the aborted request's completion error as well.
        request!.done.ignore();
        request!.abort(deadline);
        throw deadline;
      }
      request!.headers.set('User-Agent',
          'fosm/0.0.2 (Flutter OSM map; +https://github.com/fosm)');
      request!.headers.set('Accept', '*/*');
      final response = await request!.close();
      if (timedOut) {
        await response.listen((_) {}).cancel();
        throw deadline;
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
      return await download().timeout(timeout, onTimeout: () {
        timedOut = true;
        request?.abort(deadline);
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

class _PendingRequest {
  final ReceivePort port = ReceivePort();
  final Completer<Uint8List> result = Completer<Uint8List>();
}
