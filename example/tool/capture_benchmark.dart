// Subscribe before resuming a --start-paused profile benchmark.
//
// Usage: dart run tool/capture_benchmark.dart FLUTTER_RUN_LOG [--timeline FILE]
//
// --timeline FILE also captures the VM timeline (all isolates, so the
// persistent MVT worker's `fosm.vector.parse` spans are included) around
// the benchmark window: it arms the Dart stream and clears the timeline at
// startup, then saves the recorded events to FILE on completion.
//
// The acceptance gate validates the saved timeline per scenario (the app
// emits `fosm.benchmark.sampleStart/sampleEnd.<scenario>` boundary
// markers on the timeline clock): every scenario's boundaries must exist,
// and each scenario's cache state must show its required pipeline events
// — cold-like and style-switch scenarios need worker `parse` events;
// warm scenarios may legitimately skip parsing. A coarse global window
// check guards against late arming. Failures exit with code 3.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:example/benchmark/timeline_gate.dart';

Future<void> main(List<String> arguments) async {
  final positional = <String>[];
  String? timelineFile;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--timeline') {
      if (i + 1 >= arguments.length) {
        stderr.writeln('--timeline requires a file path');
        exitCode = 64;
        return;
      }
      timelineFile = arguments[++i];
    } else {
      positional.add(arguments[i]);
    }
  }
  if (positional.length != 1) {
    stderr.writeln(
        'Usage: dart run tool/capture_benchmark.dart FLUTTER_RUN_LOG '
        '[--timeline FILE]');
    exitCode = 64;
    return;
  }
  final log = File(positional.single).readAsStringSync();
  final wallClock = Stopwatch();
  // --timeline captures pipeline events by polling getVMTimeline without
  // clearing: the ring evicts old events, so snapshots are merged and
  // deduplicated every few seconds (clearing between snapshots loses
  // single-instant markers to a snapshot race, and the live Timeline
  // stream delivers nothing under DDS).
  final timelineSegments = <Map<String, dynamic>>[];
  final seenSignatures = <String>{};
  Timer? drainTimer;
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

  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic> params = const {}]) {
    final id = '${++sequence}';
    final reply = Completer<Map<String, dynamic>>();
    pending[id] = reply;
    socket.add(jsonEncode(
        {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return reply.future.timeout(const Duration(seconds: 15));
  }

  // Resumes an isolate if (and only if) it currently sits at a pause
  // event. Retries briefly: an IsolateStart notification can race the
  // isolate reaching its PauseStart event.
  Future<void> resumeIfPaused(String isolateId) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        final isolate = await call('getIsolate', {'isolateId': isolateId});
        final pause = (isolate['pauseEvent'] as Map?)?['kind'] as String?;
        if (pause == null || !pause.startsWith('Pause')) return;
        await call('resume', {'isolateId': isolateId});
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  // Snapshots the ring into [timelineSegments], skipping events already
  // merged (consecutive snapshots overlap until old events are evicted).
  // The buffer is never cleared: clearing loses single-instant markers
  // that land between the snapshot and the clear.
  Future<void> drainTimeline() async {
    final timeline = await call('getVMTimeline');
    final events = (timeline['traceEvents'] as List? ?? const [])
        .whereType<Map>()
        .map((event) => Map<String, dynamic>.from(event))
        .toList();
    for (final event in events) {
      // Signature includes phase, async id, pid and the serialized
      // correlation arguments: distinct events can share name, ts, tid
      // and duration (begin/end pairs of overlapping async spans), and
      // collapsing them would break event pairing and attribution.
      final signature = '${event['name']}|${event['ts']}|${event['ph']}|'
          '${event['tid']}|${event['pid']}|${event['dur']}|${event['id']}|'
          '${jsonEncode(event['args'])}';
      if (seenSignatures.add(signature)) {
        timelineSegments.add(event);
      }
    }
  }

  // Line-aware marker capture: SCENARIO lines drive the per-scenario
  // timeline gate. Chunks can split lines, so only complete lines are
  // parsed and a partial tail is carried across chunks.
  final scenarioLines = <String>[];
  var lineBuffer = '';
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
      if (params['streamId'] == 'Isolate') {
        // `--start-paused` leaves every later-spawned isolate paused too
        // (the persistent MVT decode worker among them) — without this,
        // vector decodes deadlock on the worker handshake. DDS relays
        // isolate events with a generic type, so every event carrying an
        // isolate id is checked; resumeIfPaused no-ops on running
        // isolates.
        final isolateId = (payload['isolate'] as Map?)?['id'] as String?;
        if (isolateId != null) {
          unawaited(resumeIfPaused(isolateId));
        }
      }
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
        lineBuffer += text;
        final lines = lineBuffer.split('\n');
        lineBuffer = lines.removeLast();
        for (final line in lines) {
          if (line.contains('FOSM_BENCHMARK_SCENARIO ')) {
            scenarioLines.add(line);
          }
        }
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

  try {
    await call('streamListen', {'streamId': 'Stdout'});
    await call('streamListen', {'streamId': 'Stderr'});
    await call('streamListen', {'streamId': 'Isolate'});
    if (timelineFile != null) {
      // Arm the timeline before anything resumes: the worker isolate's
      // parse spans are Dart timeline events and must be recorded from
      // the start to cover the whole benchmark window. Poll without
      // clearing so nothing is lost to eviction or snapshot races.
      await call('setVMTimelineFlags', {
        'recordedStreams': ['Dart'],
      });
      await call('clearVMTimeline');
      drainTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(drainTimeline().catchError((_) {}));
      });
    }
    wallClock.start();
    final vm = await call('getVM');
    for (final dynamic ref in vm['isolates'] as List? ?? const []) {
      final isolateId = (ref as Map)['id'] as String;
      final isolate = await call('getIsolate', {'isolateId': isolateId});
      final pause = (isolate['pauseEvent'] as Map?)?['kind'] as String?;
      if (pause?.startsWith('Pause') ?? false) {
        await call('resume', {'isolateId': isolateId});
      }
    }
    await done.future.timeout(const Duration(minutes: 10));
    final windowUs = wallClock.elapsedMicroseconds;
    if (timelineFile != null) {
      drainTimer?.cancel();
      await drainTimeline();
      final events = timelineSegments;

      int count(String name) =>
          events.where((e) => e['name'] == 'fosm.vector.$name').length;
      final parseEvents = count('parse');
      final parseWaitEvents = count('parseWait');
      final recordEvents = count('record');
      final toImageEvents = count('toImage');
      final vectorEvents = events
          .where((e) => '${e['name']}'.startsWith('fosm.vector.'))
          .length;

      // Coarse global check: the timeline must span most of the run
      // (guards against late arming or an early recorder stop). The
      // per-scenario check below is what proves scenario coverage.
      var minTs = 0;
      var maxTs = 0;
      for (final e in events) {
        final ts = e['ts'];
        if (ts is num) {
          final us = ts.toInt();
          if (minTs == 0 || us < minTs) minTs = us;
          if (us > maxTs) maxTs = us;
        }
      }
      final spanUs = maxTs - minTs;
      final coverageRatio =
          windowUs <= 0 ? 0.0 : (spanUs / windowUs).clamp(0.0, 1.0);

      // Per-scenario validation: the app emits sampleStart/sampleEnd
      // boundary markers on the timeline clock, so each scenario's
      // window is checked for the events its cache state requires — warm
      // scenarios may legitimately skip parsing; cold-like and
      // style-switch scenarios must show worker parses.
      final scenarios = <TimelineScenarioMark>[
        for (final line in scenarioLines)
          if (parseScenarioMarkLine(line) case final mark?) mark,
      ];
      final scenarioResults =
          validateTimelineAgainstScenarios(scenarios, events);

      final sink = File(timelineFile)
        ..createSync(recursive: true)
        ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
          'type': 'Timeline',
          'gate': {
            'windowUs': windowUs,
            'timelineSpanUs': spanUs,
            'windowCoverage': double.parse(coverageRatio.toStringAsFixed(3)),
            'parseEvents': parseEvents,
            'parseWaitEvents': parseWaitEvents,
            'recordEvents': recordEvents,
            'toImageEvents': toImageEvents,
            'fosmVectorEvents': vectorEvents,
            'scenarios': [
              for (final result in scenarioResults)
                {
                  'scenario': result.scenario.name,
                  'cacheState': result.scenario.cacheState,
                  'source': result.scenario.source,
                  'styleSwitch': result.scenario.styleSwitch,
                  'windowFound': result.windowFound,
                  'requiredEventCounts': result.counts,
                  'ok': result.ok,
                  if (result.failures.isNotEmpty)
                    'failures': result.failures,
                },
            ],
          },
          'traceEvents': events,
        }));
      stdout.writeln('timeline: ${sink.path} '
          '(${events.length} events, $vectorEvents fosm.vector.*, '
          '$parseEvents worker parse, '
          'window coverage ${(coverageRatio * 100).toStringAsFixed(0)}%, '
          '${scenarioResults.where((r) => r.ok).length}/'
          '${scenarioResults.length} scenarios valid)');

      // Acceptance gate.
      final failures = <String>[
        if (scenarios.isEmpty)
          'no FOSM_BENCHMARK_SCENARIO lines captured — cannot validate '
          'scenario coverage',
        for (final result in scenarioResults)
          if (!result.ok)
            '${result.scenario.name}: ${result.failures.join('; ')}',
        if (coverageRatio < 0.8)
          'timeline covers only ${(coverageRatio * 100).toStringAsFixed(0)}% '
          'of the benchmark window',
      ];
      if (failures.isNotEmpty) {
        stderr.writeln('timeline capture gate failed: ${failures.join('; ')}');
        exitCode = 3;
      }
    }
  } finally {
    await subscription.cancel();
    await socket.close();
  }
}
