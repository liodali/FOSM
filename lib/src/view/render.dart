import 'package:flutter/material.dart';

import '../api/tile.dart';
import '../common/utils.dart';
import '../vector/render/label_overlay.dart';

/// Paints the OSM tile grid onto a [CustomPaint] canvas.
///
/// Tiles with a loaded image are drawn directly; tiles still loading are
/// drawn as a subtle checkerboard placeholder (matching the original JS
/// implementation).
///
/// The [revision] counter (bumped by [TileManager] on every visible
/// change) drives [shouldRepaint] — much cheaper than comparing image
/// references one by one.
class RenderCanvasOSM extends CustomPainter {
  final int horizontalTileCount;
  final int verticalTileCount;
  final int leftColumnTilesLngIndex;
  final int topRowTilesLatIndex;
  final double leftColumnTilesCanvasX;
  final double topRowTilesCanvasY;
  final List<Tile> tiles;
  final int revision;

  /// Current zoom — vector styles evaluate paint properties per zoom.
  final int zoom;

  /// Vector label overlay, painted above the tile grid. Null in raster
  /// mode (and for the zoom-animation snapshot, where labels pause).
  final LabelOverlay? overlay;

  RenderCanvasOSM({
    required this.horizontalTileCount,
    required this.verticalTileCount,
    required this.leftColumnTilesLngIndex,
    required this.topRowTilesLatIndex,
    required this.leftColumnTilesCanvasX,
    required this.topRowTilesCanvasY,
    required this.tiles,
    required this.revision,
    this.zoom = 0,
    this.overlay,
  });

  static const Color _checkerLight = Color(0xFFF5F5F5);
  static const Color _checkerDark = Color(0xFFDDDDDD);

  static final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium;

  static final Paint _checkerLightPaint = Paint()..color = _checkerLight;
  static final Paint _checkerDarkPaint = Paint()..color = _checkerDark;

  @override
  void paint(Canvas canvas, Size size) {
    // Background fill so any sub-pixel gaps between tiles aren't black.
    canvas.drawRect(Offset.zero & size, _checkerLightPaint);

    const cell = 8.0;
    final cellsPerTileX = tileWidth ~/ cell;
    final cellsPerTileY = tileHeight ~/ cell;

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileCanvasX = leftColumnTilesCanvasX + hIndex * tileWidth;
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;

      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileCanvasY = topRowTilesCanvasY + vIndex * tileHeight;
        final tileLatIndex = topRowTilesLatIndex + vIndex;

        // tiles is row-major: h outer, v inner → index = h * verticalTileCount + v
        final listIndex = hIndex * verticalTileCount + vIndex;
        final tile =
            (listIndex < tiles.length) ? tiles[listIndex] : null;
        final image = tile?.sourceTile;

        if (image != null) {
          canvas.drawImage(image, Offset(tileCanvasX, tileCanvasY), _imagePaint);
        } else {
          // Checkerboard placeholder — alternating colors give a "loading"
          // feel identical to the JS reference implementation.
          _drawCheckerboard(
            canvas,
            tileCanvasX,
            tileCanvasY,
            tileLngIndex,
            tileLatIndex,
            cellsPerTileX,
            cellsPerTileY,
            cell,
          );
        }
      }
    }

    // Vector labels sit above every tile (they need viewport-level
    // collision, not per-tile rendering).
    overlay?.paint(
      canvas,
      size,
      zoom: zoom,
      leftColumnTilesCanvasX: leftColumnTilesCanvasX,
      topRowTilesCanvasY: topRowTilesCanvasY,
      leftColumnTilesLngIndex: leftColumnTilesLngIndex,
      topRowTilesLatIndex: topRowTilesLatIndex,
      tiles: tiles,
    );
  }

  void _drawCheckerboard(
    Canvas canvas,
    double originX,
    double originY,
    int lngIndex,
    int latIndex,
    int cellsX,
    int cellsY,
    double cell,
  ) {
    // Fill the whole tile with the light color first (halves draw calls).
    canvas.drawRect(
      Rect.fromLTWH(originX, originY, tileWidth.toDouble(), tileHeight.toDouble()),
      _checkerLightPaint,
    );

    // Global cell coordinates so the pattern is stable across the world
    // (doesn't "swim" relative to tiles during panning).
    final baseColX = lngIndex * cellsX;
    final baseColY = latIndex * cellsY;

    for (var cx = 0; cx < cellsX; cx++) {
      for (var cy = 0; cy < cellsY; cy++) {
        final isDark = ((baseColX + cx) + (baseColY + cy)) % 2 == 0;
        if (!isDark) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            originX + cx * cell,
            originY + cy * cell,
            cell,
            cell,
          ),
          _checkerDarkPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant RenderCanvasOSM oldDelegate) =>
      oldDelegate.revision != revision;
}
