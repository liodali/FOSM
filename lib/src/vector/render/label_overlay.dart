import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle;

import '../../api/tile.dart';
import '../style/expression.dart';
import '../style/map_style.dart';
import 'vector_tile_renderer.dart';
import 'vector_tile_runtime.dart';

/// Paints symbol layers (place labels, POI icons, …) on top of the tile
/// grid for the whole viewport.
///
/// Labels cannot be baked into tile images: text would be clipped at tile
/// borders and duplicated by the MVT buffer overlap. Instead this overlay
/// lays out labels once per tile+zoom (cached), then applies viewport
/// collision each frame — first-come-first-served in style layer order,
/// matching MapLibre's priority semantics.
///
/// Only point placements are supported; `symbol-placement: line` (road
/// names along paths) is a follow-up.
class LabelOverlay {
  final VectorTileRuntime runtime;

  LabelOverlay(this.runtime);

  static const int maxLabelsPerFrame = 400;
  static const int _maxPreparedTiles = 64;

  /// Prepared labels keyed by tile index + zoom (stable across pans).
  final LinkedHashMap<String, List<_PreparedLabel>> _prepared =
      LinkedHashMap();

  void paint(
    ui.Canvas canvas,
    ui.Size size, {
    required int zoom,
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

      final originX =
          leftColumnTilesCanvasX + (tile.lngIndex - leftColumnTilesLngIndex) * 256.0;
      final originY =
          topRowTilesCanvasY + (tile.latIndex - topRowTilesLatIndex) * 256.0;
      // Skip tiles fully off-canvas (padding ring included).
      if (originX <= -256 || originY <= -256 ||
          originX >= size.width + 256 || originY >= size.height + 256) {
        continue;
      }

      final labels = _labelsFor(tile.index, zoom, x, y, parsed);
      for (final label in labels) {
        if (drawn >= maxLabelsPerFrame) break;
        if (!seenSymbols.add(label.dedupeKey)) continue;

        final anchor = ui.Offset(
          originX + label.localX,
          originY + label.localY,
        );
        // Cull before paying for text layout.
        if (anchor.dx < -80 ||
            anchor.dy < -60 ||
            anchor.dx > size.width + 80 ||
            anchor.dy > size.height + 60) {
          continue;
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

        if (label.icon != null && sprite != null) {
          sprite.draw(canvas, label.icon!, anchor, label.iconSize);
        }
        if (haloPainter != null) {
          haloPainter.paint(canvas, anchor + _textOffsetFor(label, haloPainter));
        }
        if (textPainter != null) {
          textPainter.paint(canvas, anchor + _textOffsetFor(label, textPainter));
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

  List<_PreparedLabel> _labelsFor(
    String tileIndex,
    int zoom,
    int tileX,
    int tileY,
    ParsedVectorTile parsed,
  ) {
    final key = '$tileIndex@$zoom';
    final hit = _prepared.remove(key);
    if (hit != null) {
      _prepared[key] = hit;
      return hit;
    }

    final labels = <_PreparedLabel>[];
    final style = runtime.loaded.style;

    for (final layer in style.layers) {
      if (layer.type != StyleLayerType.symbol || !layer.isVisible) continue;
      if (zoom < layer.minZoom || zoom > layer.maxZoom) continue;
      if (layer.layout['symbol-placement'] == 'line') continue; // v1: points
      final sourceLayer = layer.sourceLayer;
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
        if (feature.geometry.isEmpty || feature.geometry.first.length < 2) {
          continue;
        }
        final ctx = EvaluationContext(
          zoom: zoom.toDouble(),
          properties: feature.properties,
        );
        if (!matchesFilter(layer.filter, ctx)) continue;

        final text = _resolveText(layer, ctx);
        final icon = _resolveIcon(layer, ctx);
        if (text == null && icon == null) continue;

        final first = feature.geometry.first;
        labels.add(_PreparedLabel(
          text: text,
          icon: icon,
          dedupeKey: '${layer.id}:${feature.id > 0 ? feature.id : text ?? icon}',
          localX: transform.x(first[0]),
          localY: transform.y(first[1]),
          fontSize: evaluateNumExpr(
            layer.layout['text-size'],
            ctx,
            fallback: 16,
            min: 6,
            max: 64,
          ),
          color: evaluateColorExpr(layer.paint['text-color'], ctx) ??
              const ui.Color(0xFF000000),
          haloColor: evaluateColorExpr(layer.paint['text-halo-color'], ctx),
          haloWidth: evaluateNumExpr(
            layer.paint['text-halo-width'],
            ctx,
            fallback: 0,
            min: 0,
            max: 8,
          ),
          letterSpacing: evaluateNumExpr(
            layer.layout['text-letter-spacing'],
            ctx,
            fallback: 0,
          ),
          anchor: evaluateStringExpr(layer.layout['text-anchor'], ctx) ?? 'center',
          offsetDx: _offsetEms(layer, ctx, 0),
          offsetDy: _offsetEms(layer, ctx, 1),
          iconSize: evaluateNumExpr(
            layer.layout['icon-size'],
            ctx,
            fallback: 1,
            min: 0.5,
            max: 4,
          ),
        ));
      }
    }

    _prepared[key] = labels;
    while (_prepared.length > _maxPreparedTiles) {
      final evicted = _prepared.remove(_prepared.keys.first);
      for (final label in evicted ?? const <_PreparedLabel>[]) {
        label.dispose();
      }
    }
    return labels;
  }

  String? _resolveText(StyleLayer layer, EvaluationContext ctx) {
    final raw = layer.layout['text-field'];
    if (raw == null) return null;
    // Legacy shorthand: a bare string names a property.
    final value = raw is String
        ? (ctx.properties?[raw])
        : evaluateExpression(raw, ctx);
    if (value == null) return null;
    var text = stringifyStyleValue(value);
    switch (evaluateStringExpr(layer.layout['text-transform'], ctx)) {
      case 'uppercase':
        text = text.toUpperCase();
      case 'lowercase':
        text = text.toLowerCase();
    }
    return text.isEmpty ? null : text;
  }

  String? _resolveIcon(StyleLayer layer, EvaluationContext ctx) {
    final raw = layer.layout['icon-image'];
    if (raw == null) return null;
    // Template icons like "{maki}-11" are unsupported — the text label
    // still renders. Name→atlas resolution happens at paint time, once
    // the sprite may have loaded.
    if (raw is String && raw.contains('{')) return null;
    final name = stringifyStyleValue(evaluateExpression(raw, ctx));
    if (name.isEmpty || name == 'null') return null;
    return name;
  }

  double _offsetEms(StyleLayer layer, EvaluationContext ctx, int index) {
    final raw = layer.layout['text-offset'];
    if (raw is! List || raw.length <= index) return 0;
    final value = evaluateExpression(raw[index], ctx);
    return value is num ? value.toDouble() : 0;
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

class _PreparedLabel {
  final String? text;
  final String? icon;
  final String dedupeKey;

  /// Position in tile-local pixels.
  final double localX;
  final double localY;

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
  });

  TextPainter painter() => _textPainter ??= _build(foreground: null);

  TextPainter haloPainter() =>
      _haloPainter ??= _build(
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
