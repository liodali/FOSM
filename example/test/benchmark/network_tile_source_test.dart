import 'dart:typed_data';

import 'package:example/benchmark/network_tile_source.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int length) => Uint8List(length);

Future<Uint8List> _upstream(int z, int x, int y) async => _bytes(1000);

void main() {
  test('inert network wraps to the upstream fetcher itself', () {
    final net = SimulatedNetwork();
    expect(net.inert, isTrue);
    expect(net.wrap(_upstream), same(_upstream));
    expect(net.describe(), {'delayMs': 0, 'kbps': 0, 'dropEvery': 0});
  });

  test('applies the fixed per-request latency', () async {
    final net = SimulatedNetwork(delayMs: 40);
    final fetcher = net.wrap(_upstream);
    final stopwatch = Stopwatch()..start();
    final bytes = await fetcher(10, 0, 0);
    stopwatch.stop();
    expect(bytes.length, 1000);
    expect(stopwatch.elapsed.inMilliseconds,
        greaterThanOrEqualTo(35)); // clock granularity margin
    expect(net.stats(), {'requests': 1, 'failures': 0, 'bytesServed': 1000});
  });

  test('shapes bandwidth by payload size', () async {
    // 2000 bytes at 64 kbps ≈ 250 ms of transfer; 1000 bytes ≈ 125 ms.
    final net = SimulatedNetwork(kbps: 64);
    final fetcher = net.wrap((z, x, y) async => _bytes(z == 1 ? 2000 : 1000));

    final big = Stopwatch()..start();
    await fetcher(1, 0, 0);
    big.stop();
    final small = Stopwatch()..start();
    await fetcher(2, 0, 0);
    small.stop();

    expect(big.elapsed, greaterThan(small.elapsed));
    expect(big.elapsed.inMilliseconds, greaterThan(220));
    expect(net.bytesServed, 3000);
  });

  test('fails every Nth request and counts failures', () async {
    final net = SimulatedNetwork(dropEvery: 3);
    final fetcher = net.wrap(_upstream);
    for (var i = 1; i <= 6; i++) {
      if (i % 3 == 0) {
        await expectLater(fetcher(10, i, 0), throwsException);
      } else {
        expect((await fetcher(10, i, 0)).length, 1000);
      }
    }
    expect(net.stats(), {'requests': 6, 'failures': 2, 'bytesServed': 4000});
    net.reset();
    expect(net.stats(), {'requests': 0, 'failures': 0, 'bytesServed': 0});
  });

  test('latency and bandwidth compose', () async {
    final net = SimulatedNetwork(delayMs: 30, kbps: 256);
    final fetcher = net.wrap((z, x, y) async => _bytes(512));
    final stopwatch = Stopwatch()..start();
    await fetcher(10, 0, 0);
    stopwatch.stop();
    // 30 ms RTT + 512·8/256 = 16 ms transfer = 46 ms minimum.
    expect(stopwatch.elapsed.inMilliseconds, greaterThan(40));
  });
}
