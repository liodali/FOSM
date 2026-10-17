// Subscribe before resuming a --start-paused profile benchmark. No packages.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr
        .writeln('Usage: dart run tool/capture_benchmark.dart FLUTTER_RUN_LOG');
    exitCode = 64;
    return;
  }
  final log = File(arguments.single).readAsStringSync();
  final match =
      RegExp(r'A Dart VM Service[^\n]* (http://[^\s]+)').firstMatch(log);
  if (match == null) {
    throw StateError('Wait for the Dart VM Service URL in the run log.');
  }
  final http = Uri.parse(match.group(1)!);
  if (!['127.0.0.1', 'localhost', '::1'].contains(http.host)) {
    throw ArgumentError('Only a local forwarded VM service is supported.');
  }
  final socket = await WebSocket.connect(
      http.replace(scheme: 'ws', path: '${http.path}ws').toString());
  final pending = <String, Completer<Map<String, dynamic>>>{};
  final done = Completer<void>();
  var sequence = 0;
  var tail = '';
  final subscription = socket.listen((dynamic message) {
    final event = jsonDecode(message as String) as Map<String, dynamic>;
    final id = event['id']?.toString();
    if (id != null) {
      final reply = pending.remove(id);
      if (event.containsKey('error')) {
        reply?.completeError(StateError('${event['error']}'));
      } else {
        reply?.complete((event['result'] as Map).cast<String, dynamic>());
      }
    } else if (event['method'] == 'streamNotify') {
      final params = (event['params'] as Map).cast<String, dynamic>();
      final payload = (params['event'] as Map).cast<String, dynamic>();
      final encoded = payload['bytes'] as String?;
      if (encoded == null) return;
      final text = utf8.decode(base64.decode(encoded));
      if (params['streamId'] == 'Stderr') {
        stderr.write(text);
      } else {
        stdout.write(text);
        tail += text;
        if (tail.contains('FOSM_BENCHMARK_DONE') && !done.isCompleted) {
          done.complete();
        }
        if (tail.length > 1024) tail = tail.substring(tail.length - 1024);
      }
    }
  }, onError: (Object error, StackTrace trace) {
    if (!done.isCompleted) done.completeError(error, trace);
  }, onDone: () {
    if (!done.isCompleted) {
      done.completeError(
          StateError('VM service disconnected before benchmark completion.'));
    }
  });
  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic> params = const {}]) {
    final id = '${++sequence}';
    final reply = Completer<Map<String, dynamic>>();
    pending[id] = reply;
    socket.add(jsonEncode(
        {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return reply.future.timeout(const Duration(seconds: 15));
  }

  try {
    await call('streamListen', {'streamId': 'Stdout'});
    await call('streamListen', {'streamId': 'Stderr'});
    final vm = await call('getVM');
    for (final dynamic ref in vm['isolates'] as List? ?? const []) {
      final isolateId = (ref as Map)['id'] as String;
      final isolate = await call('getIsolate', {'isolateId': isolateId});
      final pause = (isolate['pauseEvent'] as Map?)?['kind'] as String?;
      if (pause?.startsWith('Pause') ?? false) {
        await call('resume', {'isolateId': isolateId});
      }
    }
    await done.future.timeout(const Duration(minutes: 3));
  } finally {
    await subscription.cancel();
    await socket.close();
  }
}
