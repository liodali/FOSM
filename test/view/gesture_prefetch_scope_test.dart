import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

/// Gesture prefetch ships on for vector payloads only: raster is already
/// fast and keeps its behavior. Measured basis (iPhone 12 mini, tile latency
/// added at the server): after a cold start and a two second zoom-in the
/// median stale area fell from 1001 to 590 ms at 250 ms latency and from
/// 1925 to 1056 ms at 600 ms.
void main() {
  group('MapView gesture prefetch', () {
    test('is on for vector payloads', () {
      expect(MapView.gesturePrefetchByDefine, isTrue);
      expect(MapView.resolvedGesturePrefetch(vectorPayload: true), isTrue);
    });

    test('raster payloads never prefetch along a gesture', () {
      expect(MapView.resolvedGesturePrefetch(vectorPayload: false), isFalse);
    });
  });
}
