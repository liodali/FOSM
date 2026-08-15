import 'package:flutter/material.dart';

import '../api/geo_point.dart';
import '../api/tile_manager.dart';
import '../api/tile_source.dart';
import '../common/utils.dart';
import 'render.dart';

/// A native Flutter OSM map widget rendered entirely with [CustomPainter].
///
/// ### Usage
/// ```dart
/// MapView(
///   latLng: LatLng(latitude: 47.4358, longitude: 8.4737),
///   zoom: 7,
/// )
/// ```
///
/// Make sure to call [initMap] before using this widget (typically in
/// `main()`) to initialize the Hive tile cache.
///
/// ### Gesture handling
/// - **Pan / drag**: anchor-based — records the tile-space center at
///   [onPanStart], then applies the total pixel delta on every update.
///   This avoids the cumulative drift that an incremental lat↔lng
///   round-trip produces.
/// - The center is clamped to the Web Mercator valid range
///   (±85.0511° latitude, ±180° longitude).
class MapView extends StatefulWidget {
  final LatLng latLng;
  final int zoom;

  /// Optional custom tile fetcher. Defaults to [osmTileFetcher].
  /// Useful for custom tile servers (Mapbox, Esri, etc.) or testing.
  final TileFetcher? tileFetcher;

  const MapView({
    super.key,
    required this.latLng,
    required this.zoom,
    this.tileFetcher,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  TileManager? _tileManager;

  // ── Pan anchor ──────────────────────────────────────────────────────
  Offset? _panStartLocal;
  double? _panStartTileLng;
  double? _panStartTileLat;

  @override
  void dispose() {
    _tileManager?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.latLng != oldWidget.latLng) {
      _tileManager?.setCenterTile(latLng: widget.latLng);
      setState(() {});
    }
    if (widget.zoom != oldWidget.zoom) {
      // Zoom change invalidates all cached tile keys — rebuild the manager.
      _tileManager?.dispose();
      _tileManager = null;
    }
  }

  void _notify() {
    if (mounted) setState(() {});
  }

  /// Lazily creates the [TileManager] with the real viewport size from
  /// [LayoutBuilder]. Also handles viewport resizing (e.g. rotation).
  TileManager _ensureManager(Size size) {
    final existing = _tileManager;
    if (existing != null) {
      if (existing.width != size.width || existing.height != size.height) {
        existing.resize(size);
      }
      return existing;
    }
    final manager = TileManager.init(
      width: size.width,
      height: size.height,
      centerLatLng: widget.latLng,
      zoom: widget.zoom,
      fetcher: widget.tileFetcher,
    );
    manager.onTilesChanged = _notify;
    _tileManager = manager;
    return manager;
  }

  // ── Gesture handlers ────────────────────────────────────────────────

  void _onPanStart(DragStartDetails details) {
    final manager = _tileManager;
    if (manager == null) return;
    _panStartLocal = details.localPosition;
    _panStartTileLng = manager.centerTileLng;
    _panStartTileLat = manager.centerTileLat;
  }

  void _onPanUpdate(TileManager manager, DragUpdateDetails details) {
    final start = _panStartLocal;
    if (start == null) return;

    final delta = details.localPosition - start;
    final newTileLng = _panStartTileLng! - delta.dx / tileWidth;
    final newTileLat = _panStartTileLat! - delta.dy / tileHeight;

    manager.setCenterFromTileCoords(newTileLng, newTileLat);
    setState(() {});
  }

  void _onPanCancel() {
    _panStartLocal = null;
  }

  void _onPanEnd(DragEndDetails _) {
    _panStartLocal = null;
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final manager = _ensureManager(size);

        // Rebuild the visible grid (cheap: integer math + cache hits).
        manager.calculate();

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _onPanStart,
          onPanUpdate: (d) => _onPanUpdate(manager, d),
          onPanCancel: _onPanCancel,
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: size,
            painter: RenderCanvasOSM(
              horizontalTileCount: manager.horizontalTileCount,
              verticalTileCount: manager.verticalTileCount,
              leftColumnTilesLngIndex: manager.leftColumnTilesLngIndex,
              topRowTilesLatIndex: manager.topRowTilesLatIndex,
              leftColumnTilesCanvasX: manager.leftColumnTilesCanvasX,
              topRowTilesCanvasY: manager.topRowTilesCanvasY,
              tiles: manager.renderTiles,
              revision: manager.revision,
            ),
          ),
        );
      },
    );
  }
}
