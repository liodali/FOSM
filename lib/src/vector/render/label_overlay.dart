import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle;

import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_source.dart' show TileDecodeAborted;
import 'package:fosm/src/vector/mvt/vector_tile.dart';
import 'package:fosm/src/vector/style/expression.dart';
import 'package:fosm/src/vector/style/map_style.dart';
import 'package:fosm/src/vector/render/vector_tile_renderer.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/render/vector_trace.dart';

/// Paints symbol layers (place labels, POI icons, …) on top of the tile
/// grid for the whole viewport.
///
/// Labels cannot be baked into tile images: text would be clipped at tile
/// borders and duplicated by the MVT buffer overlap. Instead this overlay
/// lays out labels once per tile+zoom (cached), then applies viewport
/// collision each frame — first-come-first-served in style layer order,
/// matching MapLibre's priority semantics.
///
/// Point labels are placed at the feature's anchor position.
/// Line labels are sampled along geometry at regular intervals and
/// rotated to follow the path direction.
class LabelOverlay {
  final VectorTileRuntime runtime;

  LabelOverlay(this.runtime);

  static const int maxLabelsPerFrame = 500;
  static const int _maxPreparedTiles = 64;

  /// Upper bound for cached per-zoom layer styles. One entry per zoom in
  /// use; the bound only guards against unbounded zoom keys.
  static const int _maxCachedLayerStyles = 32;

  /// Pixel distance between sampled line label placements.
  /// Roads typically need ~200-300px gaps to avoid clutter.
  static const double _lineLabelSpacing = 250.0;

  /// Prepared labels keyed by `zoom/x/y` (stable across pans).
  /// Preserved across tile-arrival rebuilds because the overlay is owned
  /// for the lifetime of the runtime — see [VectorTileRuntime.labelOverlay].
  final LinkedHashMap<String, List<_PreparedLabel>> _prepared = LinkedHashMap();

  /// Symbol-layer style facts keyed by zoom, shared by every tile prepared
  /// at that zoom: compiled filters, precomputed property-dependency
  /// analysis and memoised zoom-only expression results (text-size steps,
  /// static colors, …). Invalidation is ownership-based — the overlay is
  /// created by, and disposed with, one [VectorTileRuntime] and therefore
  /// one loaded style, so a style change implies a fresh overlay and cache.
  final LinkedHashMap<int, List<_SymbolLayerStyle>> _layerStylesByZoom =
      LinkedHashMap();

  bool _disposed = false;

  /// Number of tiles with cached prepared labels (test hook).
  @visibleForTesting
  int get preparedTileCount => _prepared.length;

  /// Tiles with cached prepared labels (public attribution surface).
  int get preparedTiles => _prepared.length;

  /// Identities (`z/x/y`) of tiles whose label preparation completed —
  /// including tiles that prepared successfully with *zero* labels, so a
  /// completed no-label tile is distinct from one that was never
  /// prepared. Harnesses use this to prove label readiness for a
  /// viewport instead of relying on stable prepared counts.
  Set<String> get preparedTileKeys => _prepared.keys.toSet();

  /// Prepared labels (text/halo painter pairs) across all cached tiles.
  int get preparedLabels {
    var total = 0;
    for (final labels in _prepared.values) {
      total += labels.length;
    }
    return total;
  }

  /// Disposes every cached label painter and clears the prepared-tile
  /// cache — the deliberate response to system memory pressure.
  ///
  /// Layer styles stay cached (small, shared per zoom). The overlay keeps
  /// working: [prepare] re-populates entries, tiles without prepared
  /// labels simply paint none until they prepare again.
  void releasePrepared() {
    if (_disposed) return;
    for (final labels in _prepared.values) {
      for (final label in labels) {
        _disposeLabel(label);
      }
    }
    _prepared.clear();
  }

  /// The prepared-tile cache bound (test hook).
  @visibleForTesting
  static int get maxPreparedTilesLimit => _maxPreparedTiles;

  /// Number of zoom levels with cached layer styles (test hook).
  @visibleForTesting
  int get cachedLayerStyleZooms => _layerStylesByZoom.length;

  /// Text/halo layouts triggered from [paint] (test hook). Labels are
  /// laid out during [prepare]; paint must keep this at zero for prepared
  /// tiles.
  @visibleForTesting
  int debugPaintTimeLayouts = 0;

  /// Labels whose painters this overlay released — aborted batches, LRU
  /// evictions and overlay disposal (test hook).
  @visibleForTesting
  int debugDisposedLabels = 0;

  /// Releases [label]'s painters, routing every overlay-side disposal
  /// through one place so cleanup is observable in tests.
  void _disposeLabel(_PreparedLabel label) {
    label.dispose();
    debugDisposedLabels++;
  }

  /// Memoised font sizes of one tile's prepared labels (test hook).
  @visibleForTesting
  List<double> debugPreparedFontSizes(int zoom, int x, int y) => [
        for (final label in _prepared['$zoom/$x/$y'] ?? const [])
          label.fontSize,
      ];

  /// Forces the next [prepare] call to throw, to test lifecycle cleanup.
  @visibleForTesting
  bool debugFailNextPrepare = false;

  /// Releases all cached text/halo painters and clears prepared labels.
  /// Called once from [VectorTileRuntime.dispose]; the overlay must not
  /// be painted after disposal.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final labels in _prepared.values) {
      for (final label in labels) {
        _disposeLabel(label);
      }
    }
    _prepared.clear();
    _layerStylesByZoom.clear();
  }

  void paint(
    ui.Canvas canvas,
    ui.Size size, {
    required int zoom,
    double tileScale = 1,
    required double leftColumnTilesCanvasX,
    required double topRowTilesCanvasY,
    required int leftColumnTilesLngIndex,
    required int topRowTilesLatIndex,
    required List<Tile> tiles,
  }) {
    if (_disposed) return;
    // Traced separately from `labels.build`/`labels.layout` so timeline
    // captures show collision placement during motion on its own.
    VectorTrace.sync('labels.paint', () {
      _paintTiles(
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
    });
  }

  void _paintTiles(
    ui.Canvas canvas,
    ui.Size size, {
    required int zoom,
    double tileScale = 1,
    required double leftColumnTilesCanvasX,
    required double topRowTilesCanvasY,
    required int leftColumnTilesLngIndex,
    required int topRowTilesLatIndex,
    required List<Tile> tiles,
  }) {
    final sprite = runtime.sprite;
    final collision = _CollisionGrid(cellSize: 72);
    final seenSymbols = <String>{};
    var drawn = 0;

    for (final tile in tiles) {
      if (drawn >= maxLabelsPerFrame) break;
      final coords = _parseTileIndex(tile.index);
      if (coords == null) continue;
      final (z, x, y) = coords;
      if (z != zoom) continue;

      final parsed = runtime.parsedTileFor(z, x, y);
      if (parsed == null) continue;

      final originX = leftColumnTilesCanvasX +
          (tile.lngIndex - leftColumnTilesLngIndex) * 256.0 * tileScale;
      final originY = topRowTilesCanvasY +
          (tile.latIndex - topRowTilesLatIndex) * 256.0 * tileScale;
      // Skip tiles fully off-canvas (padding ring included).
      if (originX <= -256 * tileScale ||
          originY <= -256 * tileScale ||
          originX >= size.width + 256 * tileScale ||
          originY >= size.height + 256 * tileScale) {
        continue;
      }

      final labels = _labelsFor(zoom, x, y);
      for (final label in labels) {
        if (drawn >= maxLabelsPerFrame) break;
        if (!seenSymbols.add(label.dedupeKey)) continue;

        final anchor = ui.Offset(
          originX + label.localX * tileScale,
          originY + label.localY * tileScale,
        );
        // Cull before paying for text layout.
        if (anchor.dx < -80 ||
            anchor.dy < -60 ||
            anchor.dx > size.width + 80 ||
            anchor.dy > size.height + 60) {
          continue;
        }

        // Preparation should have laid these out already; count (in tests)
        // any paint that still has to build painters synchronously.
        if (label.text != null && !label.isTextLaidOut) {
          debugPaintTimeLayouts++;
        } else if (label.haloWidth > 0 && !label.isHaloLaidOut) {
          debugPaintTimeLayouts++;
        }
        final textPainter = label.text == null ? null : label.painter();
        final haloPainter = label.text == null || label.haloWidth <= 0
            ? null
            : label.haloPainter();

        // One collision box for icon + text together (MapLibre treats a
        // symbol's parts as a unit).
        var rect = ui.Rect.fromCircle(
          center: anchor,
          radius: 8,
        );
        if (label.icon != null && sprite != null) {
          final iconRect = sprite.rectFor(label.icon!);
          if (iconRect != null) {
            rect = rect.expandToInclude(ui.Rect.fromCenter(
              center: anchor,
              width: iconRect.width * label.iconSize + 4,
              height: iconRect.height * label.iconSize + 4,
            ));
          }
        }
        if (textPainter != null) {
          final textOffset = _textOffsetFor(label, textPainter);
          rect = rect.expandToInclude(
            ui.Rect.fromLTWH(
              anchor.dx + textOffset.dx,
              anchor.dy + textOffset.dy,
              textPainter.width + 4,
              textPainter.height + 4,
            ),
          );
        }
        if (!collision.tryPlace(rect)) continue;

        // Apply rotation for line labels.
        if (label.angle != 0) {
          canvas.save();
          canvas.translate(anchor.dx, anchor.dy);
          canvas.rotate(label.angle);
          final origin = ui.Offset.zero;
          if (label.icon != null && sprite != null) {
            sprite.draw(canvas, label.icon!, origin, label.iconSize);
          }
          if (haloPainter != null) {
            haloPainter.paint(
                canvas, origin + _textOffsetFor(label, haloPainter));
          }
          if (textPainter != null) {
            textPainter.paint(
                canvas, origin + _textOffsetFor(label, textPainter));
          }
          canvas.restore();
        } else {
          if (label.icon != null && sprite != null) {
            sprite.draw(canvas, label.icon!, anchor, label.iconSize);
          }
          if (haloPainter != null) {
            haloPainter.paint(
                canvas, anchor + _textOffsetFor(label, haloPainter));
          }
          if (textPainter != null) {
            textPainter.paint(
                canvas, anchor + _textOffsetFor(label, textPainter));
          }
        }
        drawn++;
      }
    }
  }

  /// Where to draw the text box relative to the anchor point, combining
  /// `text-anchor` (which side of the text touches the point) and
  /// `text-offset` (in ems).
  ui.Offset _textOffsetFor(_PreparedLabel label, TextPainter painter) {
    final (dx, dy) = switch (label.anchor) {
      'left' => (0.0, -painter.height / 2),
      'right' => (-painter.width, -painter.height / 2),
      'top' => (-painter.width / 2, -painter.height),
      'bottom' => (-painter.width / 2, 0.0),
      'top-left' => (0.0, -painter.height),
      'top-right' => (-painter.width, -painter.height),
      'bottom-left' => (0.0, 0.0),
      'bottom-right' => (-painter.width, 0.0),
      _ => (-painter.width / 2, -painter.height / 2), // center
    };
    return ui.Offset(
      dx + label.offsetDx * label.fontSize,
      dy + label.offsetDy * label.fontSize,
    );
  }

  /// Scans a display-eligible parsed tile's symbol features and lays out its
  /// text/halo painters ahead of the next paint.
  ///
  /// Feature scanning, style expression evaluation, line sampling and
  /// `TextPainter.layout()` all run here, cooperatively yielding every
  /// [yieldBudget] so a dense symbol tile never blocks a frame. [paint] then
  /// only runs viewport collision and drawing for cached tiles.
  ///
  /// [isRelevant] is checked between batches; when it returns false (or the
  /// overlay has been disposed) preparation aborts with [TileDecodeAborted]
  /// so the caller can discard a now-stale tile.
  ///
  /// Idempotent: a second call for the same tile is a cache hit.
  Future<void> prepare(
    int zoom,
    int x,
    int y, {
    bool Function()? isRelevant,
    String? traceAttempt,
    Duration yieldBudget = const Duration(milliseconds: 4),
    Future<void> Function()? yieldControl,
  }) async {
    if (_disposed) return;
    if (debugFailNextPrepare) {
      debugFailNextPrepare = false;
      throw StateError('debug: label preparation failure');
    }
    final parsed = runtime.parsedTileFor(zoom, x, y);
    if (parsed == null) return;

    final key = '$zoom/$x/$y';
    final cached = _prepared.remove(key);
    if (cached != null) {
      _prepared[key] = cached; // refresh LRU
      await VectorTrace.async(
        'labels.layout',
        () => _layOutLabels(
          cached,
          isRelevant: isRelevant,
          yieldBudget: yieldBudget,
          yieldControl: yieldControl,
        ),
        tile: key,
        attempt: traceAttempt,
      );
      if (_stale(isRelevant)) throw const TileDecodeAborted();
      return;
    }

    final labels = <_PreparedLabel>[];
    // Build and layout share one cleanup guard: until the batch is stored
    // it is cache-invisible, so *any* exit besides success — a stale
    // check, a cancellation or a layout failure — must dispose every
    // label, including painters already laid out before the abort.
    try {
      await VectorTrace.async(
        'labels.build',
        () => _buildLabels(
          labels,
          zoom,
          x,
          y,
          parsed,
          isRelevant: isRelevant,
          yieldBudget: yieldBudget,
          yieldControl: yieldControl,
        ),
        tile: key,
        attempt: traceAttempt,
      );
      if (_stale(isRelevant)) throw const TileDecodeAborted();
      // Lay out text/halo painters *before* the batch becomes
      // cache-visible, so a paint that races preparation can never trigger
      // text layout.
      await VectorTrace.async(
        'labels.layout',
        () => _layOutLabels(
          labels,
          isRelevant: isRelevant,
          yieldBudget: yieldBudget,
          yieldControl: yieldControl,
        ),
        tile: key,
        attempt: traceAttempt,
      );
      if (_stale(isRelevant)) throw const TileDecodeAborted();
    } catch (_) {
      for (final label in labels) {
        _disposeLabel(label);
      }
      rethrow;
    }
    // Cache insertion is the last step of a successful prepare.
    _storePrepared(key, labels);
  }

  /// Builds [labels] for one tile, yielding every [yieldBudget].
  Future<void> _buildLabels(
    List<_PreparedLabel> labels,
    int zoom,
    int tileX,
    int tileY,
    ParsedVectorTile parsed, {
    bool Function()? isRelevant,
    required Duration yieldBudget,
    Future<void> Function()? yieldControl,
  }) async {
    final stopwatch = Stopwatch()..start();

    for (final style in _layerStylesFor(zoom)) {
      if (_stale(isRelevant)) throw const TileDecodeAborted();
      if (!style.visible) continue;
      final sourceLayer = style.layer.sourceLayer;
      if (sourceLayer == null) continue;
      final data = parsed.decoded.layerByName(sourceLayer);
      if (data == null) continue;

      final transform = TileTransform.forLayer(
        z: zoom,
        x: tileX,
        y: tileY,
        srcZ: parsed.srcZ,
        extent: data.extent,
      );

      for (final feature in data.features) {
        if (_stale(isRelevant)) throw const TileDecodeAborted();
        _appendFeatureLabels(labels, style, feature, transform);
        await _maybeYield(stopwatch, yieldBudget, yieldControl);
      }
    }
  }

  /// Symbol-layer style facts for [zoom], shared by every tile prepared at
  /// that zoom: the layer list is scanned and each expression's dependency
  /// analysis + zoom-only values are computed once, then memoised across
  /// tiles (see [_SymbolLayerStyle]).
  List<_SymbolLayerStyle> _layerStylesFor(int zoom) {
    final hit = _layerStylesByZoom.remove(zoom);
    if (hit != null) {
      _layerStylesByZoom[zoom] = hit; // refresh LRU
      return hit;
    }
    final built = [
      for (final layer in runtime.loaded.style.layers)
        if (layer.type == StyleLayerType.symbol) _SymbolLayerStyle(layer, zoom),
    ];
    _layerStylesByZoom[zoom] = built;
    while (_layerStylesByZoom.length > _maxCachedLayerStyles) {
      _layerStylesByZoom.remove(_layerStylesByZoom.keys.first);
    }
    return built;
  }

  /// Lays out text/halo painters, yielding every [yieldBudget].
  Future<void> _layOutLabels(
    List<_PreparedLabel> labels, {
    bool Function()? isRelevant,
    required Duration yieldBudget,
    Future<void> Function()? yieldControl,
  }) async {
    final stopwatch = Stopwatch()..start();
    for (final label in labels) {
      if (_stale(isRelevant)) throw const TileDecodeAborted();
      if (label.text != null) {
        label.painter();
        if (label.haloWidth > 0) label.haloPainter();
      }
      await _maybeYield(stopwatch, yieldBudget, yieldControl);
    }
  }

  bool _stale(bool Function()? isRelevant) {
    if (_disposed) return true;
    final check = isRelevant;
    return check != null && !check();
  }

  Future<void> _maybeYield(
    Stopwatch stopwatch,
    Duration budget,
    Future<void> Function()? yieldControl,
  ) async {
    if (stopwatch.elapsed < budget) return;
    stopwatch.reset();
    if (yieldControl != null) {
      await yieldControl();
    } else {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Returns only labels prepared by the lower-priority runtime queue.
  /// Paint must never synchronously scan/style a dense tile as a fallback.
  List<_PreparedLabel> _labelsFor(int zoom, int tileX, int tileY) {
    final key = '$zoom/$tileX/$tileY';
    final hit = _prepared.remove(key);
    if (hit == null) return const [];
    _prepared[key] = hit;
    return hit;
  }

  void _appendFeatureLabels(
    List<_PreparedLabel> labels,
    _SymbolLayerStyle style,
    DecodedFeature feature,
    TileTransform transform,
  ) {
    if (feature.geometry.isEmpty || feature.geometry.first.length < 2) {
      return;
    }
    final ctx = EvaluationContext(
      zoom: style.zoom.toDouble(),
      properties: feature.properties,
    );
    if (!style.filter(ctx)) return;

    final text = style.resolveText(ctx);
    final icon = style.resolveIcon(ctx);
    if (text == null && icon == null) return;

    final fontSize = style.fontSize.number(ctx, fallback: 16, min: 6, max: 64);
    final color = style.textColor.color(ctx) ?? const ui.Color(0xFF000000);
    final haloColor = style.haloColor.color(ctx);
    final haloWidth = style.haloWidth.number(ctx, fallback: 0, min: 0, max: 8);
    final letterSpacing = style.letterSpacing.number(ctx, fallback: 0);
    final anchor = style.textAnchor.string(ctx) ?? 'center';
    final offsetDx = style.offsetEms(ctx, 0);
    final offsetDy = style.offsetEms(ctx, 1);
    final iconSize = style.iconSize.number(ctx, fallback: 1, min: 0.5, max: 4);

    if (style.isLine && feature.geomType == MvtGeomType.lineString) {
      // Line label: sample placements along the geometry.
      _addLineLabels(
        labels,
        style.layer.id,
        feature,
        transform,
        text: text,
        icon: icon,
        fontSize: fontSize,
        color: color,
        haloColor: haloColor,
        haloWidth: haloWidth,
        letterSpacing: letterSpacing,
        iconSize: iconSize,
      );
    } else {
      // Point label: place at the first coordinate.
      final first = feature.geometry.first;
      labels.add(_PreparedLabel(
        text: text,
        icon: icon,
        dedupeKey:
            '${style.layer.id}:${feature.id > 0 ? feature.id : text ?? icon}',
        localX: transform.x(first[0]),
        localY: transform.y(first[1]),
        fontSize: fontSize,
        color: color,
        haloColor: haloColor,
        haloWidth: haloWidth,
        letterSpacing: letterSpacing,
        anchor: anchor,
        offsetDx: offsetDx,
        offsetDy: offsetDy,
        iconSize: iconSize,
      ));
    }
  }

  void _storePrepared(String key, List<_PreparedLabel> labels) {
    _prepared[key] = labels;
    while (_prepared.length > _maxPreparedTiles) {
      final evicted = _prepared.remove(_prepared.keys.first);
      for (final label in evicted ?? const <_PreparedLabel>[]) {
        _disposeLabel(label);
      }
    }
  }

  /// Replaces `{property}` tokens in a template string with feature values.
  /// e.g. `"{maki}-11"` with `maki: "park"` → `"park-11"`.
  static String? _interpolateTemplate(
      String template, Map<String, dynamic>? props) {
    if (props == null) return null;
    final result = template.replaceAllMapped(
      RegExp(r'\{([^}]+)\}'),
      (m) => stringifyStyleValue(props[m.group(1)]),
    );
    return result.isEmpty ? null : result;
  }

  /// Samples line label placements along a line feature's geometry at
  /// regular intervals. Each placement captures the local direction so
  /// the label can be rotated to follow the road/waterway.
  void _addLineLabels(
    List<_PreparedLabel> labels,
    String layerId,
    DecodedFeature feature,
    TileTransform transform, {
    required String? text,
    required String? icon,
    required double fontSize,
    required ui.Color color,
    required ui.Color? haloColor,
    required double haloWidth,
    required double letterSpacing,
    required double iconSize,
  }) {
    for (var partIdx = 0; partIdx < feature.geometry.length; partIdx++) {
      final part = feature.geometry[partIdx];
      if (part.length < 4) continue; // Need at least 2 points

      // Compute total path length and cumulative distances.
      final dists = <double>[0.0];
      for (var i = 2; i + 1 < part.length; i += 2) {
        final dx = transform.x(part[i]) - transform.x(part[i - 2]);
        final dy = transform.y(part[i + 1]) - transform.y(part[i - 1]);
        dists.add(dists.last + math.sqrt(dx * dx + dy * dy));
      }
      final totalLen = dists.last;
      if (totalLen < 30) continue; // Too short to label

      // Sample placements along the path.
      var nextDist = _lineLabelSpacing / 2;
      while (nextDist < totalLen) {
        // Binary search for the segment containing nextDist.
        var lo = 0, hi = dists.length - 1;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (dists[mid] < nextDist) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        final segIdx = (lo - 1).clamp(0, dists.length - 2);
        final segStart = dists[segIdx];
        final segEnd = dists[segIdx + 1];
        final segLen = segEnd - segStart;
        if (segLen < 0.01) {
          nextDist += _lineLabelSpacing;
          continue;
        }

        final t = ((nextDist - segStart) / segLen).clamp(0.0, 1.0);
        final pi = segIdx * 2;
        final px = transform.x(part[pi]) +
            t * (transform.x(part[pi + 2]) - transform.x(part[pi]));
        final py = transform.y(part[pi + 1]) +
            t * (transform.y(part[pi + 3]) - transform.y(part[pi + 1]));

        // Direction angle from the segment.
        final dx = transform.x(part[pi + 2]) - transform.x(part[pi]);
        final dy = transform.y(part[pi + 3]) - transform.y(part[pi + 1]);
        var angle = math.atan2(dy, dx);
        // Keep text readable: flip if upside down.
        if (angle > math.pi / 2) angle -= math.pi;
        if (angle < -math.pi / 2) angle += math.pi;

        labels.add(_PreparedLabel(
          text: text,
          icon: icon,
          dedupeKey:
              '$layerId:${feature.id > 0 ? feature.id : text ?? icon}:$partIdx:$nextDist',
          localX: px,
          localY: py,
          fontSize: fontSize,
          color: color,
          haloColor: haloColor,
          haloWidth: haloWidth,
          letterSpacing: letterSpacing,
          anchor: 'center',
          offsetDx: 0,
          offsetDy: 0,
          iconSize: iconSize,
          angle: angle,
        ));

        nextDist += _lineLabelSpacing;
      }
    }
  }

  /// Parses `…/z/x/y` tile keys (with or without a style namespace).
  (int, int, int)? _parseTileIndex(String index) {
    final parts = index.split('/');
    if (parts.length < 3) return null;
    final z = int.tryParse(parts[parts.length - 3]);
    final x = int.tryParse(parts[parts.length - 2]);
    final y = int.tryParse(parts[parts.length - 1]);
    if (z == null || x == null || y == null) return null;
    return (z, x, y);
  }
}

/// Per-(layer, zoom) symbol-layer style facts, shared by every tile
/// prepared at that zoom.
///
/// Each layout/paint expression is wrapped in a [CachedExpression], so
/// property-dependency analysis runs once per layer/zoom and zoom-only
/// values (text-size zoom steps, static colors, …) are evaluated once and
/// memoised across every tile and feature at that zoom. Property-driven
/// values still evaluate per feature. The layer filter is compiled once
/// into closures (see [compileFilter]) instead of being re-walked per
/// feature, and `symbol-placement` is resolved once per zoom.
class _SymbolLayerStyle {
  final StyleLayer layer;
  final int zoom;

  /// `visibility` is not `none` and [zoom] is within the layer's range.
  final bool visible;

  /// Whether the layer places symbols along line geometry at [zoom].
  final bool isLine;

  /// The layer filter, compiled once and evaluated per feature.
  final CompiledFilter filter;

  late final CachedExpression _textField;
  late final CachedExpression _textTransform;
  late final CachedExpression _icon;
  late final CachedExpression fontSize;
  late final CachedExpression textColor;
  late final CachedExpression haloColor;
  late final CachedExpression haloWidth;
  late final CachedExpression letterSpacing;
  late final CachedExpression textAnchor;
  late final CachedExpression iconSize;
  late final List<CachedExpression> _offsets;

  _SymbolLayerStyle(this.layer, this.zoom)
      : visible =
            layer.isVisible && zoom >= layer.minZoom && zoom <= layer.maxZoom,
        isLine = _evaluateIsLine(layer.layout['symbol-placement'], zoom),
        filter = compileFilter(layer.filter) {
    _textField = CachedExpression(layer.layout['text-field']);
    _textTransform = CachedExpression(layer.layout['text-transform']);
    _icon = CachedExpression(layer.layout['icon-image']);
    fontSize = CachedExpression(layer.layout['text-size']);
    textColor = CachedExpression(layer.paint['text-color']);
    haloColor = CachedExpression(layer.paint['text-halo-color']);
    haloWidth = CachedExpression(layer.paint['text-halo-width']);
    letterSpacing = CachedExpression(layer.layout['text-letter-spacing']);
    textAnchor = CachedExpression(layer.layout['text-anchor']);
    iconSize = CachedExpression(layer.layout['icon-size']);
    final rawOffsets = layer.layout['text-offset'];
    _offsets = rawOffsets is List
        ? [for (final element in rawOffsets) CachedExpression(element)]
        : const [];
  }

  /// Whether [placementExpr] resolves to `"line"` at [zoom]. Liberty uses
  /// `["step", ["zoom"], "point", N, "line"]` for shields, plus plain
  /// `"line"` for road/water names.
  static bool _evaluateIsLine(dynamic placementExpr, int zoom) {
    return placementExpr == 'line' ||
        (placementExpr is List &&
            evaluateStringExpr(
                  placementExpr,
                  EvaluationContext(
                    zoom: zoom.toDouble(),
                    properties: null,
                  ),
                ) ==
                'line');
  }

  String? resolveText(EvaluationContext ctx) {
    final raw = layer.layout['text-field'];
    if (raw == null) return null;
    // Legacy shorthand: a bare string names a property.
    final value =
        raw is String ? (ctx.properties?[raw]) : _textField.evaluate(ctx);
    if (value == null) return null;
    var text = stringifyStyleValue(value);
    switch (_textTransform.string(ctx)) {
      case 'uppercase':
        text = text.toUpperCase();
      case 'lowercase':
        text = text.toLowerCase();
    }
    return text.isEmpty ? null : text;
  }

  String? resolveIcon(EvaluationContext ctx) {
    final raw = layer.layout['icon-image'];
    if (raw == null) return null;
    // Template strings like "{maki}-11" need interpolation. We handle
    // the common "{property}" pattern.
    if (raw is String) {
      if (raw.contains('{')) {
        return LabelOverlay._interpolateTemplate(raw, ctx.properties);
      }
      return raw.isEmpty ? null : raw;
    }
    final name = stringifyStyleValue(_icon.evaluate(ctx));
    if (name.isEmpty || name == 'null') return null;
    return name;
  }

  double offsetEms(EvaluationContext ctx, int index) {
    if (index >= _offsets.length) return 0;
    final value = _offsets[index].evaluate(ctx);
    return value is num ? value.toDouble() : 0;
  }
}

class _PreparedLabel {
  final String? text;
  final String? icon;
  final String dedupeKey;

  /// Position in tile-local pixels.
  final double localX;
  final double localY;

  /// Rotation angle in radians (0 = horizontal, used for line labels).
  final double angle;

  final double fontSize;
  final ui.Color color;
  final ui.Color? haloColor;
  final double haloWidth;
  final double letterSpacing;
  final String anchor;
  final double offsetDx;
  final double offsetDy;
  final double iconSize;

  TextPainter? _textPainter;
  TextPainter? _haloPainter;

  /// Whether the text painter was already laid out by preparation.
  bool get isTextLaidOut => _textPainter != null;

  /// Whether the halo painter was already laid out by preparation.
  bool get isHaloLaidOut => _haloPainter != null;

  _PreparedLabel({
    required this.text,
    required this.icon,
    required this.dedupeKey,
    required this.localX,
    required this.localY,
    required this.fontSize,
    required this.color,
    required this.haloColor,
    required this.haloWidth,
    required this.letterSpacing,
    required this.anchor,
    required this.offsetDx,
    required this.offsetDy,
    required this.iconSize,
    this.angle = 0,
  });

  TextPainter painter() => _textPainter ??= _build(foreground: null);

  TextPainter haloPainter() => _haloPainter ??= _build(
        foreground: ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2 * haloWidth
          ..strokeJoin = ui.StrokeJoin.round
          ..color = haloColor ?? const ui.Color(0xFFFFFFFF),
      );

  TextPainter _build({ui.Paint? foreground}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: foreground == null ? color : null,
          foreground: foreground,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    );
    painter.layout();
    return painter;
  }

  void dispose() {
    _textPainter?.dispose();
    _haloPainter?.dispose();
  }
}

/// Uniform-grid collision detection: a label may be placed only when its
/// rect does not intersect any previously placed rect.
class _CollisionGrid {
  final double cellSize;
  final Map<int, List<ui.Rect>> _cells = {};

  _CollisionGrid({required this.cellSize});

  bool tryPlace(ui.Rect rect) {
    final minX = (rect.left ~/ cellSize);
    final minY = (rect.top ~/ cellSize);
    final maxX = (rect.right ~/ cellSize);
    final maxY = (rect.bottom ~/ cellSize);

    for (var cx = minX; cx <= maxX; cx++) {
      for (var cy = minY; cy <= maxY; cy++) {
        final cell = _cells[Object.hash(cx, cy)];
        if (cell == null) continue;
        for (final other in cell) {
          if (other.overlaps(rect)) return false;
        }
      }
    }

    for (var cx = minX; cx <= maxX; cx++) {
      for (var cy = minY; cy <= maxY; cy++) {
        _cells.putIfAbsent(Object.hash(cx, cy), () => []).add(rect);
      }
    }
    return true;
  }
}
