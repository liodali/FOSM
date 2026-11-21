import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:fosm/src/view/render.dart';
import 'package:fosm/src/vector/render/vector_trace.dart';

/// One retained source image and its geographic tile coordinate.
///
/// [key] is deliberately opaque: raster keys are `z/x/y`, while vector keys
/// carry a style namespace. Coordinates are stored explicitly instead of
/// being recovered by parsing that cache identity.
class _FallbackSource {
  const _FallbackSource(this.key, this.image, this.z, this.x, this.y);

  final String key;
  final ui.Image image;
  final int z;
  final int x;
  final int y;
}

/// One imagery draw inside a fallback region: [source] (pinned in the
/// rendered cache) cropped to [srcUnit] (fractions of the source image)
/// and painted into [dstUnit] (fractions of the missing cell's rect).
class _FallbackDraw {
  const _FallbackDraw(this.source, this.srcUnit, this.dstUnit);

  final _FallbackSource source;
  final Rect srcUnit;
  final Rect dstUnit;

  ui.Image get image => source.image;
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

  /// Unique sources with explicit coordinates for the next reconcile's
  /// geographic carry. No cache-key parsing is involved.
  Iterable<_FallbackSource> get sources sync* {
    final seen = <String>{};
    final base = this.base;
    if (base != null && seen.add(base.source.key)) yield base.source;
    for (final draw in refinements) {
      if (seen.add(draw.source.key)) yield draw.source;
    }
  }
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
  /// crop before falling back to the cross-step carry (see
  /// [_carrySources]). Three nearest levels answer the common cases
  /// directly; deeper chains — several integer steps over blocked
  /// replacements — resolve through the carry instead of growing this
  /// fixed bound, so a z5→z12 walk stays covered without moving the
  /// cutoff (review round 2: depth 6 merely moved the z9 cutoff).
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
  bool _disposed = false;

  /// Geographic carry for one reconcile pass: the sources of the
  /// regions that existed *before* this pass — the previous generation's
  /// imagery. Their pins are still live during the pass (retired regions
  /// release only after the new regions acquire their own), so every
  /// carried image is guaranteed in-cache while looked up. Cleared at
  /// the end of the pass; carries no pins of its own and never outlives
  /// a reconcile, keeping ownership bounded to the visible missing
  /// regions (plan 09 review 2: the chain of integer steps stays covered
  /// at any depth instead of relying on a fixed ancestor cutoff).
  Map<String, _FallbackSource>? _carrySources;

  /// Pin held across a zoom switch (see [beginZoomTransition]) and
  /// released by the next [reconcile] once region pins took over.
  VoidCallback? _transitionRelease;

  /// Explicit source coordinates for the pinned pre-switch grid. These
  /// join the previous regions' carry for one reconcile, allowing even a
  /// direct multi-level zoom jump to crop retained descendant imagery.
  List<_FallbackSource>? _transitionSources;

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

  /// Source and destination unit rectangles for every draw in [cellKey]
  /// (test hook). Base first, then refinements.
  @visibleForTesting
  List<(Rect, Rect)> debugRegionDrawGeometry(String cellKey) {
    final region = _regions[cellKey];
    if (region == null) return const [];
    return [
      if (region.base != null) (region.base!.srcUnit, region.base!.dstUnit),
      for (final draw in region.refinements) (draw.srcUnit, draw.dstUnit),
    ];
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
    final transitionSources = _transitionSources;
    _transitionRelease = null;
    _transitionSources = null;
    try {
      _reconcileRegions(transitionSources ?? const []);
    } finally {
      transition?.call();
    }
  }

  void _reconcileRegions(List<_FallbackSource> transitionSources) {
    final manager = this.manager;
    final revision = manager.revision;
    if (revision == _lastReconciledRevision) return;
    _lastReconciledRevision = revision;

    // The cross-step carry: the previous generation's region sources plus
    // the pinned pre-switch grid, all still held by their pins for the
    // duration of this pass (release happens only after the new pins
    // acquire). Source coordinates are explicit and cache keys stay opaque,
    // so namespaced vector imagery follows exactly the same geographic path
    // as raster imagery, at any zoom separation.
    final carry = <String, _FallbackSource>{};
    for (final source in transitionSources) {
      carry[source.key] = source;
    }
    for (final region in _regions.values) {
      for (final source in region.sources) {
        carry[source.key] = source;
      }
    }
    _carrySources = carry;

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
    _carrySources = null;
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
      final source = baseEntry.$1;
      final span = 1 << baseEntry.$2;
      final unit = 1.0 / span;
      base = _FallbackDraw(
        source,
        Rect.fromLTWH(
            (cell.x % span) * unit, (cell.y % span) * unit, unit, unit),
        const Rect.fromLTWH(0, 0, 1, 1),
      );
      sourceKeys.add(source.key);
    }

    // Refinement: available descendants overlay the base quadrant by
    // quadrant, recursively filling gaps with deeper descendants. The
    // draw budget covers base plus refinements together.
    final refinements = <_FallbackDraw>[];
    final budget = maxDrawsPerRegion - (base == null ? 0 : 1);
    _refineWithChildren(manager, z, cell.x, cell.y,
        const Rect.fromLTWH(0, 0, 1, 1), 0, refinements, sourceKeys, budget);
    _refineWithCarriedDescendants(z, cell, refinements, sourceKeys, budget);

    if (base == null && refinements.isEmpty) return null;
    return _FallbackRegion(cellKey, base, refinements, sourceKeys,
        manager.pinRenderedImages(sourceKeys));
  }

  static int _wrappedX(int z, int x) {
    final n = 1 << z;
    return ((x % n) + n) % n;
  }

  /// Looks up a retained source for `(z, x, y)`: the grid's raw key, then
  /// the wrapped-X canonical key, then an exact coordinate match in the
  /// cross-step carry. The returned source always uses canonical X so its
  /// explicit coordinates remain usable by later geographic carry passes.
  _FallbackSource? _imageFor(TileManager manager, int z, int x, int y) {
    final direct = _rawImageFor(manager, z, x, y);
    if (direct != null) return direct;
    if (z > 30 || z < 0) return null;
    final wrappedX = _wrappedX(z, x);
    for (final source in _carrySources?.values ?? const <_FallbackSource>[]) {
      if (source.z == z && source.x == wrappedX && source.y == y) {
        return source;
      }
    }
    return null;
  }

  /// Raw cache-only lookup (no carry). Namespaces remain part of the opaque
  /// cache key; the source coordinate is carried alongside it explicitly.
  _FallbackSource? _rawImageFor(TileManager manager, int z, int x, int y) {
    if (z > 30 || z < 0) return null;
    final wrappedX = _wrappedX(z, x);
    final rawKey = manager.renderTileKey(z, x, y);
    final raw = manager.retainedImage(rawKey);
    if (raw != null) return _FallbackSource(rawKey, raw, z, wrappedX, y);
    if (wrappedX == x) return null;
    final wrappedKey = manager.renderTileKey(z, wrappedX, y);
    final wrapped = manager.retainedImage(wrappedKey);
    if (wrapped != null) {
      return _FallbackSource(wrappedKey, wrapped, z, wrappedX, y);
    }
    return null;
  }

  /// Nearest retained ancestor of `(z, x, y)`: first the fixed shallow
  /// window ([maxAncestorLevels]), then the deepest carried source whose
  /// footprint contains the cell, however many levels down it sits.
  (_FallbackSource, int)? _nearestAncestor(
      TileManager manager, int z, _TileCoord cell) {
    for (var level = 1; level <= maxAncestorLevels; level++) {
      final ancestorZoom = z - level;
      if (ancestorZoom < 0) break;
      final x = cell.x >> level;
      final y = cell.y >> level;
      final entry = _rawImageFor(manager, ancestorZoom, x, y);
      if (entry != null) return (entry, level);
    }
    final carry = _carrySources;
    if (carry == null || carry.isEmpty || z > 30) return null;
    final cellX = _wrappedX(z, cell.x);
    (_FallbackSource, int)? best;
    for (final source in carry.values) {
      if (source.z >= z || source.z < 0) continue;
      final level = z - source.z;
      if ((cellX >> level) != source.x || (cell.y >> level) != source.y) {
        continue;
      }
      if (best == null || level < best.$2) best = (source, level);
    }
    return best;
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
          refinements.add(
              _FallbackDraw(entry, const Rect.fromLTWH(0, 0, 1, 1), quadrant));
          sourceKeys.add(entry.key);
        } else {
          _refineWithChildren(manager, z + 1, cx, cy, quadrant, depth + 1,
              refinements, sourceKeys, budget);
        }
      }
    }
  }

  /// Crops every carried descendant footprint into the missing cell. Unlike
  /// the shallow recursive walk, this has no depth cutoff: a z12 source can
  /// refine a z9 cell directly. Both rectangles are clamped to their actual
  /// intersection, so a partially overlapping source never stretches into
  /// geography it does not depict.
  void _refineWithCarriedDescendants(int z, _TileCoord cell,
      List<_FallbackDraw> refinements, Set<String> sourceKeys, int budget) {
    final carry = _carrySources;
    if (carry == null || carry.isEmpty || z > 30) return;
    final candidates = carry.values
        .where((source) =>
            source.z > z && source.z <= 30 && !sourceKeys.contains(source.key))
        .toList()
      // Coarser imagery first; sharper descendants overlay it. Key order
      // makes the bounded draw selection deterministic.
      ..sort((a, b) {
        final byZoom = a.z.compareTo(b.z);
        return byZoom != 0 ? byZoom : a.key.compareTo(b.key);
      });
    final cellX = _wrappedX(z, cell.x);
    const cellUnit = Rect.fromLTWH(0, 0, 1, 1);
    for (final source in candidates) {
      if (refinements.length >= budget) return;
      final span = 1 << (source.z - z);
      final unit = 1.0 / span;
      final sourceUnit = Rect.fromLTWH((source.x - cellX * span) * unit,
          (source.y - cell.y * span) * unit, unit, unit);
      final dstUnit = sourceUnit.intersect(cellUnit);
      if (dstUnit.isEmpty) continue;
      final srcUnit = Rect.fromLTRB(
        (dstUnit.left - sourceUnit.left) / unit,
        (dstUnit.top - sourceUnit.top) / unit,
        (dstUnit.right - sourceUnit.left) / unit,
        (dstUnit.bottom - sourceUnit.top) / unit,
      );
      refinements.add(_FallbackDraw(source, srcUnit, dstUnit));
      sourceKeys.add(source.key);
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
    _transitionSources = null;
    final z = manager.zoom;
    final loaded = manager.renderTiles
        .where((tile) => tile.sourceTile != null)
        .toList(growable: false);
    _transitionSources = [
      for (final tile in loaded)
        _FallbackSource(tile.index, tile.sourceTile!, z,
            _wrappedX(z, tile.lngIndex), tile.latIndex),
    ];
    _transitionRelease =
        manager.pinRenderedImages(loaded.map((tile) => tile.index));
  }

  /// Releases every region. Used by camera commands and teardown paths
  /// that invalidate the fallback outright (and by memory-pressure
  /// eviction, via the view): later reconciles rebuild regions for
  /// still-missing cells from whatever imagery is still retained.
  void clear() {
    _transitionRelease?.call();
    _transitionRelease = null;
    _transitionSources = null;
    _carrySources = null;
    // The next reconcile must re-evaluate even at the same grid/content
    // revision: clearing is an explicit invalidation, not a paint-time
    // identity change.
    _lastReconciledRevision = 0;
    if (_regions.isEmpty) return;
    final regions = List<_FallbackRegion>.of(_regions.values);
    _regions.clear();
    for (final region in regions) {
      region.release();
    }
    _version++;
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
/// A full-viewport opaque base is painted first, unblurred: loaded replacement
/// tiles draw above this layer in the widget stack, and transparent ones
/// must blend against the same background the plain grid paints — never
/// against stale old-zoom imagery. Every imagery draw then composites through
/// its own bounded layer ([Canvas.saveLayer]) carrying the zoom snapshot's
/// gaussian sigma, with an explicit [Canvas.clipRect] around the layer at the
/// draw's geographic footprint. The softened look survives the handoff without
/// tinting neighboring ready tiles, uncovered cells, or uncovered descendant
/// quadrants (plan 09 review round 3).
///
/// While this painter is present the grid painter skips its background
/// and placeholder passes, so the two never double-paint.
class ZoomFallbackPainter extends CustomPainter {
  /// The zoom snapshot's gaussian sigma — the softened appearance that
  /// persists over the handoff (plan 09). Zero per-engine/gesture gates;
  /// sub-0.1 is treated as off. The view passes 0 for vector payloads:
  /// plan 13's product direction keeps vector transitions unblurred and
  /// reserves this blur for raster.
  final double blurSigma;

  ZoomFallbackPainter({
    required this.coverage,
    required this.manager,
    this.blurSigma = 0.0,
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

  /// Layer paint for one paint() pass; content rasterizes crisply inside
  /// each draw's layer and blurs only while compositing inside its explicit
  /// output clip.
  Paint _layerPaint() {
    final paint = Paint();
    if (blurSigma > 0.1) {
      paint.imageFilter =
          ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);
    }
    return paint;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Phase-12 attribution: duration span per repaint, tagged by whether
    // this pass pays for per-region blur layers (spans arm only).
    final spanStart = VectorSpanLog.enabled ? VectorSpanLog.nowUs() : 0;
    // Opaque base under everything (background parity + alpha guard),
    // unblurred: ready tiles and uncovered cells keep the plain
    // background beneath them.
    canvas.drawRect(Offset.zero & size, _basePaint);

    final pad = manager.tilePadding;
    final paddedV = manager.verticalTileCount;
    final tileW = manager.renderedTileWidth;
    final tileH = manager.renderedTileHeight;
    final originX = manager.leftColumnTilesCanvasX;
    final originY = manager.topRowTilesCanvasY;
    final tiles = manager.renderTiles;
    final layerPaint = _layerPaint();

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
          _drawFallbackImage(
              canvas, base, cellX, cellY, tileW, tileH, layerPaint, false);
        }
        for (final draw in region.refinements) {
          // Isolation is unconditional: a refinement may overlap not only
          // a base but also earlier carried refinements (coarser sources
          // are emitted first). Its transparent pixels must reveal the
          // plain background, never any older imagery underneath.
          _drawFallbackImage(
              canvas, draw, cellX, cellY, tileW, tileH, layerPaint, true);
        }
      }
    }
    if (VectorSpanLog.enabled) {
      VectorSpanLog.record('paint.fallback', null, spanStart,
          VectorSpanLog.nowUs() - spanStart,
          source: blurSigma > 0.1 ? 'blur' : 'plain');
    }
  }

  /// Draws one unit-rect imagery draw into the cell at `(cellX, cellY)`.
  ///
  /// The destination footprint is both the `saveLayer` bounds and an
  /// explicit output clip around that layer. A saveLayer's bounds alone do
  /// not constrain the compositor's blur output; the enclosing clip does.
  /// Each descendant gets its own layer, so its blur cannot enter an
  /// uncovered quadrant elsewhere in the cell. With no blur, the same clip
  /// still enforces the geographic footprint without paying for a layer.
  ///
  /// When [isolateEarlierDraws] is set, the opaque plain background is
  /// painted *outside* the filtered layer, before it starts: a blurred
  /// layer edge cannot make that isolation fill translucent, and the
  /// filtered image above it can therefore never reveal older imagery
  /// beneath the footprint.
  void _drawFallbackImage(
      Canvas canvas,
      _FallbackDraw draw,
      double cellX,
      double cellY,
      double tileW,
      double tileH,
      Paint layerPaint,
      bool isolateEarlierDraws) {
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

    final blurred = blurSigma > 0.1;
    canvas.save();
    canvas.clipRect(dst);
    if (isolateEarlierDraws) {
      // Alpha isolation outside the filtered layer: transparent descendant
      // pixels blend against this opaque fill, never older imagery, and the
      // fill's edge cannot become translucent through its own blur.
      canvas.drawRect(dst, _basePaint);
    }
    if (blurred) canvas.saveLayer(dst, layerPaint);
    canvas.drawImageRect(image, src, dst, _imagePaint);
    if (blurred) canvas.restore(); // filtered layer, inside the output clip
    canvas.restore(); // explicit destination-footprint clip
  }

  @override
  bool shouldRepaint(ZoomFallbackPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.version != version ||
      oldDelegate.canvasX != canvasX ||
      oldDelegate.canvasY != canvasY ||
      oldDelegate.tileScale != tileScale ||
      oldDelegate.blurSigma != blurSigma;
}
