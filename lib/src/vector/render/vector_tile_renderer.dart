import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../mvt/vector_tile.dart';
import '../style/css_color.dart';
import '../style/expression.dart';
import '../style/map_style.dart';
import '../style/style_loader.dart';

/// Maps source-layer coordinates (0..extent of the *source* tile) to pixel
/// coordinates inside the 256px tile being rendered, including the
/// over-zoom case where the source tile is an ancestor at a lower zoom.
class TileTransform {
  /// Pixels per source-unit.
  final double scale;

  /// Sub-tile origin in source units (0 when not over-zoomed).
  final double offsetX;
  final double offsetY;

  const TileTransform({
    required this.scale,
    required this.offsetX,
    required this.offsetY,
  });

  factory TileTransform.forLayer({
    required int z,
    required int x,
    required int y,
    required int srcZ,
    required int extent,
  }) {
    final dz = z - srcZ;
    if (dz <= 0) {
      final unitPx = 256.0 / extent;
      return TileTransform(scale: unitPx, offsetX: 0, offsetY: 0);
    }
    final sub = 1 << dz;
    final extentPerTile = extent / sub;
    final relX = ((x % sub) + sub) % sub;
    final relY = ((y % sub) + sub) % sub;
    return TileTransform(
      scale: 256.0 / extentPerTile,
      offsetX: relX * extentPerTile,
      offsetY: relY * extentPerTile,
    );
  }

  double x(double sourceX) => (sourceX - offsetX) * scale;
  double y(double sourceY) => (sourceY - offsetY) * scale;
}

/// Renders one decoded vector tile into a 256×256 [ui.Picture] following
/// the style's layer order and paint properties.
///
/// Performance: features of a layer are batched into as few paths as
/// possible — one path when the layer's paint properties are
/// feature-independent (the common case), or one per distinct evaluated
/// paint signature for data-driven layers — because per-feature
/// [Canvas.drawPath] calls dominate render time on large tiles.
/// Geometry whose bounds fall entirely outside the tile's pixel window
/// (plus a stroke margin) is culled before path building.
///
/// Symbol layers are skipped here — labels need viewport-level collision
/// layout and are painted by the label overlay instead.
class VectorTileRenderer {
  final LoadedVectorStyle loaded;

  VectorTileRenderer(this.loaded);

  static const double tileSize = 256;

  /// How many layers to paint before yielding to the event loop.
  /// OpenFreeMap Liberty has ~111 layers; at typical zooms ~50-70 are
  /// visible. A batch of 8 keeps each chunk under ~2ms on web CanvasKit
  /// so the browser can paint between chunks.
  static const int _layersPerBatch = 8;

  /// Renders the tile asynchronously, yielding between layer batches so
  /// the UI thread stays responsive. [PictureRecorder] and [Canvas] are
  /// plain Dart objects — they survive across async yields within the
  /// same isolate without issue.
  ///
  /// On native, [kIsWeb] is false so no yields occur and this runs
  /// synchronously (the caller already isolates the decode via
  /// `compute`). On web, every [_layersPerBatch] layers yields one
  /// frame so the browser can handle input and paint.
  Future<ui.Picture> renderAsync({
    required DecodedVectorTile decoded,
    required int srcZ,
    required int z,
    required int x,
    required int y,
    Map<String, ui.Image> rasterTiles = const {},
    Map<String, TileCoord> rasterCoords = const {},
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas =
        ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, tileSize, tileSize));
    final ctx = EvaluationContext(zoom: z.toDouble());

    // Pre-filter: collect only the layers that will actually draw at
    // this zoom. OpenFreeMap Liberty has 111 layers but typically
    // 50-70 are visible at any zoom — skipping invisible ones up-front
    // avoids re-checking per batch.
    final visible = <StyleLayer>[
      for (final layer in loaded.style.layers)
        if (layer.isVisible && z >= layer.minZoom && z <= layer.maxZoom)
          layer,
    ];

    var painted = 0;
    for (final layer in visible) {
      switch (layer.type) {
        case StyleLayerType.background:
          _paintBackground(canvas, layer, ctx);
        case StyleLayerType.raster:
          _paintRaster(canvas, layer, ctx, z, x, y, rasterTiles, rasterCoords);
        case StyleLayerType.fill:
          _paintFillLike(canvas, layer, decoded, srcZ, z, x, y, ctx,
              extrusion: false);
        case StyleLayerType.line:
          _paintLines(canvas, layer, decoded, srcZ, z, x, y, ctx);
        case StyleLayerType.circle:
          _paintCircles(canvas, layer, decoded, srcZ, z, x, y, ctx);
        case StyleLayerType.fillExtrusion:
          // Rendered flat (no 3D yet) — still gives building footprints.
          _paintFillLike(canvas, layer, decoded, srcZ, z, x, y, ctx,
              extrusion: true);
        case StyleLayerType.symbol:
          continue; // label overlay
        case StyleLayerType.unknown:
          continue;
      }

      painted++;
      // Yield every N layers on web so the browser can paint between
      // chunks. On native this is a no-op branch (kIsWeb is false).
      if (kIsWeb && painted % _layersPerBatch == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    return recorder.endRecording();
  }

  /// Synchronous render for callers that don't need chunking (tests,
  /// or native code paths that already isolate the decode).
  ui.Picture render({
    required DecodedVectorTile decoded,
    required int srcZ,
    required int z,
    required int x,
    required int y,
    Map<String, ui.Image> rasterTiles = const {},
    Map<String, TileCoord> rasterCoords = const {},
  }) {
    final recorder = ui.PictureRecorder();
    final canvas =
        ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, tileSize, tileSize));
    final ctx = EvaluationContext(zoom: z.toDouble());

    for (final layer in loaded.style.layers) {
      if (!layer.isVisible) continue;
      if (z < layer.minZoom || z > layer.maxZoom) continue;

      switch (layer.type) {
        case StyleLayerType.background:
          _paintBackground(canvas, layer, ctx);
        case StyleLayerType.raster:
          _paintRaster(canvas, layer, ctx, z, x, y, rasterTiles, rasterCoords);
        case StyleLayerType.fill:
          _paintFillLike(canvas, layer, decoded, srcZ, z, x, y, ctx,
              extrusion: false);
        case StyleLayerType.line:
          _paintLines(canvas, layer, decoded, srcZ, z, x, y, ctx);
        case StyleLayerType.circle:
          _paintCircles(canvas, layer, decoded, srcZ, z, x, y, ctx);
        case StyleLayerType.fillExtrusion:
          _paintFillLike(canvas, layer, decoded, srcZ, z, x, y, ctx,
              extrusion: true);
        case StyleLayerType.symbol:
          break;
        case StyleLayerType.unknown:
          break;
      }
    }

    return recorder.endRecording();
  }

  void _paintBackground(ui.Canvas canvas, StyleLayer layer, EvaluationContext ctx) {
    final color =
        evaluateColorExpr(layer.paint['background-color'], ctx) ??
            const ui.Color(0xFF000000);
    final opacity =
        evaluateNumExpr(layer.paint['background-opacity'], ctx, fallback: 1)
            .clamp(0.0, 1.0);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, tileSize, tileSize),
      ui.Paint()..color = _alpha(color, opacity),
    );
  }

  void _paintRaster(
    ui.Canvas canvas,
    StyleLayer layer,
    EvaluationContext ctx,
    int z,
    int x,
    int y,
    Map<String, ui.Image> rasterTiles,
    Map<String, TileCoord> rasterCoords,
  ) {
    final sourceName = layer.source;
    if (sourceName == null) return;
    final image = rasterTiles[sourceName];
    final coord = rasterCoords[sourceName];
    if (image == null || coord == null) return;

    final opacity =
        evaluateNumExpr(layer.paint['raster-opacity'], ctx, fallback: 1)
            .clamp(0.0, 1.0);
    if (opacity <= 0) return;

    // The raster tile may be an ancestor (over-zoom): draw the sub-rect
    // covering this logical tile.
    final dz = z - coord.z;
    final sub = 1 << dz;
    final relX = ((x % sub) + sub) % sub;
    final relY = ((y % sub) + sub) % sub;
    final srcSize = image.width / sub;
    final src = ui.Rect.fromLTWH(
      relX * srcSize,
      relY * srcSize,
      srcSize,
      srcSize,
    );
    canvas.drawImageRect(
      image,
      src,
      const ui.Rect.fromLTWH(0, 0, tileSize, tileSize),
      ui.Paint()
        ..color = const ui.Color(0xFFFFFFFF).withValues(alpha: opacity)
        ..filterQuality = ui.FilterQuality.medium,
    );
  }

  DecodedLayer? _sourceData(StyleLayer layer, DecodedVectorTile decoded) {
    final sourceLayer = layer.sourceLayer;
    if (sourceLayer == null) return null;
    return decoded.layerByName(sourceLayer);
  }

  TileTransform _transformFor(
    DecodedLayer data,
    int srcZ,
    int z,
    int x,
    int y,
  ) =>
      TileTransform.forLayer(
        z: z,
        x: x,
        y: y,
        srcZ: srcZ,
        extent: data.extent,
      );

  // ── Fills (and flat fill-extrusions) ─────────────────────────────────

  void _paintFillLike(
    ui.Canvas canvas,
    StyleLayer layer,
    DecodedVectorTile decoded,
    int srcZ,
    int z,
    int x,
    int y,
    EvaluationContext baseCtx, {
    required bool extrusion,
  }) {
    final data = _sourceData(layer, decoded);
    if (data == null || data.features.isEmpty) return;

    final prefix = extrusion ? 'fill-extrusion' : 'fill';
    final colorExpr = layer.paint['$prefix-color'];
    final opacityExpr = layer.paint['$prefix-opacity'];

    final colorIsStatic = !dependsOnProperties(colorExpr);
    final opacityIsStatic = !dependsOnProperties(opacityExpr);

    // A static opacity of 0 retires the layer before any geometry work.
    if (opacityIsStatic) {
      final opacity =
          evaluateNumExpr(opacityExpr, baseCtx, fallback: 1).clamp(0.0, 1.0);
      if (opacity <= 0) return;
    }

    final transform = _transformFor(data, srcZ, z, x, y);
    final bounds =
        const ui.Rect.fromLTWH(-4, -4, tileSize + 8, tileSize + 8);

    final staticColor = colorIsStatic
        ? (evaluateColorExpr(colorExpr, baseCtx) ?? const ui.Color(0xFF000000))
        : null;
    final staticOpacity = opacityIsStatic
        ? evaluateNumExpr(opacityExpr, baseCtx, fallback: 1).clamp(0.0, 1.0)
        : 0.0;

    // Batch key → (color, opacity, path). Static layers collapse to one.
    final groups = <int, _FillBatch>{};

    for (final feature in data.features) {
      if (feature.geomType != MvtGeomType.polygon) continue;
      final featureCtx = EvaluationContext(
        zoom: baseCtx.zoom,
        properties: feature.properties,
      );
      if (!matchesFilter(layer.filter, featureCtx)) continue;

      final ui.Color color;
      final double opacity;
      if (staticColor != null && opacityIsStatic) {
        color = staticColor;
        opacity = staticOpacity;
      } else {
        color = evaluateColorExpr(colorExpr, featureCtx) ??
            const ui.Color(0xFF000000);
        opacity = evaluateNumExpr(opacityExpr, featureCtx, fallback: 1)
            .clamp(0.0, 1.0);
        if (opacity <= 0) continue;
      }

      final key = (color.toARGB32() << 8) | (opacity * 100).round();
      final batch = groups.putIfAbsent(key, () => _FillBatch(color, opacity));
      _addParts(batch.path, feature, transform, bounds, close: true);
    }

    for (final batch in groups.values) {
      canvas.drawPath(
        batch.path,
        ui.Paint()..color = _alpha(batch.color, batch.opacity),
      );
    }
  }

  // ── Lines ────────────────────────────────────────────────────────────

  void _paintLines(
    ui.Canvas canvas,
    StyleLayer layer,
    DecodedVectorTile decoded,
    int srcZ,
    int z,
    int x,
    int y,
    EvaluationContext baseCtx,
  ) {
    final data = _sourceData(layer, decoded);
    if (data == null || data.features.isEmpty) return;

    final colorExpr = layer.paint['line-color'];
    final opacityExpr = layer.paint['line-opacity'];
    final widthExpr = layer.paint['line-width'];

    final cache = _StaticPaintCache(layer, baseCtx);
    final transform = _transformFor(data, srcZ, z, x, y);

    final cap = _strokeCap(cache.raw(baseCtx, layer.layout, 'line-cap'));
    final join = _strokeJoin(cache.raw(baseCtx, layer.layout, 'line-join'));
    final dashRaw = cache.raw(baseCtx, layer.paint, 'line-dasharray');
    final hasDash = dashRaw is List && dashRaw.length >= 2;

    final dataDriven = dependsOnProperties(colorExpr) ||
        dependsOnProperties(opacityExpr) ||
        dependsOnProperties(widthExpr);

    final staticWidth = dataDriven
        ? null
        : cache
            .number(baseCtx, layer.paint, 'line-width', fallback: 1)
            .clamp(0.0, 100.0);

    // Cull margin covers stroke bleed past the tile edge.
    final margin = (staticWidth ?? 16) / 2 + 4;
    final bounds = ui.Rect.fromLTWH(
      -margin,
      -margin,
      tileSize + 2 * margin,
      tileSize + 2 * margin,
    );

    final groups = <String, _LineBatch>{};
    ui.Color staticColor = const ui.Color(0xFF000000);
    double staticOpacity = 1, staticWidthValue = 1;

    if (!dataDriven) {
      staticColor = cache.color(baseCtx, layer.paint, 'line-color') ??
          const ui.Color(0xFF000000);
      staticOpacity = cache
          .number(baseCtx, layer.paint, 'line-opacity', fallback: 1)
          .clamp(0.0, 1.0);
      staticWidthValue = staticWidth ?? 1;
      if (staticOpacity <= 0 || staticWidthValue <= 0) return;
    }

    for (final feature in data.features) {
      if (feature.geomType != MvtGeomType.lineString) continue;
      final featureCtx = EvaluationContext(
        zoom: baseCtx.zoom,
        properties: feature.properties,
      );
      if (!matchesFilter(layer.filter, featureCtx)) continue;

      final ui.Color color;
      final double opacity, width;
      if (!dataDriven) {
        color = staticColor;
        opacity = staticOpacity;
        width = staticWidthValue;
      } else {
        color = evaluateColorExpr(colorExpr, featureCtx) ??
            const ui.Color(0xFF000000);
        opacity = evaluateNumExpr(opacityExpr, featureCtx, fallback: 1)
            .clamp(0.0, 1.0);
        width =
            evaluateNumExpr(widthExpr, featureCtx, fallback: 1).clamp(0.0, 100.0);
        if (opacity <= 0 || width <= 0) continue;
      }

      final key = '${color.toARGB32()}:$opacity:$width';
      final batch =
          groups.putIfAbsent(key, () => _LineBatch(color, opacity, width));
      _addParts(batch.path, feature, transform, bounds, close: false);
    }

    for (final batch in groups.values) {
      final paint = ui.Paint()
        ..color = _alpha(batch.color, batch.opacity)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = batch.width
        ..strokeCap = cap
        ..strokeJoin = join;
      if (hasDash && batch.width >= 0.5) {
        _drawDashed(canvas, batch.path, paint, dashRaw, batch.width);
      } else {
        canvas.drawPath(batch.path, paint);
      }
    }
  }

  // ── Circles ──────────────────────────────────────────────────────────

  void _paintCircles(
    ui.Canvas canvas,
    StyleLayer layer,
    DecodedVectorTile decoded,
    int srcZ,
    int z,
    int x,
    int y,
    EvaluationContext baseCtx,
  ) {
    final data = _sourceData(layer, decoded);
    if (data == null || data.features.isEmpty) return;

    final cache = _StaticPaintCache(layer, baseCtx);
    final transform = _transformFor(data, srcZ, z, x, y);

    final dataDriven = const ['circle-color', 'circle-opacity', 'circle-radius']
        .any((k) => dependsOnProperties(layer.paint[k]));

    final staticColor = cache.color(baseCtx, layer.paint, 'circle-color') ??
        const ui.Color(0xFF000000);
    final staticOpacity = cache
        .number(baseCtx, layer.paint, 'circle-opacity', fallback: 1)
        .clamp(0.0, 1.0);
    final staticRadius = cache
        .number(baseCtx, layer.paint, 'circle-radius', fallback: 5)
        .clamp(0.0, 512.0);
    final strokeWidth = cache
        .number(baseCtx, layer.paint, 'circle-stroke-width', fallback: 0)
        .clamp(0.0, 100.0);
    final strokeColor =
        cache.color(baseCtx, layer.paint, 'circle-stroke-color') ??
            const ui.Color(0xFF000000);
    final strokeOpacity = cache
        .number(baseCtx, layer.paint, 'circle-stroke-opacity', fallback: 1)
        .clamp(0.0, 1.0);

    if (!dataDriven && (staticOpacity <= 0 || staticRadius <= 0)) return;

    final fill = ui.Paint()..color = _alpha(staticColor, staticOpacity);
    final stroke = (strokeWidth > 0 && strokeOpacity > 0)
        ? (ui.Paint()
          ..color = _alpha(strokeColor, strokeOpacity)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = strokeWidth)
        : null;

    final margin = staticRadius + strokeWidth + 4;
    final bounds = ui.Rect.fromLTRB(
      -margin,
      -margin,
      tileSize + margin,
      tileSize + margin,
    );

    for (final feature in data.features) {
      final featureCtx = EvaluationContext(
        zoom: baseCtx.zoom,
        properties: feature.properties,
      );
      if (!matchesFilter(layer.filter, featureCtx)) continue;

      double opacity = staticOpacity, radius = staticRadius;
      ui.Color color = staticColor;
      if (dataDriven) {
        opacity = evaluateNumExpr(
                layer.paint['circle-opacity'], featureCtx,
                fallback: staticOpacity)
            .clamp(0.0, 1.0);
        radius = evaluateNumExpr(
                layer.paint['circle-radius'], featureCtx,
                fallback: staticRadius)
            .clamp(0.0, 512.0);
        color = evaluateColorExpr(layer.paint['circle-color'], featureCtx) ??
            staticColor;
        if (opacity <= 0 || radius <= 0) continue;
      }

      for (final part in feature.geometry) {
        if (part.length < 2) continue;
        final center = ui.Offset(
          transform.x(part[0]),
          transform.y(part[1]),
        );
        if (!bounds.contains(center)) continue;
        canvas.drawCircle(
          center,
          radius,
          dataDriven ? (ui.Paint()..color = _alpha(color, opacity)) : fill,
        );
        if (stroke != null) canvas.drawCircle(center, radius, stroke);
      }
    }
  }

  // ── Geometry → path helpers ──────────────────────────────────────────

  /// Adds a feature's geometry to [path], skipping parts whose bounds fall
  /// entirely outside [bounds] (cheap pixel-space pre-test — the raster
  /// would clip them anyway, but they cost path verbs and draw dispatch).
  void _addParts(
    ui.Path path,
    DecodedFeature feature,
    TileTransform transform,
    ui.Rect bounds, {
    required bool close,
  }) {
    for (final part in feature.geometry) {
      if (part.length < 4) {
        if (!close && part.length >= 2) {
          // Degenerate single-segment line: keep it for round-cap dots.
          final px = transform.x(part[0]);
          final py = transform.y(part[1]);
          if (px < bounds.left || px > bounds.right) continue;
          if (py < bounds.top || py > bounds.bottom) continue;
          path.moveTo(px, py);
          path.lineTo(px, py);
        }
        continue;
      }
      if (_partOutside(part, transform, bounds)) continue;
      for (var i = 0; i + 1 < part.length; i += 2) {
        final px = transform.x(part[i]);
        final py = transform.y(part[i + 1]);
        if (i == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }
      if (close) path.close();
    }
  }

  bool _partOutside(Float32List part, TileTransform transform, ui.Rect bounds) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (var i = 0; i + 1 < part.length; i += 2) {
      final px = transform.x(part[i]);
      final py = transform.y(part[i + 1]);
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
    }
    return maxX < bounds.left ||
        minX > bounds.right ||
        maxY < bounds.top ||
        minY > bounds.bottom;
  }

  /// Flutter has no dash API — walk path metrics and stroke the "on"
  /// segments. Dash values are multiples of the line width (style spec).
  void _drawDashed(
    ui.Canvas canvas,
    ui.Path path,
    ui.Paint paint,
    List<dynamic> dash,
    double width,
  ) {
    final pattern = <double>[
      for (final v in dash) (v is num ? v.toDouble() : 0.0) * width,
    ];
    final anyPositive = pattern.any((v) => v > 0);
    if (!anyPositive) {
      canvas.drawPath(path, paint);
      return;
    }

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      var segment = 0;
      var draw = true;
      final length = metric.length;
      while (distance < length) {
        final segmentLength = pattern[segment % pattern.length];
        final next = (distance + segmentLength).clamp(0.0, length);
        if (draw && segmentLength > 0) {
          canvas.drawPath(metric.extractPath(distance, next), paint);
        }
        distance = next;
        segment++;
        draw = !draw;
        if (segmentLength <= 0 && segment > pattern.length * 2) break;
      }
    }
  }

  static ui.Color _alpha(ui.Color color, double opacity) =>
      color.withValues(alpha: color.a * opacity.clamp(0.0, 1.0));

  static ui.StrokeCap _strokeCap(dynamic value) =>
      switch (value) {
        'round' => ui.StrokeCap.round,
        'square' => ui.StrokeCap.square,
        _ => ui.StrokeCap.butt,
      };

  static ui.StrokeJoin _strokeJoin(dynamic value) =>
      switch (value) {
        'round' => ui.StrokeJoin.round,
        'bevel' => ui.StrokeJoin.bevel,
        _ => ui.StrokeJoin.miter,
      };
}

class _FillBatch {
  final ui.Color color;
  final double opacity;

  /// nonZero (MVT exterior-CW / hole-CCW winding) so overlapping polygons
  /// of the same batch union instead of XOR-ing holes into each other.
  final ui.Path path = ui.Path();

  _FillBatch(this.color, this.opacity);
}

class _LineBatch {
  final ui.Color color;
  final double opacity;
  final double width;
  final ui.Path path = ui.Path();

  _LineBatch(this.color, this.opacity, this.width);
}

/// Caches paint values that only depend on zoom (not on feature
/// properties), so they are evaluated once per layer per tile instead of
/// once per feature.
class _StaticPaintCache {
  final EvaluationContext baseCtx;
  final Map<String, dynamic> _cache = {};

  _StaticPaintCache(StyleLayer layer, this.baseCtx);

  dynamic raw(EvaluationContext featureCtx, Map<String, dynamic> props, String key) {
    final expr = props[key];
    if (expr == null) return null;
    if (dependsOnProperties(expr)) {
      return evaluateExpression(expr, featureCtx);
    }
    return _cache.putIfAbsent(key, () => evaluateExpression(expr, baseCtx));
  }

  double number(
    EvaluationContext featureCtx,
    Map<String, dynamic> props,
    String key, {
    required double fallback,
  }) {
    final value = raw(featureCtx, props, key);
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  ui.Color? color(
    EvaluationContext featureCtx,
    Map<String, dynamic> props,
    String key,
  ) {
    final value = raw(featureCtx, props, key);
    if (value is ui.Color) return value;
    if (value is String) return parseCssColor(value);
    return null;
  }
}
