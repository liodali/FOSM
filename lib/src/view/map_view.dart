import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/lat_lng_bounds.dart';
import 'package:fosm/src/api/map_controller.dart';
import 'package:fosm/src/api/map_notification.dart';
import 'package:fosm/src/api/map_polyline.dart';
import 'package:fosm/src/api/marker_cluster.dart';
import 'package:fosm/src/api/marker_manager.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/api/tile_source.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/view/marker_layer.dart';
import 'package:fosm/src/view/polyline_layer.dart';
import 'package:fosm/src/view/render.dart';
import 'package:fosm/src/view/zoom_controls.dart';

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
  /// against this anchor.
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

/// The old-grid overlay painted while a zoom animation plays.
///
/// Phase 1 (waiting): old tiles shown with blur, static (scale 1.0),
/// while new tiles load underneath.
///
/// Phase 2 (scale): old tiles scale up/down from the focal point
/// while fading out, with blur masking pixelation. Reveals crisp new
/// tiles underneath. Works for both raster and vector tiles.
class _OldGridOverlay extends StatelessWidget {
  final TileManager manager;
  final Size size;
  final Alignment scaleAlignment;
  final _GridSnapshot snapshot;
  final AnimationController animation;
  final bool waiting;
  final double visualScale;
  final double blurSigma;

  const _OldGridOverlay({
    required this.manager,
    required this.size,
    required this.scaleAlignment,
    required this.snapshot,
    required this.animation,
    required this.waiting,
    required this.visualScale,
    required this.blurSigma,
  });

  @override
  Widget build(BuildContext context) {
    final progress = waiting ? 0.0 : animation.value;

    Widget grid = CustomPaint(
      size: size,
      painter: RenderCanvasOSM(
        horizontalTileCount: snapshot.horizontalTileCount,
        verticalTileCount: snapshot.verticalTileCount,
        leftColumnTilesLngIndex: snapshot.leftColumnTilesLngIndex,
        topRowTilesLatIndex: snapshot.topRowTilesLatIndex,
        leftColumnTilesCanvasX: snapshot.leftColumnTilesCanvasX,
        topRowTilesCanvasY: snapshot.topRowTilesCanvasY,
        tiles: snapshot.tiles,
        revision: snapshot.revision,
      ),
    );

    // Fade out — easeIn keeps tiles visible longer, then fades fast.
    // During the wait phase, tiles stay fully opaque.
    if (!waiting) {
      grid = Opacity(
        opacity: (1.0 - Curves.easeIn.transform(progress)).clamp(0.0, 1.0),
        child: grid,
      );
    }

    // Blur: both styles, different intensity. Progressive during scale.
    final sigma =
        waiting ? blurSigma : blurSigma * (1.0 + (visualScale - 1.0).abs());
    if (sigma > 0.1) {
      grid = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: grid,
      );
    }

    // Keep the fading overlay glued to the map when the camera pans
    // between zoom steps.
    final panShift = Offset(
      -(manager.centerTileLng - snapshot.anchorTileLng) * tileWidth,
      -(manager.centerTileLat - snapshot.anchorTileLat) * tileHeight,
    );

    return Positioned.fill(
      key: const ValueKey('zoom-scale'),
      child: Transform.translate(
        offset: panShift,
        child: Transform.scale(
          scale: visualScale,
          alignment: scaleAlignment,
          child: grid,
        ),
      ),
    );
  }
}

/// How the old tile grid animates out during a zoom transition
/// ([MapView.zoomAnimationStyle]).
///
/// Both styles use a two-phase animation:
/// 1. Old tiles are blurred and held in place while new tiles load
/// 2. Once new tiles are ready, old tiles scale up/down while fading
///    out, revealing the crisp new tiles underneath
///
/// The difference is blur intensity: [ZoomAnimationStyle.crossfade]
/// uses a heavier blur for a softer transition.
enum ZoomAnimationStyle {
  /// Light blur while waiting, then scale + fade.
  scale,

  /// Heavier blur while waiting, then scale + fade — softer transition.
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
/// ### Polylines
/// Pass decoded route geometry as [MapPolyline]s via [polylines] — one
/// `List<LatLng>` per route. FOSM only renders the points; fetching and
/// decoding a routing response is the application's responsibility. Routes
/// render above the tile grid and below markers and vector labels, stay
/// aligned on every pan/zoom, and update when the parent rebuilds with a
/// new (or empty) list.
///
/// Each [MapPolyline] can be styled with a solid, dashed, or dotted
/// pattern, an optional outer border/casing, and configurable caps and
/// joins:
///
/// ```dart
/// MapPolyline(
///   points: routePoints,
///   color: const Color(0xFF3F51B5),
///   strokeWidth: 6,
///   borderColor: Colors.white,
///   borderWidth: 2,
/// )
///
/// MapPolyline(
///   points: alternativeRoute,
///   color: Colors.orange,
///   strokeWidth: 5,
///   pattern: const MapPolylinePattern.dashed(dashLength: 14, gapLength: 8),
///   strokeCap: StrokeCap.round,
///   strokeJoin: StrokeJoin.round,
/// )
/// ```
///
/// Pattern dimensions, stroke widths, and border widths are in logical
/// pixels and do not scale with map zoom. Known limitation: a segment
/// crossing the international date line (e.g. longitude 179 → -179) is
/// drawn as a long straight line rather than wrapping around the world.
///
/// ### Programmatic control
/// Pass a [MapController] to [controller] to drive the camera and
/// markers from outside the widget tree: [MapController.moveTo],
/// [MapController.zoomIn], [MapController.setZoom],
/// [MapController.addMarker], etc. The controller becomes usable after
/// the map's first frame; listen to [MapController.isAttached] or wait
/// for [MapReadyNotification] if you need to call it immediately after
/// building the map.
///
/// ### Map events
/// The map dispatches [MapNotification]s for camera changes, zoom
/// changes, marker taps, and overlay transitions. Any ancestor widget
/// can listen with [NotificationListener] or via
/// [MapEventListenerMixin].
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

  /// Optional hard bounding box the camera can never leave — pans,
  /// pinches, and programmatic moves are all clamped inside it. When the
  /// box is smaller than the viewport, the camera pins to its center.
  /// `null` (default) disables the constraint.
  final LatLngBounds? cameraBounds;

  final TileFetcher? tileFetcher;

  /// Controller for programmatic camera and marker control.
  final MapController? controller;

  /// Markers rendered above the tile grid (and below the vector label
  /// overlay). Mutating the manager at runtime updates the map — pass it
  /// once and call [MarkerManager.add] / [MarkerManager.clear] anywhere.
  final MarkerManager? markers;

  /// Options for clustering [ClusterMarker]s. When null, [ClusterMarker]s
  /// render as ordinary markers and no grouping is performed.
  final MarkerClusterOptions? markerClusterOptions;

  /// Geographic lines rendered above map tiles and below markers/labels.
  /// List order is paint order: later polylines draw above earlier ones.
  final List<MapPolyline> polylines;

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
    this.cameraBounds,
    this.tileFetcher,
    this.controller,
    this.markers,
    this.markerClusterOptions,
    this.polylines = const [],
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

class _MapViewState extends State<MapView>
    with TickerProviderStateMixin
    implements MapControllerDelegate {
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

  /// True during phase 1: old tiles shown with blur, waiting for new
  /// tiles to load. Once new tiles are ready, phase 2 (scale) starts.
  bool _animWaitingTiles = false;

  /// Timeout timer for the wait phase — fires if tiles don't load in
  /// time so the animation doesn't stall forever.
  Timer? _animWaitTimer;

  /// Maximum time to wait for new tiles before starting the scale
  /// animation regardless (avoids infinite hold on slow networks).
  static const _animWaitTimeout = Duration(milliseconds: 600);

  bool get _isAnimating => _animController.isAnimating || _animWaitingTiles;

  // ── Pan animation ───────────────────────────────────────────────────
  AnimationController? _panController;

  // ── Controller ready notification ───────────────────────────────────
  bool _readyNotificationDispatched = false;

  // ── MapControllerDelegate implementation ────────────────────────────
  @override
  LatLng get center => _tileManager?.centerLatLng ?? widget.latLng;

  @override
  int get zoom => _tileManager?.zoom ?? widget.zoom;

  @override
  MarkerManager? get markerManager => widget.markers;

  @override
  void setZoom(int zoom, {bool animate = true}) =>
      _setZoom(zoom, animate: animate);

  @override
  void zoomBy(int delta, {bool animate = true}) =>
      _zoomBy(delta, focalLocal: null, animate: animate);

  @override
  void moveTo(LatLng latLng, {bool animate = true}) =>
      _moveTo(latLng, animate: animate);

  @override
  void fitBounds(LatLngBounds bounds,
          {EdgeInsets padding = EdgeInsets.zero, bool animate = true}) =>
      _fitBounds(bounds, padding: padding, animate: animate);

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

    widget.controller?.attach(this);
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
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?.detach(this);
      widget.controller?.attach(this);
    }
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
    if (widget.cameraBounds != oldWidget.cameraBounds) {
      _tileManager?.setCameraBounds(widget.cameraBounds);
      setState(() {});
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
    widget.controller?.detach(this);
    _animController.removeListener(_onAnimTick);
    _animController.removeStatusListener(_onAnimStatus);
    _animController.dispose();
    _stopPanAnimation();
    _animWaitTimer?.cancel();
    _tileManager?.dispose();
    _vectorRuntime?.dispose();
    super.dispose();
  }

  void _notify() {
    // If we're in the wait phase and new tiles are now ready, kick off
    // the scale animation before setState to avoid a wasted frame.
    if (_animWaitingTiles && _newTilesReady()) {
      _beginScalePhase();
    }
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
      // Vector decodes are expensive (MVT parse + style passes + toImage),
      // so the off-screen padding ring is fetched as bytes only and decoded
      // on demand when it scrolls into view. Raster decodes are cheap and
      // keep decoding the padding ring for instant panning.
      byteOnlyPadding: runtime != null,
      cameraBounds: widget.cameraBounds,
    );
    manager.onTilesChanged = _notify;
    _tileManager = manager;

    if (!_readyNotificationDispatched) {
      _readyNotificationDispatched = true;
      final controller = widget.controller;
      if (controller != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.controller == controller) {
            MapReadyNotification(controller).dispatch(context);
          }
        });
      }
    }

    return manager;
  }

  // ── Zoom trigger methods ────────────────────────────────────────────

  void _zoomIn() => _zoomBy(1, focalLocal: null);
  void _zoomOut() => _zoomBy(-1, focalLocal: null);
  void _zoomInAt(Offset localPosition) => _zoomBy(1, focalLocal: localPosition);

  void _zoomBy(int delta, {Offset? focalLocal, bool? animate}) {
    final manager = _tileManager;
    if (manager == null) return;
    final newZoom =
        (manager.zoom + delta).clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == manager.zoom) return;

    if (!(animate ?? widget.animateZoom)) {
      _applyZoomInstantly(manager, newZoom, focalLocal);
      return;
    }

    _startZoomAnimation(manager, newZoom, focalLocal);
  }

  void _setZoom(int zoom, {bool? animate}) {
    final manager = _tileManager;
    if (manager == null) return;
    final newZoom = zoom.clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == manager.zoom) return;

    if (!(animate ?? widget.animateZoom)) {
      _applyZoomInstantly(manager, newZoom, null);
      return;
    }

    _startZoomAnimation(manager, newZoom, null);
  }

  void _applyZoomInstantly(
      TileManager manager, int newZoom, Offset? focalLocal) {
    final oldZoom = manager.zoom;
    final focal =
        focalLocal ?? Offset(manager.centerCanvasX, manager.centerCanvasY);
    manager.setZoomWithFocalPoint(newZoom, focal, oldZoom);
    _currentZoom = newZoom;
    widget.onZoomChanged?.call(newZoom);
    MapZoomChangeNotification(newZoom).dispatch(context);
    _notifyCamera(manager);
    MapCameraChangeNotification(manager.centerLatLng, manager.zoom)
        .dispatch(context);
    setState(() {});
  }

  void _moveTo(LatLng latLng, {bool? animate}) {
    final manager = _tileManager;
    if (manager == null) return;

    final target = LatLng(
      latitude: clampLatitude(latLng.latitude),
      longitude: clampLongitude(latLng.longitude),
    );

    if (!(animate ?? widget.animateZoom)) {
      manager.setCenterTile(latLng: target);
      _notifyCamera(manager);
      MapCameraChangeNotification(manager.centerLatLng, manager.zoom)
          .dispatch(context);
      if (mounted) setState(() {});
      return;
    }

    _stopPanAnimation();

    final startLng = manager.centerTileLng;
    final startLat = manager.centerTileLat;
    final endLng = lon2TileX(target.longitude, manager.zoom);
    final endLat = lat2TileY(target.latitude, manager.zoom);

    final controller = AnimationController(
      duration: widget.zoomAnimationDuration,
      vsync: this,
    );
    _panController = controller;

    final animation = Tween<Offset>(
      begin: Offset(startLng, startLat),
      end: Offset(endLng, endLat),
    ).animate(CurvedAnimation(
      parent: controller,
      curve: Curves.easeInOut,
    ));

    void onTick() {
      if (!mounted) return;
      final value = animation.value;
      manager.setCenterFromTileCoords(value.dx, value.dy);
      _notifyCamera(manager);
      setState(() {});
    }

    animation.addListener(onTick);
    controller.forward().whenComplete(() {
      animation.removeListener(onTick);
      if (_panController == controller) {
        _panController?.dispose();
        _panController = null;
      }
      if (mounted) {
        MapCameraChangeNotification(manager.centerLatLng, manager.zoom)
            .dispatch(context);
      }
    });
  }

  void _stopPanAnimation() {
    _panController?.stop();
    _panController?.dispose();
    _panController = null;
  }

  /// Frames [bounds] in the viewport, leaving [padding] around it, then
  /// restores free camera movement (unlike [cameraBounds], nothing stays
  /// constrained afterwards). Zoom is integer-only: the computed zoom is
  /// floored and clamped to [MapView.minZoom]/[MapView.maxZoom], so the
  /// box is always fully visible.
  void _fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    bool? animate,
  }) {
    final manager = _tileManager;
    if (manager == null) return;

    final animateFit = animate ?? widget.animateZoom;
    final availW = manager.width - padding.left - padding.right;
    final availH = manager.height - padding.top - padding.bottom;
    if (availW <= 0 || availH <= 0) return;

    // Spans in zoom-0 tile units (tile size 256 px).
    final spanX = lon2TileX(bounds.east, 0) - lon2TileX(bounds.west, 0);
    final spanY = lat2TileY(bounds.south, 0) - lat2TileY(bounds.north, 0);

    // Scale factors for each nonzero span; a zero span (single point on
    // one axis) contributes no constraint.
    final scales = <double>[];
    if (spanX > 0) scales.add(availW / (spanX * tileWidth));
    if (spanY > 0) scales.add(availH / (spanY * tileHeight));

    int targetZoom;
    if (scales.isEmpty) {
      // Degenerate box (single point) → frame it as close as allowed.
      targetZoom = widget.maxZoom;
    } else {
      final scale = scales.reduce(math.min);
      targetZoom = math.max(0, math.log(scale) / math.ln2).floor();
      targetZoom = targetZoom.clamp(widget.minZoom, widget.maxZoom);
    }

    // Projected bounds center, shifted for asymmetric padding.
    final projectedCenterX =
        (lon2TileX(bounds.west, targetZoom) +
            lon2TileX(bounds.east, targetZoom)) /
        2;
    final projectedCenterY =
        (lat2TileY(bounds.north, targetZoom) +
            lat2TileY(bounds.south, targetZoom)) /
        2;
    final centerTileX = projectedCenterX -
        (padding.left - padding.right) / (2 * tileWidth);
    final centerTileY = projectedCenterY -
        (padding.top - padding.bottom) / (2 * tileHeight);
    final targetCenter = LatLng(
      latitude: tileY2Lat(centerTileY, targetZoom),
      longitude: tileX2Lng(centerTileX, targetZoom),
    );

    // Zoom first: the manager zoom switches immediately even in the
    // animated two-phase path, so the pan tween below runs at the target
    // zoom. Then pan to the (padding-shifted) center.
    if (targetZoom != manager.zoom) {
      if (animateFit) {
        _startZoomAnimation(manager, targetZoom, null);
      } else {
        _applyZoomInstantly(manager, targetZoom, null);
      }
    }
    _moveTo(targetCenter, animate: animateFit);
  }

  // ── Zoom animation (two-phase) ─────────────────────────────────────
  //
  // Google Maps style zoom:
  //
  // Phase 1 (waiting): old tiles shown with blur while new tiles load.
  //   Old tiles stay in place (scale = 1.0) but blurred so the user
  //   sees the current view softening while new tiles fill in.
  //
  // Phase 2 (scale): once new tiles are ready (or timeout expires),
  //   old tiles scale up (zoom in: 1→2×) or down (zoom out: 1→0.5×)
  //   while fading out, revealing crisp new tiles underneath.
  //
  // Both styles show blur:
  //   - scale: light blur (sigma 2)
  //   - crossfade: heavy blur (sigma 5)

  void _startZoomAnimation(
      TileManager manager, int targetZoom, Offset? focalLocal) {
    // Cancel any in-progress animation.
    _animController.stop();
    _stopPanAnimation();
    _animWaitTimer?.cancel();
    _animWaitTimer = null;
    _animOldSnapshot = null;
    _animWaitingTiles = false;

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
    MapZoomChangeNotification(targetZoom).dispatch(context);
    _notifyCamera(manager);
    MapCameraChangeNotification(manager.centerLatLng, manager.zoom)
        .dispatch(context);

    // Re-anchor the snapshot to the POST-step camera so pans from here
    // on shift the overlay by exactly their screen-pixel delta while it
    // fades out. Manager zoom is already the NEW zoom here.
    final snap = _animOldSnapshot!;
    snap.anchorTileLng = manager.centerTileLng;
    snap.anchorTileLat = manager.centerTileLat;

    // 3. Calculate new tiles and check if all visible tiles are loaded.
    manager.calculate();

    final ready = _newTilesReady();
    if (ready) {
      // All new tiles already available (cache hit) — start scale
      // immediately.
      _beginScalePhase();
    } else {
      // Phase 1: hold old tiles with blur while new tiles load.
      _animWaitingTiles = true;
      _visualScale = 1.0;
      // Schedule a timeout so we don't wait forever on slow networks.
      _animWaitTimer?.cancel();
      _animWaitTimer = Timer(_animWaitTimeout, () {
        if (!mounted || !_animWaitingTiles) return;
        _beginScalePhase();
      });
    }
    setState(() {});
  }

  /// Returns true when all visible tiles in the new zoom have loaded
  /// (no placeholders). Called from [_notify] (tiles-changed callback)
  /// and from the timeout in [_startZoomAnimation].
  bool _newTilesReady() {
    final manager = _tileManager;
    if (manager == null) return true;
    return !manager.renderTiles.any((t) => t.sourceTile == null);
  }

  /// Transitions from phase 1 (blur + wait) to phase 2 (scale + fade).
  void _beginScalePhase() {
    if (!_animWaitingTiles && _animOldSnapshot == null) return;
    _animWaitingTiles = false;
    _animWaitTimer?.cancel();
    _animWaitTimer = null;

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

  /// Blur sigma for the current zoom animation style.
  double get _blurSigma =>
      widget.zoomAnimationStyle == ZoomAnimationStyle.crossfade ? 5.0 : 2.0;

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
    _animWaitingTiles = false;
    _visualScale = 1.0;
    setState(() {});
  }

  // ── Scale gesture handlers (pan + pinch-to-zoom) ────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    final manager = _tileManager;
    if (manager == null) return;

    // Cancel any ongoing zoom animation (wait or scale phase).
    if (_isAnimating) {
      _animController.stop();
      _animWaitTimer?.cancel();
      _animWaitTimer = null;
      _animOldSnapshot = null;
      _animWaitingTiles = false;
      _visualScale = 1.0;
    }
    _stopPanAnimation();

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
    final zoomDelta = math.log(details.scale / startScale) / math.log(2);
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
        MapZoomChangeNotification(newZoom).dispatch(context);
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
    final manager = _tileManager;
    if (manager != null) {
      MapCameraChangeNotification(manager.centerLatLng, manager.zoom)
          .dispatch(context);
    }
    _scaleStartTileLng = null;
    _scaleStartTileLat = null;
    _scaleStartZoom = null;
    _scaleStartFocal = null;
  }

  /// Cluster tap: dispatches notification, calls the optional callback,
  /// and optionally zooms in using the cluster's screen position as the
  /// focal point.
  void _onClusterTapped(MarkerCluster cluster) {
    MapMarkerClusterTapNotification(cluster).dispatch(context);
    widget.markerClusterOptions?.onTap?.call(cluster);
    if (widget.markerClusterOptions?.zoomOnTap ?? true) {
      final position = _tileManager?.latLngToScreen(cluster.point);
      if (position != null) {
        _zoomInAt(position);
      }
    }
  }

  /// Bare-map tap: closes an open marker overlay when its config allows
  /// (`MarkerOverlayConfig.closeOnMapTap`). This detector lives below the
  /// marker layer, so marker taps never reach it.
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
          // NOTE: bare-map tap is handled by the tile-layer detector below,
          // not by this root detector. Putting it here made the map's tap
          // recognizer compete in the gesture arena with marker taps, which
          // caused marker taps to be dropped/intermittent.
          onDoubleTapDown: (details) {
            _doubleTapLocal = details.localPosition;
          },
          onDoubleTap: () => _zoomInAt(_doubleTapLocal),
          child: Stack(
            children: [
              // ── Map surface: tiles + bare-map tap handler ───────────
              // Placed below markers so marker taps win unambiguously.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _onMapTap,
                  child: Stack(
                    children: [
                      // ── NEW zoom tiles (background, always at 1.0×) ─
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

                      // ── OLD zoom tiles (overlay, animated out) ─────
                      // Keyed: this child inserts/removes mid-animation,
                      // and an unkeyed insertion reshuffles — recreating
                      // the state of — every Stack child after it (marker
                      // layer included).
                      if (isAnimatingZoom) ...[
                        _OldGridOverlay(
                          manager: manager,
                          size: size,
                          scaleAlignment: scaleAlignment,
                          snapshot: _animOldSnapshot!,
                          animation: _animController,
                          waiting: _animWaitingTiles,
                          visualScale: _visualScale,
                          blurSigma: _blurSigma,
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ── Polylines (above tiles, below markers and labels) ──
              if (widget.polylines.isNotEmpty) ...[
                Positioned.fill(
                  child: PolylineLayer(
                    polylines: widget.polylines,
                    manager: manager,
                  ),
                ),
              ],

              // ── Markers (above tiles + scale overlay, below labels) ─
              if (widget.markers != null) ...[
                Positioned.fill(
                  child: MarkerLayer(
                    markers: widget.markers!,
                    manager: manager,
                    clusterOptions: widget.markerClusterOptions,
                    onMarkerTap: (marker) {
                      MapMarkerTapNotification(marker).dispatch(context);
                    },
                    onMarkerLongPress: (marker) {
                      MapMarkerLongPressNotification(marker).dispatch(context);
                    },
                    onClusterTap: (cluster) {
                      _onClusterTapped(cluster);
                    },
                    onOverlayShown: (marker) {
                      MapOverlayShownNotification(marker).dispatch(context);
                    },
                    onOverlayHidden: (marker) {
                      MapOverlayHiddenNotification(marker).dispatch(context);
                    },
                  ),
                ),
              ],

              // ── Vector labels (above markers; need viewport-level ──
              // ── collision, not per-tile rendering). Ignored for  ───
              // ── hit testing so markers stay tappable.             ───
              if (runtime != null) ...[
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
                        leftColumnTilesCanvasX: manager.leftColumnTilesCanvasX,
                        topRowTilesCanvasY: manager.topRowTilesCanvasY,
                        tiles: manager.renderTiles,
                        revision: manager.revision,
                        zoom: manager.zoom,
                        overlay: runtime.labelOverlay,
                      ),
                    ),
                  ),
                ),
              ],

              // ── Zoom controls (not affected by scale) ────────────
              if (widget.showZoomControls) ...[
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

              // ── Attribution (required by vector tile providers) ───
              if (runtime != null && runtime.loaded.attribution.isNotEmpty) ...[
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
            ],
          ),
        );
      },
    );
  }
}
