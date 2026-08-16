import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/vector/style/style_parser.dart';

import 'mvt_builder.dart';

/// Style used by the pipeline tests: red background, blue water fill on
/// the `water` source-layer, one text label layer. All tile URLs point at
/// an invalid host — nothing here touches the network.
LoadedVectorStyle buildLoadedStyle() {
  final style = parseStyleJson(jsonEncode({
    'version': 8,
    'sources': {
      'openmaptiles': {
        'type': 'vector',
        'tiles': ['https://example.invalid/{z}/{x}/{y}.pbf'],
        'maxzoom': 12,
      },
    },
    'layers': [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#ff0000'},
      },
      {
        'id': 'water',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'paint': {'fill-color': '#0000ff'},
      },
      {
        'id': 'water-labels',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'layout': {'text-field': ['get', 'class']},
      },
    ],
  }));
  return LoadedVectorStyle(
    style: style,
    sources: const {
      'openmaptiles': ResolvedTileSource(
        name: 'openmaptiles',
        type: 'vector',
        urlTemplate: 'https://example.invalid/{z}/{x}/{y}.pbf',
        maxZoom: 12,
      ),
    },
  );
}

/// Left half of the tile is blue water, the rest shows the red background.
Uint8List buildHalfWaterTile() {
  final builder = MvtBuilder()
    ..addLayer(
      name: 'water',
      keys: const ['class'],
      values: const ['ocean'],
      features: [
        TestFeature(
          id: 1,
          type: TestGeomType.polygon,
          tags: const [0, 0],
          geometryCommands: polygonRingCommands(
            const [(0, 0), (2048, 0), (2048, 4096), (0, 4096)],
          ),
        ),
        TestFeature(
          id: 2,
          type: TestGeomType.point,
          tags: const [0, 0],
          geometryCommands: pointCommands(1024, 2048),
        ),
      ],
    );
  return builder.build();
}

/// A tiny RGBA pixel reader over raw [ByteData] from `toByteData()`.
class Pixels {
  final ByteData data;
  final int width;

  Pixels(this.data, this.width);

  int red(int x, int y) => data.getUint8((y * width + x) * 4);
  int green(int x, int y) => data.getUint8((y * width + x) * 4 + 1);
  int blue(int x, int y) => data.getUint8((y * width + x) * 4 + 2);
  int alpha(int x, int y) => data.getUint8((y * width + x) * 4 + 3);
}

void main() {
  group('VectorTileRenderer', () {
    testWidgets('renders background + fill with correct pixels', (tester) async {
      final loaded = buildLoadedStyle();
      final renderer = VectorTileRenderer(loaded);
      final decoded = decodeVectorTile(buildHalfWaterTile());

      final image = await tester.runAsync(() async {
        final picture = renderer.render(
          decoded: decoded,
          srcZ: 12,
          z: 12,
          x: 3,
          y: 2,
        );
        final img = await picture.toImage(256, 256);
        picture.dispose();
        return img;
      });
      expect(image, isNotNull);
      expect(image!.width, 256);
      expect(image.height, 256);

      final bytes = await tester.runAsync(() => image.toByteData());
      expect(bytes, isNotNull);
      final pixels = Pixels(bytes!, 256);

      // Left half: opaque blue. Right half: opaque red background.
      expect(pixels.blue(10, 128), 255);
      expect(pixels.red(10, 128), 0);
      expect(pixels.alpha(10, 128), 255);
      expect(pixels.red(246, 128), 255);
      expect(pixels.blue(246, 128), 0);
      expect(pixels.alpha(246, 128), 255);
    });

    testWidgets('over-zoom renders the parent sub-rect', (tester) async {
      final loaded = buildLoadedStyle();
      final renderer = VectorTileRenderer(loaded);
      final decoded = decodeVectorTile(buildHalfWaterTile());

      Future<ui.Image> renderAt(int z, int x, int y) async {
        final picture = renderer.render(
          decoded: decoded,
          srcZ: 12,
          z: z,
          x: x,
          y: y,
        );
        final img = await picture.toImage(256, 256);
        picture.dispose();
        return img;
      }

      final images = await tester.runAsync(
        () => Future.wait([renderAt(13, 6, 4), renderAt(13, 7, 4)]),
      );
      final leftChild = images![0];
      final rightChild = images[1];

      final leftBytes = await tester.runAsync(() => leftChild.toByteData());
      final rightBytes = await tester.runAsync(() => rightChild.toByteData());
      final leftPixels = Pixels(leftBytes!, leftChild.width);
      final rightPixels = Pixels(rightBytes!, rightChild.width);

      // Child (6, 4) is the top-left quadrant of the parent: entirely
      // inside the blue half. Child (7, 4) is the top-right: all red.
      expect(leftPixels.blue(128, 128), 255);
      expect(leftPixels.red(128, 128), 0);
      expect(rightPixels.red(128, 128), 255);
      expect(rightPixels.blue(128, 128), 0);
    });
  });

  group('TileManager vector mode', () {
    testWidgets('namespaced keys + full fetch/decode/render cycle',
        (tester) async {
      final tileBytes = buildHalfWaterTile();
      final runtime = VectorTileRuntime(
        loaded: buildLoadedStyle(),
        namespace: 'pipeline-test',
        parseInIsolate: false,
      );

      final manager = TileManager.init(
        width: 256,
        height: 256,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) async => tileBytes,
        decoder: runtime.decoder,
        cacheNamespace: runtime.namespace,
        tilePadding: 0,
        preloadAdjacentZoom: false,
      );

      manager.calculate();

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      expect(manager.renderTiles, isNotEmpty);
      for (final tile in manager.renderTiles) {
        expect(tile.index, startsWith('pipeline-test/'));
        expect(tile.sourceTile, isNotNull,
            reason: 'tile ${tile.index} should have rendered');
      }

      // The parsed source tile is shared and cached for the label overlay.
      final anyTile = manager.renderTiles.first;
      final parts = anyTile.index.split('/');
      final parsed = runtime.parsedTileFor(
        int.parse(parts[1]),
        int.parse(parts[2]),
        int.parse(parts[3]),
      );
      expect(parsed, isNotNull);
      expect(parsed!.decoded.layerByName('water'), isNotNull);

      // Label overlay paints without throwing (symbol layer present).
      final overlay = runtime.createLabelOverlay();
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        overlay.paint(
          canvas,
          const ui.Size(256, 256),
          zoom: 12,
          leftColumnTilesCanvasX: 0,
          topRowTilesCanvasY: 0,
          leftColumnTilesLngIndex: int.parse(parts[2]),
          topRowTilesLatIndex: int.parse(parts[3]),
          tiles: manager.renderTiles,
        );
        recorder.endRecording().dispose();
      });

      manager.dispose();
      runtime.dispose();
    });
  });
}
