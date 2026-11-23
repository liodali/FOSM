import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/lane_budget.dart';

/// A link shared by every request in flight: [bytesPerSecond] of capacity and
/// [latencyUs] before the first byte. One round starts `limit` equal tiles at
/// once; with fair sharing they all end together after
/// `latency + n * size / capacity`.
class _Link {
  _Link({required this.bytesPerSecond, required this.latencyUs});

  final double bytesPerSecond;
  final int latencyUs;
  int nowUs = 0;

  /// Runs [rounds] back-to-back rounds against [budget] and returns the total
  /// width the budget asked for before each round.
  List<int> run(LaneBudget budget, {required int tileBytes, int rounds = 8}) {
    final widths = <int>[];
    for (var round = 0; round < rounds; round++) {
      final n = budget.foregroundLimit;
      widths.add(n);
      final start = nowUs;
      for (var i = 0; i < n; i++) {
        budget.fetchStarted(start);
      }
      final duration =
          latencyUs + (n * tileBytes / bytesPerSecond * 1e6).round();
      nowUs = start + duration;
      for (var i = 0; i < n; i++) {
        budget.fetchFinished(nowUs, bytes: tileBytes, firstByteUs: latencyUs);
      }
    }
    return widths;
  }
}

void main() {
  group('LaneBudget', () {
    test('uses the initial width until it has measured anything', () {
      final budget = LaneBudget();
      expect(budget.hasEstimate, isFalse);
      expect(budget.foregroundLimit, 6);
      expect(budget.backgroundLimit(activeForeground: 0), 2,
          reason: 'idle work starts as narrow as the lane it replaces');
    });

    test('a slow link settles at a narrow lane', () {
      // 2 Mbit/s, 100 ms to the first byte, 120 KB tiles: about 1.2 tiles fit
      // in the pipe, so a wide lane only queues.
      final link = _Link(bytesPerSecond: 250000, latencyUs: 100000);
      final widths = link.run(LaneBudget(), tileBytes: 120000);
      expect(widths.first, 6, reason: 'starts at the initial width');
      expect(widths.last, lessThanOrEqualTo(4));
      expect(widths.last, greaterThanOrEqualTo(3));
    });

    test('a modest link settles near the bandwidth-delay product', () {
      // 8 Mbit/s, 100 ms: about 1.2 + 0.2 tiles of delay product.
      final link = _Link(bytesPerSecond: 1000000, latencyUs: 100000);
      final widths = link.run(LaneBudget(), tileBytes: 120000);
      expect(widths.last, inInclusiveRange(3, 5));
    });

    test('a fast latency-bound link climbs to the maximum', () {
      // 240 Mbit/s, 250 ms: dozens of tiles fit in the pipe.
      final link = _Link(bytesPerSecond: 30000000, latencyUs: 250000);
      final widths = link.run(LaneBudget(), tileBytes: 120000, rounds: 6);
      expect(widths.last, 12);
    });

    test('keeps climbing as long as more requests deliver more', () {
      // Latency-bound but with a modest ceiling: the width rises round over
      // round and never exceeds the configured maximum.
      final link = _Link(bytesPerSecond: 6000000, latencyUs: 600000);
      final widths = link.run(LaneBudget(initialWidth: 3), tileBytes: 120000);
      for (var i = 1; i < widths.length; i++) {
        expect(widths[i], greaterThanOrEqualTo(widths[i - 1] - 1));
      }
      expect(widths.last, 12);
    });

    test('follows the link down when it slows', () {
      final fast = _Link(bytesPerSecond: 30000000, latencyUs: 250000);
      final budget = LaneBudget();
      expect(fast.run(budget, tileBytes: 120000, rounds: 5).last, 12);
      // The fast estimate ages out of the filter window, then the slow link
      // takes over.
      final slow = _Link(bytesPerSecond: 250000, latencyUs: 100000)
        ..nowUs = fast.nowUs + 70000000;
      final widths = slow.run(budget, tileBytes: 120000, rounds: 8);
      expect(widths.last, lessThanOrEqualTo(4));
    });

    test('never goes below the minimum or above the maximum', () {
      final slow = _Link(bytesPerSecond: 20000, latencyUs: 10000);
      final low = slow.run(LaneBudget(minimumWidth: 4), tileBytes: 120000);
      expect(low.every((w) => w >= 4), isTrue);
      final fast = _Link(bytesPerSecond: 1e9, latencyUs: 500000);
      final high =
          fast.run(LaneBudget(foregroundMax: 10), tileBytes: 120000);
      expect(high.every((w) => w <= 10), isTrue);
    });

    test('idle work uses the whole pipe, loading work only the leftover', () {
      final link = _Link(bytesPerSecond: 30000000, latencyUs: 250000);
      final budget = LaneBudget();
      link.run(budget, tileBytes: 120000, rounds: 6);
      final total = budget.totalWidth;
      expect(total, greaterThan(12));
      expect(budget.backgroundLimit(activeForeground: 0), 12,
          reason: 'idle work may use the whole pipe, up to its own maximum');
      expect(budget.backgroundLimit(activeForeground: 12), total - 12,
          reason: 'with the foreground lane full, only the leftover');
    });

    test('a loaded slow link leaves background work one request', () {
      final link = _Link(bytesPerSecond: 250000, latencyUs: 100000);
      final budget = LaneBudget();
      link.run(budget, tileBytes: 120000);
      expect(budget.backgroundLimit(activeForeground: budget.foregroundLimit),
          1,
          reason: 'never starved, never competing');
      expect(budget.backgroundLimit(activeForeground: 0),
          lessThanOrEqualTo(budget.foregroundLimit));
    });

    test('idle work widens once the link shows spare capacity', () {
      final link = _Link(bytesPerSecond: 30000000, latencyUs: 250000);
      final budget = LaneBudget();
      expect(budget.backgroundLimit(activeForeground: 0), 2);
      link.run(budget, tileBytes: 120000, rounds: 3);
      expect(budget.hasEstimate, isTrue);
      expect(budget.backgroundLimit(activeForeground: 0), greaterThan(2));
    });

    test('a clock that goes backwards cannot inflate the rate', () {
      final budget = LaneBudget();
      // Two callers on different time bases: the second one's "now" is far
      // behind the first one's busy-period start.
      budget.fetchStarted(10000000);
      budget.fetchFinished(10300000, bytes: 100000, firstByteUs: 100000);
      budget.fetchStarted(10300000);
      budget.fetchFinished(1800000, bytes: 150000, firstByteUs: 120000);
      // 250 KB over the 0.3 s that really passed is 0.83 MB/s; the held
      // timestamp must not produce anything near the 14 MB/s a mixed clock did.
      final width = budget.totalWidth;
      expect(width, lessThan(8),
          reason: 'the estimate stays at the real rate, not an inflated one');
    });

    test('abandoned requests do not distort the estimate', () {
      final budget = LaneBudget();
      budget.fetchStarted(0);
      budget.fetchAbandoned();
      expect(budget.inFlight, 0);
      expect(budget.foregroundLimit, 6);
    });

    test('an idle gap does not dilute the next burst', () {
      final link = _Link(bytesPerSecond: 30000000, latencyUs: 250000);
      final budget = LaneBudget();
      link.run(budget, tileBytes: 120000, rounds: 5);
      // Thirty quiet seconds, then a burst: the busy period restarts, so the
      // first sample is not averaged over the gap.
      link.nowUs += 30000000;
      final widths = link.run(budget, tileBytes: 120000, rounds: 2);
      expect(widths.last, 12);
    });

    test('tiny empty tiles do not shrink the mean size to nothing', () {
      final budget = LaneBudget();
      for (var i = 0; i < 20; i++) {
        budget.fetchStarted(i * 300000);
        budget.fetchFinished(i * 300000 + 250000,
            bytes: 0, firstByteUs: 250000);
      }
      expect(budget.foregroundLimit, 6, reason: 'still the initial width');
    });
  });
}
