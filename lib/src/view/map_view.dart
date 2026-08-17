import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api/geo_point.dart';
import '../api/marker_manager.dart';
import '../api/tile.dart';
import '../api/tile_manager.dart';
import '../api/tile_source.dart';
import '../common/utils.dart';
import '../vector/render/vector_tile_runtime.dart';
import '../vector/style/style_loader.dart';
import 'marker_layer.dart';
import 'render.dart';
import 'zoom_controls.dart';

/// Captures a snapshot of the tile grid geometry and tiles for rendering
/// an "old zoom" overlay during the scale transition.
class _GridSnapshot {
  final int horizontalTileCount;
  final int verticalTileCount;
  final int leftColumnTilesLngIndex;
  final int topRowTilesLatIndex;
  final double leftColumnTilesCanvasX;
  final double topRowTilesCanvasY;
  final List<Tile> tiles;
  final int revision;

  /// Zoom of the snapshotted grid.
  final int zoom;

  /// The POST-step camera center, in the NEW zoom's tile units. The
  /// camera may keep moving while the overlay fades out (an in-progress
  /// pinch pans between zoom steps) — the overlay shift is measured
  /// against this anchor (see [_MapViewState._animPanShift]).
  double anchorTileLng;
  double anchorTileLat;

  _GridSnapshot({
    required this.horizontalTileCount,
    required this.verticalTileCount,
    required this.leftColumnTilesLngIndex,
    required this.topRowTilesLatIndex,
    required this.leftColumnTilesCanvasX,
    required this.topRowTilesCanvasY,
    required this.tiles,
    required this.revision,
    required this.zoom,
    required this.anchorTileLng,
    required this.anchorTileLat,
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
        zoom: m.zoom,
        anchorTileLng: m.centerTileLng,
        anchorTileLat: m.centerTileLat,
      );
}

/// How the old tile grid animates out during a zoom transition
/// ([MapView.zoomAnimationStyle]).
enum ZoomAnimationStyle {
  /// Old tiles scale up (zoom in) or down (zoom out) around the focal
  /// point while fading out.
  scale,

  /// Old tiles scale up/down with a progressive Gaussian blur while
  /// fading out — smooth crossfade that masks pixelation during the
  /// scale. Works for both raster and vector tiles.
  crossfade,
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
///   [onScaleStart], then applies the pixel delta since the last zoom
///   step on every update.
/// - **Pinch to zoom**: two-finger scale gesture changes the zoom level
///   in integer steps as the accumulated scale crosses each rounding
///   boundary. The geographic point under the current focal point stays
///   stationary, and each step plays a zoom animation when
///   [animateZoom] is enabled.
/// - **Double-tap**: zoom in one level with a smooth zoom animation.
///
/// ### Markers
/// Pass a [MarkerManager] to [markers] and mutate it at runtime — markers
/// (any widget, or plain text) render above the tile grid and below the
/// vector label overlay, and are culled when their anchor leaves the
/// viewport. Markers accept [onTap]/[onLongPress] callbacks, and those
/// with a [Marker.overlayBuilder] show a tap-to-toggle overlay that
/// follows the marker across pans and zooms (see [MarkerOverlayConfig]
/// for `removeOnMove` and friends).
///
/// ### Zoom animation (Google Maps style)
/// When [animateZoom] is `true` (default), tapping +/−, double-tapping
/// or crossing a zoom step in a pinch triggers a zoom animation:
///
/// - **[ZoomAnimationStyle.scale]** (default): old tiles scale up
///   (zoom in) or down (zoom out) from the focal point while fading out,
///   revealing the new tiles underneath.
/// - **[ZoomAnimationStyle.crossfade]**: same scale transition with a
///   progressive Gaussian blur that increases as old tiles scale,
///   creating a smooth crossfade that masks pixelation. Works for both
///   raster and vector tiles.
///
/// In both styles, new tiles at the target zoom level are already
/// rendered underneath at native resolution. At the end of the
/// animation, the old overlay is removed — seamless transition.
///
/// The fading old-grid overlay tracks camera pans, so a pinch that keeps
/// panning mid-animation stays visually aligned.
class MapView extends StatefulWidget {
  final LatLng latLng;
  final int zoom;
  final int minZoom;
  final int maxZoom;
  final TileFetcher? tileFetcher;

  /// Markers rendered above the tile grid (and below the vector label
  /// overlay). Mutating the manager at runtime updates the map — pass it
  /// once and call [MarkerManager.add] / [MarkerManager.clear] anywhere.
  final MarkerManager? markers;

  /// Renders a hosted vector style instead of raster tiles (e.g.
  /// [openFreeMapLiberty]). When set, [tileFetcher] is ignored — the
  /// style document defines all tile sources. Raster mode remains the
  /// default when this is null.
  final VectorMapStyle? vectorStyle;

  final bool showZoomControls;
  final ValueChanged<int>? onZoomChanged;

  /// Called after the user pans or zooms the map. Lets the host track the
  /// camera (e.g. to restore it after switching tile sources). Not called
  /// for programmatic [latLng]/[zoom] widget changes.
  final void Function(LatLng center, int zoom)? onCameraChanged;

  final Alignment zoomControlsAlignment;
  final bool animateZoom;
  final Duration zoomAnimationDuration;

  /// Which animation the old tile grid plays during zoom transitions
  /// (double-tap, ± buttons, pinch zoom steps) when [animateZoom] is
  /// enabled. Defaults to [ZoomAnimationStyle.scale].
  final ZoomAnimationStyle zoomAnimationStyle;

  const MapView({
    super.key,
    required this.latLng,
    required this.zoom,
    this.minZoom = 1,
    this.maxZoom = 19,
    this.tileFetcher,
    this.markers,
    this.vectorStyle,
    this.showZoomControls = true,
    this.onZoomChanged,
    this.onCameraChanged,
    this.zoomControlsAlignment = Alignment.bottomRight,
    this.animateZoom = true,
    this.zoomAnimationDuration = const Duration(milliseconds: 350),
    this.zoomAnimationStyle = ZoomAnimationStyle.scale,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  TileManager? _tileManager;
  int _currentZoom = 0;

  // ── Vector style session ────────────────────────────────────────────
  VectorTileRuntime? _vectorRuntime;
  Object? _vectorError;

  // ── Zoom animation ──────────────────────────────────────────────────
  late AnimationController _animController;
  Animation<double>? _scaleAnimation;

  /// Visual scale applied to the OLD grid overlay during animation.
  /// Zoom in: 1.0→2.0, Zoom out: 1.0→0.5.
  double _visualScale = 1.0;

  /// Focal point for the scale transform (in local widget coords).
  Offset _visualScaleFocal = Offset.zero;

  /// Snapshot of the OLD grid (before zoom change) rendered as an overlay
  /// during the scale transition.
  _GridSnapshot? _animOldSnapshot;

  /// Whether we're zooming in (true) or out (false).
  bool _animIsZoomIn = true;

  bool get _isAnimating => _animController.isAnimating;

  // ── Scale gesture state ─────────────────────────────────────────────
  // Anchors captured at gesture start and re-baselined after every zoom
  // step — tile coordinates only make sense in the zoom they were
  // captured at, and a pinch may step through several zoom levels.
  double? _scaleStartTileLng;
  double? _scaleStartTileLat;
  int? _scaleStartZoom;
  Offset? _scaleStartFocal;

  /// Scale at the last (re-)baseline — the accumulated pinch scale is
  /// measured relative to it.
  double? _scaleStartScale;

  // ── Double-tap focal point ──────────────────────────────────────────
  Offset _doubleTapLocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _currentZoom = widget.zoom;
    if (widget.vectorStyle != null) {
      _loadVectorStyle();
    }

    _animController = AnimationController(
      duration: widget.zoomAnimationDuration,
      vsync: this,
    );
    _animController.addListener(_onAnimTick);
    _animController.addStatusListener(_onAnimStatus);
  }

  Future<void> _loadVectorStyle() async {
    final style = widget.vectorStyle;
    if (style == null) return;
    setState(() => _vectorError = null);
    try {
      final loaded = await loadVectorStyle(style);
      if (!mounted || widget.vectorStyle != style) return;
      _vectorRuntime = VectorTileRuntime(
        loaded: loaded,
        namespace: style.id,
      );
    } catch (error) {
      if (!mounted || widget.vectorStyle != style) return;
      _vectorError = error;
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.zoomAnimationDuration != oldWidget.zoomAnimationDuration) {
      _animController.duration = widget.zoomAnimationDuration;
    }
    if (widget.vectorStyle != oldWidget.vectorStyle) {
      // Style switch: tear everything down and reload.
      _tileManager?.dispose();
      _tileManager = null;
      _vectorRuntime?.dispose();
      _vectorRuntime = null;
      _vectorError = null;
      if (widget.vectorStyle != null) {
        _loadVectorStyle();
      } else {
        setState(() {});
      }
      return;
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
    _vectorRuntime?.dispose();
    super.dispose();
  }

  void _notify() {
    if (mounted) setState(() {});
  }

  void _notifyCamera(TileManager manager) {
    widget.onCameraChanged?.call(manager.centerLatLng, manager.zoom);
  }

  TileManager _ensureManager(Size size) {
    final existing = _tileManager;
    if (existing != null) {
      if (existing.width != size.width || existing.height != size.height) {
        existing.resize(size);
      }
      return existing;
    }
    final runtime = _vectorRuntime;
    final manager = TileManager.init(
      width: size.width,
      height: size.height,
      centerLatLng: widget.latLng,
      zoom: widget.zoom,
      fetcher: runtime?.fetcher ?? widget.tileFetcher,
      decoder: runtime?.decoder,
      urlBuilder: runtime?.urlBuilder,
      cacheNamespace: runtime?.namespace ?? '',
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
    _notifyCamera(manager);
    setState(() {});
  }

  // ── Zoom animation ─────────────────────────────────────────────────
  //
  // Google Maps style zoom:
  //
  // 1. Snapshot the current (old) grid
  // 2. Switch TileManager to the NEW zoom immediately
  // 3. During animation:
  //    - NEW tiles rendered at 1.0× as background
  //    - OLD tiles rendered with Transform.scale + opacity fade as overlay
  //    - crossfade style: adds progressive Gaussian blur that increases
  //      with scale, masking pixelation during the transition
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
    _notifyCamera(manager);

    // Re-anchor the snapshot to the POST-step camera so pans from here
    // on shift the overlay by exactly their screen-pixel delta while it
    // fades out. Manager zoom is already the NEW zoom here.
    final snap = _animOldSnapshot!;
    snap.anchorTileLng = manager.centerTileLng;
    snap.anchorTileLat = manager.centerTileLat;

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

  /// The old-grid overlay painted while a zoom animation plays.
  /// Old tiles scale up (zoom in) or down (zoom out) from the focal
  /// point while fading out, revealing the new tiles underneath.
  /// With [ZoomAnimationStyle.crossfade], a progressive Gaussian blur
  /// is added that increases with the scale — masking pixelation and
  /// creating a smooth transition. Works for both raster and vector.
  Widget _buildOldGridOverlay(
    TileManager manager,
    Size size,
    Alignment scaleAlignment,
  ) {
    final snap = _animOldSnapshot!;
    final progress = _animController.value;

    Widget grid = CustomPaint(
      size: size,
      painter: RenderCanvasOSM(
        horizontalTileCount: snap.horizontalTileCount,
        verticalTileCount: snap.verticalTileCount,
        leftColumnTilesLngIndex: snap.leftColumnTilesLngIndex,
        topRowTilesLatIndex: snap.topRowTilesLatIndex,
        leftColumnTilesCanvasX: snap.leftColumnTilesCanvasX,
        topRowTilesCanvasY: snap.topRowTilesCanvasY,
        tiles: snap.tiles,
        revision: snap.revision,
      ),
    );

    // Fade out — easeIn keeps tiles visible longer, then fades fast.
    grid = Opacity(
      opacity: (1.0 - Curves.easeIn.transform(progress)).clamp(0.0, 1.0),
      child: grid,
    );

    // Crossfade: progressive blur proportional to the scale delta.
    if (widget.zoomAnimationStyle == ZoomAnimationStyle.crossfade) {
      final sigma = (_visualScale - 1.0).abs() * 4.0;
      if (sigma > 0.1) {
        grid = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
          ),
          child: grid,
        );
      }
    }

    return Positioned.fill(
      key: const ValueKey('zoom-scale'),
      child: Transform.translate(
        offset: _animPanShift(manager),
        child: Transform.scale(
          scale: _visualScale,
          alignment: scaleAlignment,
          child: grid,
        ),
      ),
    );
  }

  /// How far the camera panned since the animation started, in screen
  /// pixels. Applied to the fading old-grid overlay so an in-progress
  /// pinch (which pans between zoom steps) keeps it glued to the map
  /// instead of ghosting. A camera pan moves every layer by the same
  /// screen pixels regardless of the overlay's own animation scale.
  Offset _animPanShift(TileManager manager) {
    final snap = _animOldSnapshot;
    if (snap == null) return Offset.zero;
    return Offset(
      -(manager.centerTileLng - snap.anchorTileLng) * tileWidth,
      -(manager.centerTileLat - snap.anchorTileLat) * tileHeight,
    );
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
    _scaleStartScale = 1.0;
  }

  void _onScaleUpdate(TileManager manager, ScaleUpdateDetails details) {
    final startZoom = _scaleStartZoom;
    final startFocal = _scaleStartFocal;
    final startScale = _scaleStartScale;
    if (startZoom == null ||
        startFocal == null ||
        startScale == null ||
        startScale <= 0) {
      return;
    }

    final focalLocal = details.localFocalPoint;

    // The map renders integer zoom levels only, so a zoom step is applied
    // when the pinch scale accumulated since the last baseline crosses a
    // rounding boundary. The step anchors on the CURRENT focal point, so
    // the content under the fingers stays put even when the focal drifts
    // during the pinch.
    final zoomDelta =
        math.log(details.scale / startScale) / math.log(2);
    final newZoom =
        (startZoom + zoomDelta).round().clamp(widget.minZoom, widget.maxZoom);

    if (newZoom != manager.zoom) {
      if (widget.animateZoom) {
        // Same scale transition as double-tap and the ± buttons — honors
        // [MapView.zoomAnimationDuration].
        _startZoomAnimation(manager, newZoom, focalLocal);
      } else {
        manager.setZoomWithFocalPoint(newZoom, focalLocal, manager.zoom);
        _currentZoom = newZoom;
        widget.onZoomChanged?.call(newZoom);
        _notifyCamera(manager);
      }

      // Re-baseline the gesture: the camera (and its tile-space anchor)
      // is now in the NEW zoom's units. Without this, the pan below
      // would mix units from different zoom levels and teleport the
      // camera — tile coordinates double with every zoom step.
      _scaleStartZoom = newZoom;
      _scaleStartScale = details.scale;
      _scaleStartTileLng = manager.centerTileLng;
      _scaleStartTileLat = manager.centerTileLat;
      _scaleStartFocal = focalLocal;
      _notifyCamera(manager);
    } else {
      // Pan: anchor-based. Safe because the anchor is always in the
      // CURRENT zoom's units — either from gesture start or from the
      // last re-baseline above.
      final delta = focalLocal - _scaleStartFocal!;
      final newTileLng = _scaleStartTileLng! - delta.dx / tileWidth;
      final newTileLat = _scaleStartTileLat! - delta.dy / tileHeight;
      manager.setCenterFromTileCoords(newTileLng, newTileLat);
      _notifyCamera(manager);
    }

    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _scaleStartTileLng = null;
    _scaleStartTileLat = null;
    _scaleStartZoom = null;
    _scaleStartFocal = null;
  }

  /// Bare-map tap: closes an open marker overlay when its config allows
  /// (`MarkerOverlayConfig.closeOnMapTap`). Marker taps never reach here —
  /// their own recognizer is deeper in the tree and wins the arena.
  void _onMapTap() {
    final markers = widget.markers;
    if (markers == null) return;
    final overlay = markers.overlayMarker;
    if (overlay != null && overlay.overlayConfig.closeOnMapTap) {
      markers.hideOverlay();
    }
  }

  // ── Build ───────────────────────────────────────────────────────────

  /// Shown while a vector style loads (style JSON + TileJSON fetch) or if
  /// it failed — no tile grid can be built until sources resolve.
  Widget _buildStylePlaceholder() {
    if (_vectorError != null) {
      return ColoredBox(
        color: Colors.grey.shade200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: Colors.black54),
              const SizedBox(height: 8),
              Text(
                'Failed to load map style',
                style: TextStyle(color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
      );
    }
    return const ColoredBox(
      color: Color(0xFFF5F5F5),
      child: Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.vectorStyle != null && _vectorRuntime == null) {
      return _buildStylePlaceholder();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final manager = _ensureManager(size);

        // Rebuild the visible grid (cheap: integer math + cache hits).
        manager.calculate();

        final runtime = _vectorRuntime;

        // During scale animation, render two layers.
        final isAnimatingZoom = _isAnimating && _animOldSnapshot != null;

        // Compute scale alignment from focal point.
        final alignmentX =
            (size.width > 0) ? _visualScaleFocal.dx / size.width : 0.5;
        final alignmentY =
            (size.height > 0) ? _visualScaleFocal.dy / size.height : 0.5;
        final scaleAlignment = Alignment(
          alignmentX.clamp(0.0, 1.0),
          alignmentY.clamp(0.0, 1.0),
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: (d) => _onScaleUpdate(manager, d),
          onScaleEnd: _onScaleEnd,
          onTap: _onMapTap,
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

              // ── OLD zoom tiles (overlay, animated out) ─────────────
              // Keyed: this child inserts/removes mid-animation, and an
              // unkeyed insertion reshuffles — recreating the state of —
              // every Stack child after it (marker layer included).
              if (isAnimatingZoom)
                _buildOldGridOverlay(
                  manager,
                  size,
                  scaleAlignment,
                ),

              // ── Markers (above tiles + scale overlay, below labels) ─
              if (widget.markers != null)
                Positioned.fill(
                  child: MarkerLayer(
                    markers: widget.markers!,
                    manager: manager,
                  ),
                ),

              // ── Vector labels (above markers; need viewport-level ──
              // ── collision, not per-tile rendering). Ignored for  ───
              // ── hit testing so markers stay tappable.             ───
              if (runtime != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      size: size,
                      painter: VectorLabelPainter(
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
                        zoom: manager.zoom,
                        overlay: runtime.createLabelOverlay(),
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

              // ── Attribution (required by vector tile providers) ───
              if (runtime != null && runtime.loaded.attribution.isNotEmpty)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(
                        runtime.loaded.attribution,
                        style: TextStyle(
                          fontSize: 9,
                          color: Colors.black.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
