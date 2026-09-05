import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/isolate/mvt_isolate.dart'
    if (dart.library.io) 'package:fosm/src/isolate/mvt_isolate_native.dart';
import 'package:fosm/src/isolate/mvt_worker.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';

import 'mvt_builder.dart';

void main() {
  test('platform decoder filters unused source layers', () async {
    final decoded = await decodeMvtAsync(
      buildTestTile(),
      sourceLayers: const {'not-water'},
    );
    expect(decoded.layers, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 20)));

  // The persistent MVT isolate only exists on native (dart:io). On web
  // MvtIsolate is a stub whose isReady is always false, so these tests
  // would not exercise the worker.
  if (kIsWeb) {
    test('MvtIsolate is a no-op stub on web', () {
      final worker = MvtIsolate();
      expect(worker.isReady, isFalse);
      worker.dispose();
    });
    return;
  }

  group('MvtIsolate lifecycle', () {
    // Real isolates need a real event loop; fail fast instead of hanging
    // if the test runner can't drain isolate messages.
    const isolateTimeout = Timeout(Duration(seconds: 20));

    test('spawn → decode → dispose', () async {
      final worker = MvtIsolate();
      await worker.spawn();
      expect(worker.isReady, isTrue);

      final decoded = await worker.decode(buildTestTile());
      expect(decoded, isA<DecodedVectorTile>());
      final water = decoded.layerByName('water');
      expect(water, isNotNull);
      expect(water!.features, isNotEmpty);

      worker.dispose();
      expect(worker.isReady, isFalse);
    }, timeout: isolateTimeout);

    test('filters unused source layers in the worker', () async {
      final worker = MvtIsolate();
      await worker.spawn();

      final decoded = await worker.decode(
        buildTestTile(),
        sourceLayers: const {'not-water'},
      );
      expect(decoded.layers, isEmpty);

      worker.dispose();
    }, timeout: isolateTimeout);

    test('multiple sequential requests reuse one isolate', () async {
      final worker = MvtIsolate();
      await worker.spawn();

      for (var i = 0; i < 3; i++) {
        final decoded = await worker.decode(buildTestTile());
        expect(decoded.layerByName('water'), isNotNull);
      }

      worker.dispose();
    }, timeout: isolateTimeout);

    test('concurrent requests are both answered', () async {
      final worker = MvtIsolate();
      await worker.spawn();

      final results = await Future.wait([
        worker.decode(buildTestTile()),
        worker.decode(buildTestTile()),
      ]);
      for (final decoded in results) {
        expect(decoded.layerByName('water'), isNotNull);
      }

      worker.dispose();
    }, timeout: isolateTimeout);

    test('invalid bytes do not crash the worker (error or empty result)',
        () async {
      final worker = MvtIsolate();
      await worker.spawn();

      // Garbage bytes are not a valid MVT stream. The worker must either
      // surface a decode error or return an empty tile — either way it
      // must not hang or kill the isolate. A subsequent valid decode
      // must still work, proving the worker survived.
      try {
        await worker.decode(Uint8List.fromList([0x00, 0x01, 0x02]));
      } catch (_) {
        // Expected when the decoder throws on malformed input.
      }

      final decoded = await worker.decode(buildTestTile());
      expect(decoded.layerByName('water'), isNotNull);

      worker.dispose();
    }, timeout: isolateTimeout);

    test('dispose is safe to call immediately after spawn', () async {
      final worker = MvtIsolate();
      await worker.spawn();
      // Disposing right away (with no in-flight requests) must not throw
      // and must flip isReady off.
      worker.dispose();
      expect(worker.isReady, isFalse);
    }, timeout: isolateTimeout);

    test('double dispose is safe', () async {
      final worker = MvtIsolate();
      await worker.spawn();
      worker.dispose();
      // Second call must not throw.
      worker.dispose();
    }, timeout: isolateTimeout);
  });
}
