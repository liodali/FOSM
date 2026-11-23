import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

/// The adaptive lane budget and stale-request cancellation are vector-only:
/// raster keeps its fixed lanes, which is the reference the vector work is
/// measured against.
void main() {
  group('MapView adaptive lanes', () {
    test('raster keeps the fixed lanes', () {
      expect(MapView.resolvedLaneBudget(vectorPayload: false), isNull);
    });

    test('native vector payloads get an adaptive budget', () {
      final budget = MapView.resolvedLaneBudget(vectorPayload: true);
      expect(budget, isNotNull);
      expect(budget!.foregroundMax, 12);
      expect(budget.backgroundMax, 12);
    });

    test('every map shares one budget: the link is the process\'s', () {
      expect(MapView.resolvedLaneBudget(vectorPayload: true),
          same(MapView.resolvedLaneBudget(vectorPayload: true)));
    });
  });

  group('MapView stale request cancellation', () {
    test('raster never cancels', () {
      expect(MapView.resolvedCancelStaleLoads(vectorPayload: false), isFalse);
    });
  });
}
