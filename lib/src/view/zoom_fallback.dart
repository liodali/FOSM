import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:fosm/src/view/render.dart';

/// One imagery draw inside a fallback region: [image] (pinned in the
/// rendered cache) cropped to [srcUnit] (fractions of the source image)
/// and painted into [dstUnit] (fractions of the missing cell's rect).
class _FallbackDraw {
  const _FallbackDraw(this.image, this.srcUnit, this.dstUnit);

  final ui.Image image;
  final Rect srcUnit;
  final Rect dstUnit;
}

/// Fallback coverage for one missing visible cell. Holds the full-cell
/// ancestor base (when retained), the sharper descendant draws that
/// refine it, and the pin release callback that frees those images once
/// the region retires.
class _FallbackRegion {
  _FallbackRegion(
      this.cellKey, this.base, this.refinements, this.sourceKeys, this.release);

  final String cellKey;

  /// Full-cell ancestor crop beneath the refinements, when one is
  /// retained. Covers the whole cell, so holes left by missing
  /// descendants can never reveal another zoom's stale geometry.
  final _FallbackDraw? base;

  /// Sharper descendant draws over [base]. Each one must be isolated
  /// from it (see [ZoomFallbackPainter]): transparent descendant pixels
  /// blend against the plain background, never the old-zoom crop.
  final List<_FallbackDraw> refinements;

  /// Cache keys of every image the draws reference — also the keys pinned.
  final Set<String> sourceKeys;
  final VoidCallback release;
}

/// Geographic fallback coverage for the visible grid, region by region.
///
/// While the current grid has missing visible cells, each missing cell is
/// covered by the sharpest retained imagery for the same geographic
/// region: available descendants compose over the nearest retained
/// ancestor crop. Regions retire independently — the moment a cell's own
/// tile publishes, that region releases its pins, so replaced areas never
/// keep old-zoom images alive (and, because the fallback painter stops
/// painting them, transparent replacement tiles can never expose stale
/// data underneath).
///
/// Regions are derived from the live grid on every [reconcile], so the
/// fallback stays geographically aligned while panning mid-transition and
/// survives repeated source-zoom reversals: a cell simply looks up
/// whichever zooms are still retained.
///
/// Bounds:
/// * at most one region per missing visible cell;
/// * at most [maxDrawsPerRegion] draws per region;
/// * every referenced image is pinned for the region's lifetime and
///   released exactly once on retirement/clear/dispose.
class ZoomFallbackCoverage {
  ZoomFallbackCoverage(this.manager);

  final TileManager manager;

  /// How many ancestor zooms above the grid zoom are searched for a base
  /// crop. Level 1 (2× upscale) is preferred; deeper levels only fill in
  /// when nearer ancestors were never retained.
  static const int maxAncestorLevels = 3;

  /// How many descendant zooms below the grid zoom refine the region.
  /// Descendants are sharper than the cell itself, so they overlay the
  /// blurrier ancestor base (zoom-out continuity: the recently viewed
  /// sharper grid composes back over its parent).
  static const int maxChildDepth = 2;

  /// Hard cap on draws per region, bounding overdraw and the number of
  /// images one cell can pin.
  static const int maxDrawsPerRegion = 16;

  final Map<String, _FallbackRegion> _regions = {};
  int _lastReconciledRevision = -1;
  bool _suspended = false;
  int _suspendedGridRevision = -1;
  bool _disposed = false;

  /// Pin held across a zoom switch (see [beginZoomTransition]) and
  /// released by the next [reconcile] once region pins took over.
  VoidCallback? _transitionRelease;

  /// Bumped whenever the region set changes, so painters can compare.
  int _version = 0;

  /// Number of currently covered cells.
  int get regionCount => _regions.length;

  /// Whether any cell currently has fallback coverage.
  bool get hasRegions => _regions.isNotEmpty;

  /// Whether [cellKey] currently shows fallback imagery. A region exists
  /// only while its source images are retained (it pins them for its
  /// lifetime), and suspension/clear drops regions outright — so presence
  /// is exactly "this cell is painted with fallback imagery now".
  bool coversCell(String cellKey) => _regions.containsKey(cellKey);

  /// Monotonic change token for `shouldRepaint`.
  int get version => _version;

  /// The region covering [cellKey], if any. Same library as the painter.
  _FallbackRegion? _region(String cellKey) => _regions[cellKey];

  /// Cache keys backing the region for [cellKey] (test hook).
  @visibleForTesting
  List<String> debugRegionSourceKeys(String cellKey) =>
      _regions[cellKey]?.sourceKeys.toList() ?? const [];

  /// Number of imagery draws in the region for [cellKey] (test hook).
  @visibleForTesting
  int debugRegionDrawCount(String cellKey) {
    final region = _regions[cellKey];
    if (region == null) return 0;
    return (region.base == null ? 0 : 1) + region.refinements.length;
  }

  /// The covered cell keys (test hook).
  @visibleForTesting
  List<String> debugRegionKeys() => _regions.keys.toList();

  /// Reconciles coverage with the live grid. Cheap enough to call on
  /// every build: work only happens when the grid/content revision
  /// changed, and each revision's pass is a bounded walk over the
  /// visible cells with map lookups. A pending zoom-transition pin is
  /// released after the pass, so imagery the regions draw stays pinned
  /// and everything else becomes evictable again.
  void reconcile() {
    if (_disposed) return;
    final transition = _transitionRelease;
    _transitionRelease = null;
    try {
      _reconcileRegions();
    } finally {
      transition?.call();
    }
  }

  void _reconcileRegions() {
    final manager = this.manager;
    if (_suspended) {
      // A settle-timeout dropped the fallback for this grid window; a new
      // window or zoom step (grid revision bump) re-enables it.
      if (manager.gridRevision == _suspendedGridRevision) return;
      _suspended = false;
    }
    final revision = manager.revision;
    if (revision == _lastReconciledRevision) return;
    _lastReconciledRevision = revision;

    // Current missing visible cells (off-world rows can never load and
    // never have imagery, so they are skipped like everywhere else).
    final missing = <String>{};
    final missingCoords = <String, _TileCoord>{};
    final pad = manager.tilePadding;
    final paddedV = manager.verticalTileCount;
    final worldRows = 1 << manager.zoom;
    final tiles = manager.renderTiles;
    for (var h = 0; h < manager.visibleHorizontalCount; h++) {
      for (var v = 0; v < manager.visibleVerticalCount; v++) {
        final listIndex = (h + pad) * paddedV + pad + v;
        if (listIndex >= tiles.length) continue;
        final tile = tiles[listIndex];
        if (tile.latIndex < 0 || tile.latIndex >= worldRows) continue;
        if (tile.sourceTile != null) continue;
        missing.add(tile.index);
        missingCoords[tile.index] = _TileCoord(tile.lngIndex, tile.latIndex);
      }
    }

    var changed = false;
    // Retire regions whose cell loaded its own tile or left the window.
    // Their pins are released only after the new regions below acquired
    // theirs: old and new windows share imagery, and on a zero budget
    // releasing first would evict shared ancestors before the regions
    // that still need them can pin them.
    final retired = <_FallbackRegion>[];
    _regions.removeWhere((key, region) {
      if (missing.contains(key)) return false;
      retired.add(region);
      changed = true;
      return true;
    });
    // Cover newly missing cells with whatever retained imagery exists.
    for (final key in missing) {
      if (_regions.containsKey(key)) continue;
      final region = _buildRegion(manager, key, missingCoords[key]!);
      if (region != null) {
        _regions[key] = region;
        changed = true;
      }
    }
    // New pins are in place — obsolete imagery may become evictable.
    for (final region in retired) {
      region.release();
    }
    if (changed) _version++;
  }

  /// Builds the fallback for one missing cell: the nearest retained
  /// ancestor crop as a full-cell base, then descendant refinement on
  /// top. Returns `null` when nothing retained covers the cell.
  _FallbackRegion? _buildRegion(
      TileManager manager, String cellKey, _TileCoord cell) {
    final z = manager.zoom;
    final sourceKeys = <String>{};

    // Base: nearest retained ancestor.
    _FallbackDraw? base;
    final baseEntry = _nearestAncestor(manager, z, cell);
    if (baseEntry != null) {
      final span = 1 << baseEntry.$3;
      final unit = 1.0 / span;
      base = _FallbackDraw(
        baseEntry.$2,
        Rect.fromLTWH(
            (cell.x % span) * unit, (cell.y % span) * unit, unit, unit),
        const Rect.fromLTWH(0, 0, 1, 1),
      );
      sourceKeys.add(baseEntry.$1);
    }

    // Refinement: available descendants overlay the base quadrant by
    // quadrant, recursively filling gaps with deeper descendants. The
    // draw budget covers base plus refinements together.
    final refinements = <_FallbackDraw>[];
    final budget = maxDrawsPerRegion - (base == null ? 0 : 1);
    _refineWithChildren(manager, z, cell.x, cell.y,
        const Rect.fromLTWH(0, 0, 1, 1), 0, refinements, sourceKeys, budget);

    if (base == null && refinements.isEmpty) return null;
    return _FallbackRegion(cellKey, base, refinements, sourceKeys,
        manager.pinRenderedImages(sourceKeys));
  }

  /// Nearest retained ancestor of `(z, x, y)` within
  /// [maxAncestorLevels]. Returns the cache key, image and level.
  (String, ui.Image, int)? _nearestAncestor(
      TileManager manager, int z, _TileCoord cell) {
    for (var level = 1; level <= maxAncestorLevels; level++) {
      final ancestorZoom = z - level;
      if (ancestorZoom < 0) break;
      final x = cell.x >> level;
      final y = cell.y >> level;
      final entry = _imageFor(manager, ancestorZoom, x, y);
      if (entry != null) return (entry.$1, entry.$2, level);
    }
    return null;
  }

  /// Looks up a retained image for `(z, x, y)`, first by the grid's raw
  /// key convention, then by the wrapped-X canonical key — the antimeridian
  /// duplicate of a retained tile depicts the same region. Zooms beyond
  /// the manager's supported range can never be cached, so they skip the
  /// wrap arithmetic (which would overflow 32-bit web ints past 30).
  (String, ui.Image)? _imageFor(TileManager manager, int z, int x, int y) {
    if (z > 30 || z < 0) return null;
    final rawKey = manager.renderTileKey(z, x, y);
    final raw = manager.retainedImage(rawKey);
    if (raw != null) return (rawKey, raw);
    final n = 1 << z;
    final wrappedX = ((x % n) + n) % n;
    if (wrappedX == x) return null;
    final wrappedKey = manager.renderTileKey(z, wrappedX, y);
    final wrapped = manager.retainedImage(wrappedKey);
    if (wrapped != null) return (wrappedKey, wrapped);
    return null;
  }

  void _refineWithChildren(
      TileManager manager,
      int z,
      int x,
      int y,
      Rect unit,
      int depth,
      List<_FallbackDraw> refinements,
      Set<String> sourceKeys,
      int budget) {
    if (depth >= maxChildDepth) return;
    for (var i = 0; i < 2; i++) {
      for (var j = 0; j < 2; j++) {
        if (refinements.length >= budget) return;
        final cx = 2 * x + i;
        final cy = 2 * y + j;
        final quadrant = Rect.fromLTWH(unit.left + i * unit.width / 2,
            unit.top + j * unit.height / 2, unit.width / 2, unit.height / 2);
        final entry = _imageFor(manager, z + 1, cx, cy);
        if (entry != null) {
          refinements.add(_FallbackDraw(
              entry.$2, const Rect.fromLTWH(0, 0, 1, 1), quadrant));
          sourceKeys.add(entry.$1);
        } else {
          _refineWithChildren(manager, z + 1, cx, cy, quadrant, depth + 1,
              refinements, sourceKeys, budget);
        }
      }
    }
  }

  /// Pins the currently loaded grid across an imminent source-zoom
  /// switch, so the rendered-cache budget cannot evict the old imagery
  /// between the switch and the [reconcile] that builds per-region pins.
  /// A repeated call (another step of the same gesture) replaces the
  /// pending pin with one over the now-current grid, exactly like the
  /// one-snapshot-per-gesture rule of the animated overlay.
  void beginZoomTransition() {
    if (_disposed) return;
    _transitionRelease?.call();
    _transitionRelease = null;
    _transitionRelease = manager.pinRenderedImages(manager.renderTiles
        .where((tile) => tile.sourceTile != null)
        .map((tile) => tile.index));
  }

  /// Releases every region. Used by camera commands and teardown paths
  /// that invalidate the fallback outright; later reconciles may rebuild
  /// regions for still-missing cells.
  void clear() {
    _transitionRelease?.call();
    _transitionRelease = null;
    if (_regions.isEmpty) return;
    final regions = List<_FallbackRegion>.of(_regions.values);
    _regions.clear();
    for (final region in regions) {
      region.release();
    }
    _version++;
  }

  /// Drops coverage and keeps it dropped until the grid membership
  /// changes (settle-timeout path): the still-missing cells fall back to
  /// checkerboards instead of holding old imagery indefinitely.
  void suspend() {
    clear();
    _suspended = true;
    _suspendedGridRevision = manager.gridRevision;
  }

  void dispose() {
    clear();
    _disposed = true;
  }
}

/// Integer tile coordinate of a missing cell.
class _TileCoord {
  const _TileCoord(this.x, this.y);

  final int x;
  final int y;
}

/// Paints per-region fallback coverage beneath the live tile grid.
///
/// For every missing visible cell this painter lays down, in order:
/// 1. the checkerboard placeholder (global parity continuity) — regions
///    draw over it, and cells without any retained imagery keep it;
/// 2. the region's imagery: the ancestor-crop base (if retained), then
///    descendant refinements — each cleared to the background first when
///    a base sits underneath, so transparent descendant pixels never
///    blend over old-zoom imagery.
///
/// A full-viewport opaque base is painted first: loaded replacement
/// tiles draw above this layer in the widget stack, and transparent ones
/// must blend against the same background the plain grid paints — never
/// against stale old-zoom imagery.
///
/// While this painter is present the grid painter skips its background
/// and placeholder passes, so the two never double-paint.
class ZoomFallbackPainter extends CustomPainter {
  ZoomFallbackPainter({
    required this.coverage,
    required this.manager,
  })  : revision = manager.revision,
        canvasX = manager.leftColumnTilesCanvasX,
        canvasY = manager.topRowTilesCanvasY,
        tileScale = manager.zoomScale,
        version = coverage.version;

  final ZoomFallbackCoverage coverage;
  final TileManager manager;

  // Snapshot fields for shouldRepaint — reading the live manager in
  // shouldRepaint would compare an object against itself.
  final int revision;
  final double canvasX;
  final double canvasY;
  final double tileScale;
  final int version;

  static final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium;
  static final Paint _basePaint = Paint()..color = const Color(0xFFF5F5F5);

  @override
  void paint(Canvas canvas, Size size) {
    // Opaque base under everything (background parity + alpha guard).
    canvas.drawRect(Offset.zero & size, _basePaint);

    final pad = manager.tilePadding;
    final paddedV = manager.verticalTileCount;
    final tileW = manager.renderedTileWidth;
    final tileH = manager.renderedTileHeight;
    final originX = manager.leftColumnTilesCanvasX;
    final originY = manager.topRowTilesCanvasY;
    final tiles = manager.renderTiles;

    for (var h = 0; h < manager.visibleHorizontalCount; h++) {
      for (var v = 0; v < manager.visibleVerticalCount; v++) {
        final listIndex = (h + pad) * paddedV + pad + v;
        if (listIndex >= tiles.length) continue;
        final tile = tiles[listIndex];
        if (tile.sourceTile != null) continue; // grid paints it above
        final cellX = originX + (pad + h) * tileW;
        final cellY = originY + (pad + v) * tileH;

        // Checkerboard placeholder, same parity rule as the grid painter.
        final picture = RenderCanvasOSM.checkerPicture(
            (tile.lngIndex + tile.latIndex) % 2 == 0);
        canvas
          ..save()
          ..translate(cellX, cellY)
          ..scale(tileW / tileWidth, tileH / tileHeight)
          ..drawPicture(picture)
          ..restore();

        final region = coverage._region(tile.index);
        if (region == null) continue;
        final base = region.base;
        if (base != null) {
          _drawImageUnit(canvas, base, cellX, cellY, tileW, tileH);
        }
        for (final draw in region.refinements) {
          final dst = Rect.fromLTRB(
            cellX + draw.dstUnit.left * tileW,
            cellY + draw.dstUnit.top * tileH,
            cellX + draw.dstUnit.right * tileW,
            cellY + draw.dstUnit.bottom * tileH,
          );
          if (dst.isEmpty) continue;
          if (base != null) {
            // Alpha isolation: a transparent descendant quadrant must
            // blend against the plain background, never against the
            // old-zoom ancestor crop underneath it.
            canvas.drawRect(dst, _basePaint);
          }
          final image = draw.image;
          final src = Rect.fromLTRB(
            draw.srcUnit.left * image.width,
            draw.srcUnit.top * image.height,
            draw.srcUnit.right * image.width,
            draw.srcUnit.bottom * image.height,
          );
          if (src.isEmpty) continue;
          canvas.drawImageRect(image, src, dst, _imagePaint);
        }
      }
    }
  }

  /// Draws one unit-rect imagery draw into the cell at `(cellX, cellY)`.
  void _drawImageUnit(Canvas canvas, _FallbackDraw draw, double cellX,
      double cellY, double tileW, double tileH) {
    final image = draw.image;
    final src = Rect.fromLTRB(
      draw.srcUnit.left * image.width,
      draw.srcUnit.top * image.height,
      draw.srcUnit.right * image.width,
      draw.srcUnit.bottom * image.height,
    );
    if (src.isEmpty) return;
    final dst = Rect.fromLTRB(
      cellX + draw.dstUnit.left * tileW,
      cellY + draw.dstUnit.top * tileH,
      cellX + draw.dstUnit.right * tileW,
      cellY + draw.dstUnit.bottom * tileH,
    );
    if (dst.isEmpty) return;
    canvas.drawImageRect(image, src, dst, _imagePaint);
  }

  @override
  bool shouldRepaint(ZoomFallbackPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.version != version ||
      oldDelegate.canvasX != canvasX ||
      oldDelegate.canvasY != canvasY ||
      oldDelegate.tileScale != tileScale;
}
