import 'package:flutter_test/flutter_test.dart';

import 'mvt_builder.dart';
import 'pipeline_fixture.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';

/// Plan-13 attribution: the parsed-source-tile LRU must count capacity
/// evictions so workload captures can measure reparsing pressure when a
/// source footprint exceeds [VectorTileRuntime.maxParsedTiles].
void main() {
  testWidgets('parsed-tile LRU counts evictions beyond the entry cap',
      (tester) async {
    final runtime = VectorTileRuntime(
      loaded: buildLoadedStyle(),
      namespace: 'parsed-lru-counter',
      parseOffThread: false,
    );
    addTearDown(runtime.dispose);

    expect(runtime.parsedEvictions, 0);
    await tester.runAsync(() async {
      for (var x = 0; x < 40; x++) {
        await runtime.decoder(buildTestTile(), 10, 100 + x, 60);
      }
    });
    // 40 distinct source tiles through a 32-entry LRU: at least 8
    // evictions, and the retained set stays at the cap.
    expect(runtime.parsedEvictions, greaterThanOrEqualTo(8));
    expect(runtime.parsedTileCount, lessThanOrEqualTo(32));

    // Re-decoding an evicted tile parses again and keeps counting.
    await tester.runAsync(() async {
      await runtime.decoder(buildTestTile(), 10, 100, 60);
    });
    expect(runtime.parsedEvictions, greaterThanOrEqualTo(9));
  });
}
