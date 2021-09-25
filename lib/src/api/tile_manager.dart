import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:fosm/fosm.dart';

import '../common/osm_transformation_utilities.dart';
import '../common/utils.dart';
import 'tile.dart';
import 'tile_source.dart';

class TileManager {
  int maxSizeTileCached = 1024 * 1024 * 12;

  List<Tile> _renderTiles = [];

  List<Tile> _cachedTiles = [];
  late int horizontalTileCount;
  late int verticalTileCount;
  late int leftColumnTilesLngIndex;
  late int topRowTilesLatIndex;
  late double leftColumnTilesCanvasX;
  late double topRowTilesCanvasY;
  late double centerTileLng;
  late double centerTileLat;
  late double centerCanvasX;
  late double centerCanvasY;
  double width;
  double height;
  LatLng centerLatLng;
  int zoom;

  TileManager.init({
    required this.width,
    required this.height,
    required this.centerLatLng,
    required this.zoom,
  }) {
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
    setCenterTile();
  }

  List<Tile> get renderTiles => _renderTiles;

  void setCenterTile({LatLng? latLng}) {
    if (latLng != null) centerLatLng = latLng;
    centerTileLng = lon2TileX(centerLatLng.longitude, zoom);
    centerTileLat = lat2TileY(centerLatLng.latitude, zoom);
  }

  void calculate(Function(VoidCallback fn) action) {
    action(() {
      Set<Tile> sets = _renderTiles.toSet();
      _cachedTiles.addAll(sets.toList());
      _renderTiles.clear();
    });
    final centerPointTileX = (centerTileLng % 1) * tileWidth;
    final centerPointTileY = (centerTileLat % 1) * tileHeight;

    final centerCanvasTileX = centerCanvasX - centerPointTileX;
    final centerCanvasTileY = centerCanvasY - centerPointTileY;

    final leftColumnsBeforeCenterCount = (centerCanvasTileX / tileWidth).ceil();
    leftColumnTilesCanvasX =
        centerCanvasTileX - leftColumnsBeforeCenterCount * tileWidth;

    final topRowsBeforeCenterCount = (centerCanvasTileY / tileHeight).ceil();
    topRowTilesCanvasY =
        centerCanvasTileY - topRowsBeforeCenterCount * tileHeight;

    final centerTileLngIndex = centerTileLng.floor();
    leftColumnTilesLngIndex = centerTileLngIndex - leftColumnsBeforeCenterCount;

    final centerTileLatIndex = centerTileLat.floor();
    topRowTilesLatIndex = centerTileLatIndex - topRowsBeforeCenterCount;

    horizontalTileCount =
        ((width + -leftColumnTilesCanvasX) / tileWidth).ceil();
    verticalTileCount = ((height + -topRowTilesCanvasY) / tileHeight).ceil();

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;
      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileLatIndex = topRowTilesLatIndex + vIndex;
        // Draw a checker board pattern as a substrate for the tile while it is loading

        action(() {
          for (var x = 0; x < tileWidth / 8; x++) {
            for (var y = 0; y < tileHeight / 8; y++) {
              //renderTiles.add();
              _renderTiles.add(Tile(
                null,
                "$tileLngIndex-$tileLatIndex",
                tileLatIndex,
                tileLngIndex,
              ));
            }
          }
        });
        Future.microtask(() async {
          final index = _renderTiles.indexWhere(
              (element) => element.index == "$tileLngIndex-$tileLatIndex");
          final indexOld = _cachedTiles.indexWhere(
              (element) => element.index == "$tileLngIndex-$tileLatIndex");
          if (index == -1 && indexOld == -1) {
            final imageTile = await getTile(zoom, tileLngIndex, tileLatIndex);
            ui.Codec codec =
                await ui.instantiateImageCodec(imageTile.toUint8List());
            ui.FrameInfo fi = await codec.getNextFrame();
            action(() {
              _renderTiles.add(Tile(
                fi.image,
                "$tileLngIndex-$tileLatIndex",
                tileLatIndex,
                tileLngIndex,
              ));
            });
          } else if (_renderTiles[index].sourceTile == null && indexOld == -1) {
            final imageTile = await getTile(zoom, tileLngIndex, tileLatIndex);
            ui.Codec codec =
                await ui.instantiateImageCodec(imageTile.toUint8List());
            ui.FrameInfo fi = await codec.getNextFrame();
            action(() {
              _renderTiles[index] = Tile(
                fi.image,
                "$tileLngIndex-$tileLatIndex",
                tileLatIndex,
                tileLngIndex,
              );
            });
          } else {
            if (_cachedTiles.isNotEmpty) {
              action(() {
                _renderTiles[index] = _cachedTiles[indexOld];
              });
            }
          }
        });
      }
    }
  }
}
