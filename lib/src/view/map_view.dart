import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/geo_point.dart';
import '../api/tile_manager.dart';
import '../api/tile_source.dart';
import '../common/osm_transformation_utilities.dart';
import '../common/utils.dart';
import 'render.dart';
import 'zoom_controls.dart';

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
///   [onScaleStart], then applies the total pixel delta on every update.
///   This avoids the cumulative drift that an incremental lat↔lng
///   round-trip produces.
/// - **Pinch to zoom**: two-finger scale gesture changes the zoom level.
///   The geographic point under the focal point stays stationary.
/// - The center is clamped to the Web Mercator valid range
///   (±85.0511° latitude, ±180° longitude).
class MapView extends StatefulWidget {
  final LatLng latLng;
  final int zoom;
  
  /// Minimum zoom level (default 1). OSM tiles are available from z=0.
  final int minZoom;
  
  /// Maximum zoom level (default 19). OSM tiles are available up to z=19.
  final int maxZoom;

  /// Optional custom tile fetcher. Defaults to [osmTileFetcher].
  /// Useful for custom tile servers (Mapbox, Esri, etc.) or testing.
  final TileFetcher? tileFetcher;

  /// Whether to show floating +/− zoom controls.
  /// Defaults to `true`.
  final bool showZoomControls;

  /// Called whenever the zoom level changes (via pinch, button, or
  /// double-tap). The argument is the new zoom level.
  final ValueChanged<int>? onZoomChanged;

  /// Position of the zoom controls overlay.
  /// Defaults to [Alignment.bottomRight].
  final Alignment zoomControlsAlignment;

  const MapView({
    super.key,
    required this.latLng,
    required this.zoom,
    this.minZoom = 1,
    this.maxZoom = 19,
    this.tileFetcher,
    this.showZoomControls = true,
    this.onZoomChanged,
    this.zoomControlsAlignment = Alignment.bottomRight,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  TileManager? _tileManager;
  int _currentZoom = 0; // initialized in initState

  // ── Scale gesture state ─────────────────────────────────────────────
  double? _scaleStartTileLng;
  double? _scaleStartTileLat;
  int? _scaleStartZoom;
  Offset? _scaleStartFocal;

  @override
  void initState() {
    super.initState();
    _currentZoom = widget.zoom;
  }

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
    if (widget.zoom != oldWidget.zoom && widget.zoom != _currentZoom) {
      // External zoom change (e.g. from a zoom button)
      _tileManager?.setZoom(widget.zoom);
      _currentZoom = widget.zoom;
      setState(() {});
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

  // ── Zoom helpers ────────────────────────────────────────────────────

  void _zoomIn() => _zoomBy(1);
  void _zoomOut() => _zoomBy(-1);

  void _zoomBy(int delta) {
    final manager = _tileManager;
    if (manager == null) return;
    final newZoom = (manager.zoom + delta).clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == manager.zoom) return;

    // Zoom centered on the viewport center.
    final oldZoom = manager.zoom;
    final centerLocal = Offset(manager.centerCanvasX, manager.centerCanvasY);
    manager.setZoomWithFocalPoint(newZoom, centerLocal, oldZoom);
    _currentZoom = newZoom;
    widget.onZoomChanged?.call(newZoom);
    setState(() {});
  }

  // ── Scale gesture handlers (pan + pinch-to-zoom) ────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    final manager = _tileManager;
    if (manager == null) return;
    _scaleStartTileLng = manager.centerTileLng;
    _scaleStartTileLat = manager.centerTileLat;
    _scaleStartZoom = manager.zoom;
    _scaleStartFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(TileManager manager, ScaleUpdateDetails details) {
    final startZoom = _scaleStartZoom;
    final startTileLng = _scaleStartTileLng;
    final startTileLat = _scaleStartTileLat;
    if (startZoom == null || startTileLng == null || startTileLat == null) return;

    // Compute new zoom from scale factor.
    // Tile zoom is logarithmic: scale 2.0 = zoom + 1, scale 0.5 = zoom - 1.
    final scale = details.scale;
    final zoomDelta = (scale > 0) ? (math.log(scale) / math.log(2)) : 0.0;
    final newZoom = (startZoom + zoomDelta).round().clamp(widget.minZoom, widget.maxZoom);

    // Current focal point in local coords.
    final focalLocal = details.localFocalPoint;

    if (newZoom != manager.zoom) {
      // Zoom changed — use focal-point-preserving zoom.
      // Geographic point under the focal at start zoom.
      final focalTileLng = startTileLng + (_scaleStartFocal!.dx - manager.centerCanvasX) / tileWidth;
      final focalTileLat = startTileLat + (_scaleStartFocal!.dy - manager.centerCanvasY) / tileHeight;
      final focalLng = tileX2Lng(focalTileLng, startZoom);
      final focalLat = tileY2Lat(focalTileLat, startZoom);

      // At the new zoom, where is this geographic point in tile coords?
      final newFocalTileLng = lon2TileX(focalLng, newZoom);
      final newFocalTileLat = lat2TileY(focalLat, newZoom);

      // New center: focal point stays at current focalLocal on screen.
      final newCenterTileLng = newFocalTileLng - (focalLocal.dx - manager.centerCanvasX) / tileWidth;
      final newCenterTileLat = newFocalTileLat - (focalLocal.dy - manager.centerCanvasY) / tileHeight;

      manager.zoom = newZoom;
      _currentZoom = newZoom;
      manager.setCenterFromTileCoords(newCenterTileLng, newCenterTileLat);
      widget.onZoomChanged?.call(newZoom);
    } else {
      // No zoom change — pure pan.
      // Compute pan delta from the start focal point.
      final delta = focalLocal - _scaleStartFocal!;
      final newTileLng = startTileLng - delta.dx / tileWidth;
      final newTileLat = startTileLat - delta.dy / tileHeight;
      manager.setCenterFromTileCoords(newTileLng, newTileLat);
    }

    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _scaleStartTileLng = null;
    _scaleStartTileLat = null;
    _scaleStartZoom = null;
    _scaleStartFocal = null;
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
          onScaleStart: _onScaleStart,
          onScaleUpdate: (d) => _onScaleUpdate(manager, d),
          onScaleEnd: _onScaleEnd,
          onDoubleTap: _zoomIn,
          child: Stack(
            children: [
              Positioned.fill(
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
              ),
              if (widget.showZoomControls)
                Positioned.fill(
                  child: MapZoomControls(
                    zoom: _currentZoom,
                    minZoom: widget.minZoom,
                    maxZoom: widget.maxZoom,
                    alignment: widget.zoomControlsAlignment,
                    onZoomIn: _zoomIn,
                    onZoomOut: _zoomOut,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
