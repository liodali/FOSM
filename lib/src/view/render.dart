import 'package:flutter/material.dart';
import 'package:fosm/src/api/geo_point.dart';

import '../api/tile.dart';

const tileWidth = 256;
const tileHeight = 256;

class RenderCanvasOSM extends CustomPainter {
  final int horizontalTileCount;
  final int verticalTileCount;
  final int leftColumnTilesLngIndex;
  final int topRowTilesLatIndex;
  final double leftColumnTilesCanvasX;
  final double topRowTilesCanvasY;
  final List<Tile> tiles;

  final LatLng latLng;
  final int zoom;

  RenderCanvasOSM({
    required this.horizontalTileCount,
    required this.verticalTileCount,
    required this.leftColumnTilesLngIndex,
    required this.topRowTilesLatIndex,
    required this.leftColumnTilesCanvasX,
    required this.topRowTilesCanvasY,
    required this.latLng,
    required this.tiles,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint();

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileCanvasX = leftColumnTilesCanvasX + hIndex * tileWidth;
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;
      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileCanvasY = topRowTilesCanvasY + vIndex * tileHeight;
        final tileLatIndex = topRowTilesLatIndex + vIndex;
        final index = tiles.indexWhere((element) =>
            element.latIndex == tileLatIndex &&
            element.lngIndex == tileLngIndex);
        // Draw a checker board pattern as a substrate for the tile while it is loading
        if ((index != -1 && tiles[index].sourceTile == null) || index == -1) {
          for (var x = 0; x < tileWidth / 8; x++) {
            for (var y = 0; y < tileHeight / 8; y++) {
              //canvas.fillStyle = x % 2 === 0 ^ y % 2 === 0 ? 'silver' : 'white';

              canvas.drawRect(
                Rect.fromLTRB(tileCanvasX + x * 8, tileCanvasY + y * 8, 8, 8),
                Paint()
                  ..filterQuality = FilterQuality.medium
                  ..color = Colors.grey,
              );
              // else if (index != -1 && tiles[index].sourceTile != null ) {
              //   canvas.drawImage(tiles[index].sourceTile!,
              //       Offset(tileCanvasX, tileCanvasY), paint);
              //   canvas.restore();
              //   canvas.drawRect(
              //     Rect.fromLTRB(tileCanvasX + x * 8, tileCanvasY + y * 8, 8, 8),
              //     Paint()
              //       ..filterQuality = FilterQuality.medium
              //       ..color = Colors.grey,
              //   );
            }
          }
        }

        if (index != -1 && tiles[index].sourceTile != null) {
          canvas.drawImage(tiles[index].sourceTile!,
              Offset(tileCanvasX, tileCanvasY), paint);
          //  canvas.restore();
        }
      }
    }
    // canvas.drawImage(, Offset(0,0), paint);
  }

  @override
  bool shouldRepaint(covariant RenderCanvasOSM oldDelegate) {
    return oldDelegate.latLng != this.latLng ||
        oldDelegate.zoom != zoom ||
        tiles.isNotEmpty ||
        oldDelegate.tiles.where((element) {
          final index = tiles.indexWhere((tile) => tile.index == element.index);

          return tiles[index].sourceTile != element.sourceTile;
        }).isNotEmpty;
  }
}
