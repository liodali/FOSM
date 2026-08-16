import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Persistent HTTP isolate for tile downloads (native implementation).
///
/// Spawns a long-lived isolate with a persistent [HttpClient] so TCP
/// connections are reused across hundreds of requests — much cheaper
/// than spawning a fresh isolate per tile via [compute].
///
/// Accepts arbitrary URL strings, so it works for both raster (OSM) and
/// vector (OpenFreeMap, Mapbox, etc.) tile URLs.
///
/// Protocol (main → isolate):  `[SendPort replyPort, String url]`
/// Protocol (isolate → main):  `Uint8List` on success, `String` on error.
class HttpIsolate {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  bool _ready = false;

  /// Guards against concurrent spawn() calls.
  Future<void>? _spawnFuture;

  bool get isReady => _ready;

  /// Spawns the background isolate and waits for the handshake.
  Future<void> spawn() {
    return _spawnFuture ??= _doSpawn();
  }

  Future<void> _doSpawn() async {
    if (_ready) return;

    // Create a fresh ReceivePort each time.
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

  /// Fetches [url] and returns the raw bytes.
  /// Throws a [String] error message on failure.
  Future<Uint8List> fetchUrl(String url) {
    if (!_ready) {
      throw StateError('HttpIsolate not ready — call spawn() first');
    }
    final responsePort = ReceivePort();
    _sendPort!.send([responsePort.sendPort, url]);
    return responsePort.first.then((response) {
      responsePort.close();
      if (response is Uint8List) return response;
      throw response is String ? response : 'Unknown error';
    });
  }

  /// Kills the isolate and cleans up ports.
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

    // Persistent HttpClient reuses TCP connections across requests.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 30);

    receivePort.listen((message) async {
      final parts = message as List;
      final replyPort = parts[0] as SendPort;
      final url = parts[1] as String;

      try {
        replyPort.send(await _fetch(client, url));
      } catch (e) {
        replyPort.send(e.toString());
      }
    });
  }

  static Future<Uint8List> _fetch(HttpClient client, String url) async {
    final uri = Uri.parse(url);
    final request = await client.getUrl(uri);
    request.headers.set(
      'User-Agent',
      'fosm/0.0.1 (Flutter OSM map; +https://github.com/fosm)',
    );
    request.headers.set('Accept', '*/*');

    final response = await request.close();
    if (response.statusCode != 200) {
      response.drain<void>();
      throw 'HTTP ${response.statusCode} for $url';
    }

    final chunks = <List<int>>[];
    await for (final chunk in response) {
      chunks.add(chunk);
    }
    return Uint8List.fromList(chunks.expand((c) => c).toList());
  }
}
