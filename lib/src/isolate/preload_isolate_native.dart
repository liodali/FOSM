import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Native implementation: spawns a long-lived isolate with a persistent
/// [HttpClient] so TCP connections are reused across hundreds of tile
/// requests — much cheaper than spawning a fresh isolate per tile via
/// [compute].
///
/// Protocol (main → isolate):  `[SendPort replyPort, int z, int x, int y]`
/// Protocol (isolate → main):  `Uint8List` on success, `String` on error.
class PreloadIsolateImpl {
  Isolate? _isolate;
  SendPort? _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  bool _ready = false;

  bool get isReady => _ready;

  /// Spawns the background isolate and waits for the handshake.
  Future<void> spawn() async {
    if (_ready) return;

    final completer = Completer<SendPort>();
    _receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _ready = true;
        if (!completer.isCompleted) completer.complete(message);
      }
    });

    _isolate = await Isolate.spawn(_entryPoint, _receivePort.sendPort);
    await completer.future;
  }

  /// Sends a fetch command and returns the raw PNG bytes.
  /// Throws a [String] error message on failure.
  Future<Uint8List> fetch(int z, int x, int y) {
    final responsePort = ReceivePort();
    _sendPort!.send([responsePort.sendPort, z, x, y]);
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
    _receivePort.close();
    _sendPort = null;
  }

  // ── Isolate entry point (runs on the background thread) ─────────────

  static void _entryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    receivePort.listen((message) async {
      final parts = message as List;
      final replyPort = parts[0] as SendPort;
      final z = parts[1] as int;
      final x = parts[2] as int;
      final y = parts[3] as int;

      try {
        replyPort.send(await _fetchOsmTile(client, z, x, y));
      } catch (e) {
        replyPort.send(e.toString());
      }
    });
  }

  /// Fetches a tile from OpenStreetMap using the isolate's persistent
  /// [HttpClient] (keeps TCP connections alive across requests).
  static Future<Uint8List> _fetchOsmTile(
      HttpClient client, int z, int x, int y) async {
    final n = 1 << z;
    final wrappedX = ((x % n) + n) % n;
    final uri = Uri.parse(
        'https://tile.openstreetmap.org/$z/$wrappedX/$y.png');

    final request = await client.getUrl(uri);
    request.headers.set('User-Agent',
        'fosm/0.0.1 (Flutter OSM map; +https://github.com/fosm)');
    request.headers.set('Accept', 'image/png,image/*');

    final response = await request.close();

    if (response.statusCode != 200) {
      response.drain<void>();
      throw 'HTTP ${response.statusCode}';
    }

    final chunks = <List<int>>[];
    await for (final chunk in response) {
      chunks.add(chunk);
    }
    return Uint8List.fromList(chunks.expand((c) => c).toList());
  }
}
