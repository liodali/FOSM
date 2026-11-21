import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/common/rendered_tile_cache.dart' show RenderedTileCache;

/// The payload-scoped rendered-cache budget defaults behind the
/// resolution decision (512 px vector tiles): vector payloads resolve to
/// [MapView.vectorRenderedCacheDefaultBytes] when the app leaves
/// `maxRenderedCacheBytes` unset, raster payloads keep the shipped
/// `RenderedTileCache.defaultMaxBytes`, and an explicit value always
/// wins. Measured basis: docs/performance/vector-render-improvement/
/// zoom-softness-diagnostic.md (device A/B).
void main() {
  const mb = 1024 * 1024;

  group('MapView rendered-cache budget resolution', () {
    test('an explicit value wins for both payloads (including zero)', () {
      expect(
        MapView.resolvedRenderedCacheBytes(
            vectorPayload: true, maxRenderedCacheBytes: 42),
        42,
      );
      expect(
        MapView.resolvedRenderedCacheBytes(
            vectorPayload: false, maxRenderedCacheBytes: 42),
        42,
      );
      expect(
        MapView.resolvedRenderedCacheBytes(
            vectorPayload: true, maxRenderedCacheBytes: 0),
        0,
      );
    });

    test('vector default lands in the 100–200 MB band', () {
      expect(
        MapView.vectorRenderedCacheDefaultBytes,
        inInclusiveRange(100 * mb, 200 * mb),
      );
    });

    test('raster default stays at the shipped 50 MB (50–100 MB band)', () {
      expect(
        MapView.resolvedRenderedCacheBytes(vectorPayload: false),
        RenderedTileCache.defaultMaxBytes,
      );
      expect(
        RenderedTileCache.defaultMaxBytes,
        inInclusiveRange(50 * mb, 100 * mb),
      );
    });

    test('vector default exceeds the raster default', () {
      expect(
        MapView.vectorRenderedCacheDefaultBytes > RenderedTileCache.defaultMaxBytes,
        isTrue,
        reason: '512 px vector tiles quadruple the per-tile bytes — the '
            'vector budget must not thrash where the raster budget holds',
      );
    });
  });
}
