import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';

/// Vector payloads widen the manager's background lane; raster keeps the
/// default. Measured basis: on an iPhone 12 mini at 250 ms tile latency the
/// 2 wide lane never finished preparing the next zoom level during a 4 s
/// idle (prepared window promoted 0, stale area 417 to 568 ms on a one-level
/// zoom); 6 wide promoted 12 with 0 ms stale area.
void main() {
  group('MapView background lane width', () {
    test('raster keeps the manager default', () {
      expect(MapView.resolvedBackgroundLoads(vectorPayload: false), isNull);
    });

    test('vector payloads use the wider vector lane', () {
      expect(MapView.resolvedBackgroundLoads(vectorPayload: true),
          TileManager.vectorBackgroundLoads);
      expect(TileManager.vectorBackgroundLoads,
          greaterThan(TileManager.maxConcurrentBackgroundLoads));
    });
  });
}
