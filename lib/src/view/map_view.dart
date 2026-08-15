import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/geo_point.dart';
import '../api/tile.dart';
import '../api/tile_manager.dart';
import '../api/tile_source.dart';
import '../common/osm_transformation_utilities.dart';
import '../common/utils.dart';
import 'render.dart';
import 'zoom_controls.dart';

/// Captures a snapshot of the tile grid geometry and tiles for rendering
/// an "old zoom" overlay during the crossfade animation.
class _GridSnapshot {
  final int horizontalTileCount;
  final int verticalTileCount;
  final int leftColumnTilesLngIndex;
  final int topRowTilesLatIndex;
  final double leftColumnTilesCanvasX;
  final double topRowTilesCanvasY;
  final List<Tile> tiles;
  final int revision;

  _GridSnapshot({
    required this.horizontalTileCount,
    required this.verticalTileCount,
    required this.leftColumnTilesLngIndex,
    required this.topRowTilesLatIndex,
    required this.leftColumnTilesCanvasX,
    required this.topRowTilesCanvasY,
    required this.tiles,
    required this.revision,
  });

  factory _GridSnapshot.from(TileManager m) => _GridSnapshot(
        horizontalTileCount: m.horizontalTileCount,
        verticalTileCount: m.verticalTileCount,
        leftColumnTilesLngIndex: m.leftColumnTilesLngIndex,
        topRowTilesLatIndex: m.topRowTilesLatIndex,
        leftColumnTilesCanvasX: m.leftColumnTilesCanvasX,
        topRowTilesCanvasY: m.topRowTilesCanvasY,
        tiles: List<Tile>.from(m.renderTiles),
        revision: m.revision,
      );
}

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
/// - **Pinch to zoom**: two-finger scale gesture changes the zoom level.
///   The geographic point under the focal point stays stationary.
/// - **Double-tap**: zoom in one level with a smooth crossfade animation.
///
/// ### Zoom animation (Google Maps / Leaflet style)
/// When [animateZoom] is `true` (default), tapping +/− or double-tapping
/// triggers a **crossfade** between old and new zoom tiles:
/// 1. Old tiles scale up (zoom in) or down (zoom out) while fading out
/// 2. New tiles at the target zoom level are already rendered underneath
///    at their native resolution, fading in
/// 3. At the end, the old overlay is removed — seamless transition
class MapView extends StatefulWidget {
  final LatLng latLng;
  final int zoom;
  final int minZoom;
  final int maxZoom;
  final TileFetcher? tileFetcher;
  final bool showZoomControls;
  final ValueChanged<int>? onZoomChanged;
  final Alignment zoomControlsAlignment;
  final bool animateZoom;
  final Duration zoomAnimationDuration;

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
    this.animateZoom = true,
    this.zoomAnimationDuration = const Duration(milliseconds: 350),
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  TileManager? _tileManager;
  int _currentZoom = 0;

  // ── Zoom animation ──────────────────────────────────────────────────
  late AnimationController _animController;
  Animation<double>? _scaleAnimation;

  /// Visual scale applied to the OLD grid overlay during animation.
  /// Zoom in: 1.0→2.0, Zoom out: 1.0→0.5.
  double _visualScale = 1.0;

  /// Focal point for the scale transform (in local widget coords).
  Offset _visualScaleFocal = Offset.zero;

  /// Snapshot of the OLD grid (before zoom change) rendered as an overlay
  /// during the crossfade animation.
  _GridSnapshot? _animOldSnapshot;

  /// Whether we're zooming in (true) or out (false).
  bool _animIsZoomIn = true;

  bool get _isAnimating => _animController.isAnimating;

  // ── Scale gesture state ─────────────────────────────────────────────
  double? _scaleStartTileLng;
  double? _scaleStartTileLat;
  int? _scaleStartZoom;
  Offset? _scaleStartFocal;

  // ── Double-tap focal point ──────────────────────────────────────────
  Offset _doubleTapLocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _currentZoom = widget.zoom;

    _animController = AnimationController(
      duration: widget.zoomAnimationDuration,
      vsync: this,
    );
    _animController.addListener(_onAnimTick);
    _animController.addStatusListener(_onAnimStatus);
  }

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.zoomAnimationDuration != oldWidget.zoomAnimationDuration) {
      _animController.duration = widget.zoomAnimationDuration;
    }
    if (widget.latLng != oldWidget.latLng) {
      _tileManager?.setCenterTile(latLng: widget.latLng);
      setState(() {});
    }
    if (widget.zoom != oldWidget.zoom && widget.zoom != _currentZoom) {
      _tileManager?.setZoom(widget.zoom);
      _currentZoom = widget.zoom;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _animController.removeListener(_onAnimTick);
    _animController.removeStatusListener(_onAnimStatus);
    _animController.dispose();
    _tileManager?.dispose();
    super.dispose();
  }

  void _notify() {
    if (mounted) setState(() {});
  }

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

  // ── Zoom trigger methods ────────────────────────────────────────────

  void _zoomIn() => _zoomBy(1, focalLocal: null);
  void _zoomOut() => _zoomBy(-1, focalLocal: null);
  void _zoomInAt(Offset localPosition) => _zoomBy(1, focalLocal: localPosition);

  void _zoomBy(int delta, {Offset? focalLocal}) {
    final manager = _tileManager;
    if (manager == null) return;
    final newZoom =
        (manager.zoom + delta).clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == manager.zoom) return;

    if (!widget.animateZoom) {
      _applyZoomInstantly(manager, newZoom, focalLocal);
      return;
    }

    _startZoomAnimation(manager, newZoom, focalLocal);
  }

  void _applyZoomInstantly(
      TileManager manager, int newZoom, Offset? focalLocal) {
    final oldZoom = manager.zoom;
    final focal =
        focalLocal ?? Offset(manager.centerCanvasX, manager.centerCanvasY);
    manager.setZoomWithFocalPoint(newZoom, focal, oldZoom);
    _currentZoom = newZoom;
    widget.onZoomChanged?.call(newZoom);
    setState(() {});
  }

  // ── Crossfade animation ─────────────────────────────────────────────
  //
  // Google Maps / Leaflet style zoom:
  //
  // 1. Snapshot the current (old) grid
  // 2. Switch TileManager to the NEW zoom immediately
  // 3. During animation:
  //    - NEW tiles (TileManager's current state) rendered at 1.0× as background
  //    - OLD tiles (snapshot) rendered with Transform.scale + opacity fade as overlay
  // 4. At animation end: remove old overlay
  //
  // The old tiles scale up (zoom in: 1→2×) or down (zoom out: 1→0.5×)
  // while fading out, revealing the crisp new tiles underneath.

  void _startZoomAnimation(
      TileManager manager, int targetZoom, Offset? focalLocal) {
    // Cancel any in-progress animation.
    _animController.stop();
    _animOldSnapshot = null;

    // 1. Ensure grid is up-to-date and snapshot the OLD grid.
    manager.calculate();
    _animOldSnapshot = _GridSnapshot.from(manager);
    _animIsZoomIn = targetZoom > manager.zoom;

    // 2. Switch TileManager to the TARGET zoom immediately.
    //    The new grid will be rendered as the background layer.
    final focal =
        focalLocal ?? Offset(manager.centerCanvasX, manager.centerCanvasY);
    _visualScaleFocal = focal;
    manager.setZoomWithFocalPoint(targetZoom, focal, manager.zoom);
    _currentZoom = targetZoom;
    widget.onZoomChanged?.call(targetZoom);

    // 3. Set up the scale animation for the old grid overlay.
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: _animIsZoomIn ? 2.0 : 0.5,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    ));

    _visualScale = 1.0;
    _animController.forward(from: 0.0);
  }

  void _onAnimTick() {
    if (!mounted) return;
    _visualScale = _scaleAnimation?.value ?? 1.0;
    setState(() {});
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;

    // Animation done — remove old grid overlay.
    _animOldSnapshot = null;
    _visualScale = 1.0;
    setState(() {});
  }

  // ── Scale gesture handlers (pan + pinch-to-zoom) ────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    final manager = _tileManager;
    if (manager == null) return;

    // Cancel any ongoing zoom animation.
    if (_isAnimating) {
      _animController.stop();
      _animOldSnapshot = null;
      _visualScale = 1.0;
    }

    _scaleStartTileLng = manager.centerTileLng;
    _scaleStartTileLat = manager.centerTileLat;
    _scaleStartZoom = manager.zoom;
    _scaleStartFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(TileManager manager, ScaleUpdateDetails details) {
    final startZoom = _scaleStartZoom;
    final startTileLng = _scaleStartTileLng;
    final startTileLat = _scaleStartTileLat;
    if (startZoom == null ||
        startTileLng == null ||
        startTileLat == null) {
      return;
    }

    final scale = details.scale;
    final zoomDelta =
        (scale > 0) ? (math.log(scale) / math.log(2)) : 0.0;
    final newZoom =
        (startZoom + zoomDelta).round().clamp(widget.minZoom, widget.maxZoom);

    final focalLocal = details.localFocalPoint;

    if (newZoom != manager.zoom) {
      final focalTileLng = startTileLng +
          (_scaleStartFocal!.dx - manager.centerCanvasX) / tileWidth;
      final focalTileLat = startTileLat +
          (_scaleStartFocal!.dy - manager.centerCanvasY) / tileHeight;
      final focalLng = tileX2Lng(focalTileLng, startZoom);
      final focalLat = tileY2Lat(focalTileLat, startZoom);

      final newFocalTileLng = lon2TileX(focalLng, newZoom);
      final newFocalTileLat = lat2TileY(focalLat, newZoom);

      final newCenterTileLng = newFocalTileLng -
          (focalLocal.dx - manager.centerCanvasX) / tileWidth;
      final newCenterTileLat = newFocalTileLat -
          (focalLocal.dy - manager.centerCanvasY) / tileHeight;

      manager.zoom = newZoom;
      _currentZoom = newZoom;
      manager.setCenterFromTileCoords(newCenterTileLng, newCenterTileLat);
      widget.onZoomChanged?.call(newZoom);
    } else {
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

        // During crossfade animation, render two layers.
        final isCrossfade = _isAnimating && _animOldSnapshot != null;

        // Compute scale alignment from focal point.
        final alignmentX =
            (size.width > 0) ? _visualScaleFocal.dx / size.width : 0.5;
        final alignmentY =
            (size.height > 0) ? _visualScaleFocal.dy / size.height : 0.5;
        final scaleAlignment = Alignment(
          alignmentX.clamp(0.0, 1.0),
          alignmentY.clamp(0.0, 1.0),
        );

        // Compute crossfade progress (0→1) from the scale value.
        final crossfadeProgress = isCrossfade
            ? (_animIsZoomIn
                ? (_visualScale - 1.0).clamp(0.0, 1.0)
                : ((1.0 - _visualScale) / 0.5).clamp(0.0, 1.0))
            : 0.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: (d) => _onScaleUpdate(manager, d),
          onScaleEnd: _onScaleEnd,
          onDoubleTapDown: (details) {
            _doubleTapLocal = details.localPosition;
          },
          onDoubleTap: () => _zoomInAt(_doubleTapLocal),
          child: Stack(
            children: [
              // ── NEW zoom tiles (background, always at 1.0×) ───────
              Positioned.fill(
                child: CustomPaint(
                  size: size,
                  painter: RenderCanvasOSM(
                    horizontalTileCount: manager.horizontalTileCount,
                    verticalTileCount: manager.verticalTileCount,
                    leftColumnTilesLngIndex:
                        manager.leftColumnTilesLngIndex,
                    topRowTilesLatIndex: manager.topRowTilesLatIndex,
                    leftColumnTilesCanvasX:
                        manager.leftColumnTilesCanvasX,
                    topRowTilesCanvasY: manager.topRowTilesCanvasY,
                    tiles: manager.renderTiles,
                    revision: manager.revision,
                  ),
                ),
              ),

              // ── OLD zoom tiles (overlay, scaled + fading out) ─────
              if (isCrossfade)
                Positioned.fill(
                  child: Transform.scale(
                    scale: _visualScale,
                    alignment: scaleAlignment,
                    child: Opacity(
                      // Old tiles fade out as new tiles appear.
                      // Use easeIn curve so old tiles stay visible longer
                      // at the start, then fade quickly at the end.
                      opacity: (1.0 - Curves.easeIn.transform(crossfadeProgress))
                          .clamp(0.0, 1.0),
                      child: CustomPaint(
                        size: size,
                        painter: RenderCanvasOSM(
                          horizontalTileCount:
                              _animOldSnapshot!.horizontalTileCount,
                          verticalTileCount:
                              _animOldSnapshot!.verticalTileCount,
                          leftColumnTilesLngIndex:
                              _animOldSnapshot!.leftColumnTilesLngIndex,
                          topRowTilesLatIndex:
                              _animOldSnapshot!.topRowTilesLatIndex,
                          leftColumnTilesCanvasX:
                              _animOldSnapshot!.leftColumnTilesCanvasX,
                          topRowTilesCanvasY:
                              _animOldSnapshot!.topRowTilesCanvasY,
                          tiles: _animOldSnapshot!.tiles,
                          revision: _animOldSnapshot!.revision,
                        ),
                      ),
                    ),
                  ),
                ),

              // ── Zoom controls (not affected by scale) ────────────
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
