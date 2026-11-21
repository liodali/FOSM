import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/tile_manager.dart';

/// Vector payloads widen the manager's load lanes; raster keeps the
/// defaults. Measured basis (iPhone 12 mini, tile latency added at the
/// server): at 250 ms the 2 wide background lane never finished preparing
/// the next zoom level during a 4 s idle (prepared window promoted 0, stale
/// area 417 to 568 ms on a one-level zoom), 12 wide promoted 12 with 0 ms;
/// a cold pinch exposes about 30 cells at once, and the 6 wide foreground
/// lane fetched them in waves (median stale area 1979 ms at 250 ms latency
/// against 1445 ms at 12 wide).
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

  group('MapView foreground lane width', () {
    test('raster keeps the manager default', () {
      expect(MapView.resolvedVisibleLoads(vectorPayload: false), isNull);
    });

    test('vector payloads use the wider vector lane', () {
      expect(MapView.resolvedVisibleLoads(vectorPayload: true),
          TileManager.vectorVisibleLoads);
      expect(TileManager.vectorVisibleLoads,
          greaterThan(TileManager.maxConcurrentVisibleLoads));
    });
  });
}
