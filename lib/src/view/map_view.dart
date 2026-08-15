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
/// - **Double-tap**: zoom in one level with a smooth scale animation.
/// - The center is clamped to the Web Mercator valid range
///   (±85.0511° latitude, ±180° longitude).
///
/// ### Zoom animation
/// When [animateZoom] is `true` (default), tapping the +/− buttons or
/// double-tapping triggers a smooth visual zoom:
/// - **Zoom in**: tiles scale from 1.0× → 2.0× (centered on focal point),
///   then snap to the new zoom level at 1.0×. This creates the illusion of
///   a continuous camera zoom, identical to Google Maps.
/// - **Zoom out**: tiles scale from 1.0× → 0.5×, then snap to new zoom.
/// Pinch-to-zoom is always instantaneous (continuous gesture).
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

  /// Whether to animate zoom transitions (button tap, double-tap) with a
  /// smooth visual scale effect. Pinch-to-zoom is always smooth via the
  /// continuous gesture.
  /// Defaults to `true`.
  final bool animateZoom;

  /// Duration of zoom animations.
  /// Defaults to 300 milliseconds.
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
    this.zoomAnimationDuration = const Duration(milliseconds: 300),
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  TileManager? _tileManager;
  int _currentZoom = 0;

  // ── Visual zoom animation ───────────────────────────────────────────
  //
  // During an animated zoom, we apply a Transform.scale to the canvas.
  // This creates the illusion of a smooth camera zoom:
  //
  //   Zoom in (Z → Z+1):  scale 1.0 → 2.0, then snap to Z+1 at 1.0
  //   Zoom out (Z → Z-1): scale 1.0 → 0.5, then snap to Z-1 at 1.0
  //
  // The scaled Z tiles look identical to the Z+1 tiles at the same
  // geographic area, so the transition is seamless.

  late AnimationController _animController;
  Animation<double>? _scaleAnimation;

  /// Current visual scale factor applied to the canvas. 1.0 = normal.
  double _visualScale = 1.0;

  /// The screen position (in local widget coordinates) that the scale
  /// transform is anchored to. The geographic point under this position
  /// stays stationary during the animation.
  Offset _visualScaleFocal = Offset.zero;

  /// The zoom level we're animating *toward*.
  int _animTargetZoom = 0;

  /// Whether an animation is currently in progress.
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
      // Instant zoom — no animation.
      _applyZoomInstantly(manager, newZoom, focalLocal);
      return;
    }

    // Animated zoom: scale the canvas visually, then snap at the end.
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

  // ── Animation lifecycle ─────────────────────────────────────────────

  void _startZoomAnimation(
      TileManager manager, int targetZoom, Offset? focalLocal) {
    // Cancel any in-progress animation.
    _animController.stop();

    final isZoomIn = targetZoom > manager.zoom;
    _animTargetZoom = targetZoom;

    // Focal point: where the user tapped, or viewport center.
    _visualScaleFocal =
        focalLocal ?? Offset(manager.centerCanvasX, manager.centerCanvasY);

    // Scale animation:
    //   Zoom in:  1.0 → 2.0  (tiles grow, then snap to Z+1 at 1.0)
    //   Zoom out: 1.0 → 0.5  (tiles shrink, then snap to Z-1 at 1.0)
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: isZoomIn ? 2.0 : 0.5,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    ));

    _animController.forward(from: 0.0);
  }

  void _onAnimTick() {
    if (!mounted) return;
    final scale = _scaleAnimation?.value;
    if (scale == null) return;
    _visualScale = scale;
    setState(() {});
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;

    final manager = _tileManager;
    if (manager == null) return;

    // Animation finished — snap to the target zoom level.
    final oldZoom = manager.zoom;
    manager.setZoomWithFocalPoint(
        _animTargetZoom, _visualScaleFocal, oldZoom);
    _currentZoom = _animTargetZoom;
    _visualScale = 1.0; // Reset scale
    widget.onZoomChanged?.call(_animTargetZoom);
    setState(() {});
  }

  // ── Scale gesture handlers (pan + pinch-to-zoom) ────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    final manager = _tileManager;
    if (manager == null) return;

    // Cancel any ongoing zoom animation.
    if (_isAnimating) {
      _animController.stop();
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

        // Compute the Transform alignment from the focal point.
        // Transform.alignment is in the range [0,1] relative to the child size.
        final alignmentX =
            (size.width > 0) ? _visualScaleFocal.dx / size.width : 0.5;
        final alignmentY =
            (size.height > 0) ? _visualScaleFocal.dy / size.height : 0.5;
        final scaleAlignment =
            Alignment(alignmentX.clamp(0, 1), alignmentY.clamp(0, 1));

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
              // Tile canvas — wrapped in Transform.scale during animation.
              Positioned.fill(
                child: Transform.scale(
                  scale: _visualScale,
                  alignment: scaleAlignment,
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
              ),

              // Zoom controls overlay (not affected by the scale transform).
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
