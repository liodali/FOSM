import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:fosm/src/vector/render/label_overlay.dart';
import 'package:fosm/src/vector/render/vector_trace.dart';

/// Paints the OSM tile grid onto a [CustomPaint] canvas.
///
/// Tiles with a loaded image are drawn directly; tiles still loading are
/// drawn as a subtle checkerboard placeholder (matching the original JS
/// implementation).
///
/// The [revision] counter (bumped by [TileManager] on content/membership
/// changes) plus the canvas anchors and [tileScale] drive
/// [shouldRepaint] — much cheaper than comparing image references one by
/// one, while camera-only motion (no revision bump) still repaints at its
/// new position.
class RenderCanvasOSM extends CustomPainter {
  /// Total `paint` invocations across the process. Diagnostics only:
  /// the plan-12 retained-grid-layer candidate asserts this counter stays
  /// flat across sub-tile camera motion, and device captures cross-check
  /// it against the `paint.grid` span count.
  static int debugPaintCount = 0;

  final int horizontalTileCount;
  final int verticalTileCount;
  final int leftColumnTilesLngIndex;
  final int topRowTilesLatIndex;
  final double leftColumnTilesCanvasX;
  final double topRowTilesCanvasY;
  final List<Tile> tiles;
  final int revision;
  final double tileScale;
  final bool paintBackground;
  final bool paintPlaceholders;

  /// Vector payloads set this: their captured tile images may exceed the
  /// 256 px tile-space resolution (the `fosm.vectorTileResolution` knob),
  /// so non-preview images are drawn mapped onto the cell rect. Raster
  /// imagery keeps the historical natural-size path (drawn at its own
  /// pixel size × `tileScale`) regardless of the source resolution —
  /// raster output is pixel-identical to the pre-knob painter.
  final bool fitImagesToTile;

  RenderCanvasOSM({
    required this.horizontalTileCount,
    required this.verticalTileCount,
    required this.leftColumnTilesLngIndex,
    required this.topRowTilesLatIndex,
    required this.leftColumnTilesCanvasX,
    required this.topRowTilesCanvasY,
    required this.tiles,
    required this.revision,
    this.tileScale = 1,
    this.paintBackground = true,
    this.paintPlaceholders = true,
    this.fitImagesToTile = false,
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

  /// The reusable checkerboard picture whose top-left cell is dark for
  /// even `(lngIndex + latIndex)` parity. Shared with the zoom-fallback
  /// painter so both layers replay identical placeholders.
  static ui.Picture checkerPicture(bool darkTopLeft) => darkTopLeft
      ? (_checkerEven ??= _checkerPicture(true))
      : (_checkerOdd ??= _checkerPicture(false));

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
    debugPaintCount++;
    // Phase-12 attribution: duration span per repaint (spans arm only; no
    // Timeline event, the trace arm reads paint CPU from the profiler).
    final spanStart = VectorSpanLog.enabled ? VectorSpanLog.nowUs() : 0;
    // Background fill so any sub-pixel gaps between tiles aren't black.
    if (paintBackground) {
      canvas.drawRect(Offset.zero & size, _checkerLightPaint);
    }

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileCanvasX =
          leftColumnTilesCanvasX + hIndex * tileWidth * tileScale;
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;

      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileCanvasY =
            topRowTilesCanvasY + vIndex * tileHeight * tileScale;
        final tileLatIndex = topRowTilesLatIndex + vIndex;

        // tiles is row-major: h outer, v inner → index = h * verticalTileCount + v
        final listIndex = hIndex * verticalTileCount + vIndex;
        final tile = (listIndex < tiles.length) ? tiles[listIndex] : null;
        final image = tile?.sourceTile;

        if (image != null) {
          if (tile!.isPreview) {
            canvas.drawImageRect(
                image,
                ui.Rect.fromLTWH(
                    0, 0, image.width.toDouble(), image.height.toDouble()),
                ui.Rect.fromLTWH(tileCanvasX, tileCanvasY,
                    tileWidth * tileScale, tileHeight * tileScale),
                _imagePaint);
          } else if (fitImagesToTile && image.width != tileWidth) {
            // Vector capture above the tile-space resolution: map natural
            // pixels onto the cell rect uniformly (scale then draw at
            // natural size, so a resolution knob never leaks past the
            // cell). Raster imagery never enters this branch.
            final drawScale = tileWidth * tileScale / image.width;
            canvas.save();
            canvas.translate(tileCanvasX, tileCanvasY);
            canvas.scale(drawScale);
            canvas.drawImage(image, Offset.zero, _imagePaint);
            canvas.restore();
          } else if (tileScale == 1) {
            canvas.drawImage(
                image, Offset(tileCanvasX, tileCanvasY), _imagePaint);
          } else {
            canvas.save();
            canvas.translate(tileCanvasX, tileCanvasY);
            canvas.scale(tileScale);
            canvas.drawImage(image, Offset.zero, _imagePaint);
            canvas.restore();
          }
        } else if (paintPlaceholders) {
          final darkTopLeft = (tileLngIndex + tileLatIndex) % 2 == 0;
          // One pre-rasterized image draw per missing tile
          // (`fosm.gridPlaceholderImage`, on by default). On a device the
          // picture replay below cost about 150 us per tile against about
          // 6 us for an image draw, and dominated the grid repaint.
          final checker = placeholderImage ? _checkerImage(darkTopLeft) : null;
          if (checker != null) {
            canvas.drawImageRect(
                checker,
                ui.Rect.fromLTWH(
                    0, 0, tileWidth.toDouble(), tileHeight.toDouble()),
                ui.Rect.fromLTWH(tileCanvasX, tileCanvasY,
                    tileWidth * tileScale, tileHeight * tileScale),
                _checkerImagePaint);
          } else {
            // Reusable checkerboard placeholder — a single picture replay
            // per missing tile instead of hundreds of rect draws. The
            // picture is recorded at (0,0), so translate to the tile origin.
            final picture = checkerPicture(darkTopLeft);
            canvas
              ..save()
              ..translate(tileCanvasX, tileCanvasY)
              ..scale(tileScale)
              ..drawPicture(picture)
              ..restore();
          }
        }
      }
    }
    if (VectorSpanLog.enabled) {
      VectorSpanLog.record('paint.grid', null, spanStart,
          VectorSpanLog.nowUs() - spanStart);
    }
  }

  /// Draws missing-tile placeholders as one pre-rasterized image instead of
  /// replaying the checkerboard picture. On by default: on an iPhone 12 mini
  /// the replay cost about 150 us per tile against about 6 us for an image
  /// draw and made up 95 % of the grid repaint (warm pinch UI p99 8.9 to
  /// 3.8 ms, warm fling 4.5 to 2.8 ms). Edges differ from the replay by at
  /// most 14/255 per channel at fractional offsets. Revert per build with
  /// `--dart-define=fosm.gridPlaceholderImage=false`. Non-const so tests can
  /// toggle it.
  static bool placeholderImage =
      const bool.fromEnvironment('fosm.gridPlaceholderImage',
          defaultValue: true);

  static final Paint _checkerImagePaint = Paint()
    ..filterQuality = FilterQuality.none;
  static ui.Image? _checkerImageEven;
  static ui.Image? _checkerImageOdd;
  static bool _checkerImageFailed = false;

  /// The checkerboard rasterized once at tile size, or null when the
  /// platform cannot snapshot synchronously (callers fall back to the
  /// picture replay).
  static ui.Image? _checkerImage(bool darkTopLeft) {
    if (_checkerImageFailed) return null;
    final cached = darkTopLeft ? _checkerImageEven : _checkerImageOdd;
    if (cached != null) return cached;
    try {
      final image =
          checkerPicture(darkTopLeft).toImageSync(tileWidth, tileHeight);
      if (darkTopLeft) {
        _checkerImageEven = image;
      } else {
        _checkerImageOdd = image;
      }
      return image;
    } catch (_) {
      _checkerImageFailed = true;
      return null;
    }
  }

  /// Whether the pre-rasterized placeholder is usable on this platform.
  @visibleForTesting
  static bool get debugCheckerImageAvailable => _checkerImage(true) != null;

  @override
  bool shouldRepaint(covariant RenderCanvasOSM oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.tileScale != tileScale ||
      oldDelegate.leftColumnTilesCanvasX != leftColumnTilesCanvasX ||
      oldDelegate.topRowTilesCanvasY != topRowTilesCanvasY ||
      oldDelegate.paintBackground != paintBackground ||
      oldDelegate.paintPlaceholders != paintPlaceholders ||
      oldDelegate.fitImagesToTile != fitImagesToTile;
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
  final double tileScale;

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
    this.tileScale = 1,
    required this.zoom,
    required this.overlay,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    overlay?.paint(
      canvas,
      size,
      zoom: zoom,
      tileScale: tileScale,
      leftColumnTilesCanvasX: leftColumnTilesCanvasX,
      topRowTilesCanvasY: topRowTilesCanvasY,
      leftColumnTilesLngIndex: leftColumnTilesLngIndex,
      topRowTilesLatIndex: topRowTilesLatIndex,
      tiles: tiles,
    );
  }

  @override
  bool shouldRepaint(covariant VectorLabelPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.zoom != zoom ||
      oldDelegate.tileScale != tileScale ||
      oldDelegate.overlay != overlay ||
      oldDelegate.leftColumnTilesLngIndex != leftColumnTilesLngIndex ||
      oldDelegate.topRowTilesLatIndex != topRowTilesLatIndex ||
      oldDelegate.leftColumnTilesCanvasX != leftColumnTilesCanvasX ||
      oldDelegate.topRowTilesCanvasY != topRowTilesCanvasY ||
      oldDelegate.tiles != tiles;
}
