import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:fosm/src/vector/render/label_overlay.dart';

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

  RenderCanvasOSM({
    required this.horizontalTileCount,
    required this.verticalTileCount,
    required this.leftColumnTilesLngIndex,
    required this.topRowTilesLatIndex,
    required this.leftColumnTilesCanvasX,
    required this.topRowTilesCanvasY,
    required this.tiles,
    required this.revision,
  });

  static const Color _checkerLight = Color(0xFFF5F5F5);
  static const Color _checkerDark = Color(0xFFDDDDDD);

  static final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium;

  static final Paint _checkerLightPaint = Paint()..color = _checkerLight;
  static final Paint _checkerDarkPaint = Paint()..color = _checkerDark;

  /// Pre-recorded checkerboard pictures, one per tile parity. The parity
  /// is `(lngIndex + latIndex) % 2`, which determines the colour of the
  /// top-left cell, so adjacent tiles keep the global checker continuity.
  ///
  /// Recording once and replaying with a single `drawPicture` per missing
  /// tile replaces the old ~512 `drawRect` calls per tile (one base rect
  /// plus one rect per dark cell). For an empty 80-tile grid that cuts
  /// the display list from ~41 000 rect draws to 80 picture replays.
  static ui.Picture? _checkerEven; // dark top-left
  static ui.Picture? _checkerOdd; // light top-left

  static ui.Picture _checkerPicture(bool darkTopLeft) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const cell = 8.0;
    final cellsX = tileWidth ~/ cell;
    final cellsY = tileHeight ~/ cell;
    // Light base fills the whole tile.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, tileWidth.toDouble(), tileHeight.toDouble()),
      _checkerLightPaint,
    );
    for (var cx = 0; cx < cellsX; cx++) {
      for (var cy = 0; cy < cellsY; cy++) {
        final isDark = ((cx + cy) % 2 == 0) == darkTopLeft;
        if (!isDark) continue;
        canvas.drawRect(
          ui.Rect.fromLTWH(cx * cell, cy * cell, cell, cell),
          _checkerDarkPaint,
        );
      }
    }
    return recorder.endRecording();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Background fill so any sub-pixel gaps between tiles aren't black.
    canvas.drawRect(Offset.zero & size, _checkerLightPaint);

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileCanvasX = leftColumnTilesCanvasX + hIndex * tileWidth;
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;

      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileCanvasY = topRowTilesCanvasY + vIndex * tileHeight;
        final tileLatIndex = topRowTilesLatIndex + vIndex;

        // tiles is row-major: h outer, v inner → index = h * verticalTileCount + v
        final listIndex = hIndex * verticalTileCount + vIndex;
        final tile = (listIndex < tiles.length) ? tiles[listIndex] : null;
        final image = tile?.sourceTile;

        if (image != null) {
          canvas.drawImage(
              image, Offset(tileCanvasX, tileCanvasY), _imagePaint);
        } else {
          // Reusable checkerboard placeholder — a single picture replay
          // per missing tile instead of hundreds of rect draws. The
          // picture is recorded at (0,0), so translate to the tile origin.
          final darkTopLeft = (tileLngIndex + tileLatIndex) % 2 == 0;
          final picture = darkTopLeft
              ? (_checkerEven ??= _checkerPicture(true))
              : (_checkerOdd ??= _checkerPicture(false));
          canvas
            ..save()
            ..translate(tileCanvasX, tileCanvasY)
            ..drawPicture(picture)
            ..restore();
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant RenderCanvasOSM oldDelegate) =>
      oldDelegate.revision != revision;
}

/// Paints the vector label overlay (place names, road shields, POI icons)
/// for the whole viewport. Lives in its own [CustomPaint] above the marker
/// layer, so labels stay legible over markers while markers stay above
/// the tile grid.
///
/// Raster mode passes no [overlay] and the painter is a no-op.
class VectorLabelPainter extends CustomPainter {
  final int horizontalTileCount;
  final int verticalTileCount;
  final int leftColumnTilesLngIndex;
  final int topRowTilesLatIndex;
  final double leftColumnTilesCanvasX;
  final double topRowTilesCanvasY;
  final List<Tile> tiles;
  final int revision;

  /// Current zoom — styles evaluate paint properties per zoom.
  final int zoom;

  /// Vector label overlay. Null in raster mode (and during the
  /// zoom-animation snapshot, where labels pause).
  final LabelOverlay? overlay;

  VectorLabelPainter({
    required this.horizontalTileCount,
    required this.verticalTileCount,
    required this.leftColumnTilesLngIndex,
    required this.topRowTilesLatIndex,
    required this.leftColumnTilesCanvasX,
    required this.topRowTilesCanvasY,
    required this.tiles,
    required this.revision,
    required this.zoom,
    required this.overlay,
  });

  @override
  void paint(Canvas canvas, Size size) {
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

  @override
  bool shouldRepaint(covariant VectorLabelPainter oldDelegate) =>
      oldDelegate.revision != revision;
}
