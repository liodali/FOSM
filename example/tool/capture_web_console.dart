// Captures benchmark markers from a static-served Flutter WEB run in
// Chrome by subscribing to the browser console over the remote-debugging
// (CDP) websocket. Used instead of `flutter run`'s stdout relay on web,
// where flutter_tools' Chrome brings no debug extension and app prints
// cannot be relayed that way.
//
//   dart run tool/capture_web_console.dart CDP_PORT OUT_LOG
//
// Prints every console/log line it observes to OUT_LOG (plain, so
// parse_benchmark_log.dart can read the capture like a native run log)
// and exits 0 at the FOSM_BENCHMARK_DONE marker, 3 otherwise.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
        'Usage: dart run tool/capture_web_console.dart CDP_PORT OUT_LOG');
    exitCode = 64;
    return;
  }
  final cdpPort = int.parse(arguments[0]);
  final outLog = File(arguments[1])..parent.createSync(recursive: true);

  // Finds the localhost page target (the static build this capture
  // launched Chrome against; not flutter_tools' dwds tab).
  Uri? pageWs;
  for (var attempt = 0; attempt < 60; attempt++) {
    pageWs = await _findAppPage(cdpPort);
    if (pageWs != null) break;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  if (pageWs == null) {
    stderr.writeln('no localhost page target on CDP port $cdpPort');
    exitCode = 66;
    return;
  }

  final out = outLog.openWrite();
  final done = Completer<void>();
  var scenarioCount = 0;
  final socket = await WebSocket.connect(pageWs.toString());
  // Send before subscribing: dart:io's single-subscription stream can
  // drop frames already queued when the listener attaches later, and
  // CDP replies land within the first milliseconds.
  socket.add(jsonEncode({'jsonrpc': '2.0', 'id': '1',
      'method': 'Runtime.enable'}));
  var subscribed = false;
  try {
    await for (final raw in socket) {
      if (!subscribed) subscribed = true;
      final event = jsonDecode(raw as String) as Map<String, dynamic>;
      final method = event['method'] as String?;
      if (method == 'Runtime.consoleAPICalled') {
        final params = (event['params'] as Map).cast<String, dynamic>();
        final type = params['type'] as String?;
        if (type != 'log' && type != 'info' && type != 'warning' &&
            type != 'error') {
          continue;
        }
        for (final arg in (params['args'] as List)) {
          final value = (arg as Map)['value'];
          // dart2js print produces a single-string arg; anything else is
          // surfaced in its JSON form so the parser can skip it.
          final text = value is String
              ? value
              : (value == null ? '' : jsonEncode(value));
          out.write('$text\n');
          if (text.contains('FOSM_BENCHMARK_SCENARIO ')) scenarioCount++;
          if (text.contains('FOSM_BENCHMARK_DONE') && !done.isCompleted) {
            done.complete();
          }
        }
      } else if (method == 'Runtime.exceptionThrown') {
        final details =
            ((event['params'] as Map)['exceptionDetails'] as Map)
                .cast<String, dynamic>();
        final text = (details['exception'] is Map &&
                (details['exception'] as Map)['description'] is String)
            ? (details['exception'] as Map)['description'] as String
            : '${details['exception']}';
        out.write('$text\n');
      }
      if (done.isCompleted) break;
    }
  } finally {
    if (!done.isCompleted) {
      done.completeError(
          StateError('browser console stream ended before DONE (no events '
              'observed${subscribed ? '' : ' — subscribe raced the connect?'}'));
    }
  }
  await socket.close();
  await out.flush();
  await out.close();
  stderr.writeln('scenarios observed: $scenarioCount');
  if (scenarioCount == 0) exitCode = 3;
}

Future<Uri?> _findAppPage(int cdpPort) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  try {
    final response = await client
        .getUrl(Uri.parse('http://127.0.0.1:$cdpPort/json'))
        .then((request) => request.close());
    final body = await response.transform(utf8.decoder).join();
    final tabs = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    for (final tab in tabs) {
      final url = '${tab['url']}';
      if ((url.startsWith('http://localhost:') ||
              url.startsWith('http://127.0.0.1:')) &&
          !url.contains('/json')) {
        final ws = '${tab['webSocketDebuggerUrl']}';
        if (ws.isNotEmpty) return Uri.parse(ws);
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}
