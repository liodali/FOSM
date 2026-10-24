import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/physics.dart';

import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/lat_lng_bounds.dart';
import 'package:fosm/src/api/map_controller.dart';
import 'package:fosm/src/api/map_notification.dart';
import 'package:fosm/src/api/map_polyline.dart';
import 'package:fosm/src/api/map_polygon.dart';
import 'package:fosm/src/api/marker_cluster.dart';
import 'package:fosm/src/api/marker_manager.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';
import 'package:fosm/src/api/tile_source.dart';
import 'package:fosm/src/api/map_load_state.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:fosm/src/common/tile_work_scheduler.dart';
import 'package:fosm/src/common/rendered_tile_cache.dart';
import 'package:fosm/src/common/memory_attribution.dart';
import 'package:fosm/src/vector/render/vector_tile_runtime.dart';
import 'package:fosm/src/vector/style/style_loader.dart';
import 'package:fosm/src/view/marker_layer.dart';
import 'package:fosm/src/view/polyline_layer.dart';
import 'package:fosm/src/view/polygon_layer.dart';
import 'package:fosm/src/view/shape_geometry.dart';
import 'package:fosm/src/view/shape_geometry_cache.dart';
import 'package:fosm/src/view/render.dart';
import 'package:fosm/src/view/zoom_fallback.dart';
import 'package:fosm/src/view/zoom_controls.dart';
import 'scale_bar.dart';
import 'location_control.dart';
import 'user_location_layer.dart';
import '../api/map_location_controller.dart';

typedef MapLoadingBuilder = Widget Function(
    BuildContext context, MapLoadState state);
typedef MapErrorBuilder = Widget Function(
    BuildContext context, MapLoadState state, VoidCallback retry);

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
  final VoidCallback releaseImages;
  final double cameraZoom;
  final double tileScale;

  /// Zoom and camera center of the snapshotted grid.
  final int zoom;
  final double sourceCenterTileLng;
  final double sourceCenterTileLat;
  final double sourceCenterCanvasX;
  final double sourceCenterCanvasY;

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
    required this.releaseImages,
    required this.cameraZoom,
    required this.tileScale,
    required this.zoom,
    required this.sourceCenterTileLng,
    required this.sourceCenterTileLat,
    required this.sourceCenterCanvasX,
    required this.sourceCenterCanvasY,
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
        releaseImages: m.retainSnapshot(m.renderTiles),
        cameraZoom: m.cameraZoom,
        tileScale: m.zoomScale,
        zoom: m.zoom,
        sourceCenterTileLng: m.centerTileLng,
        sourceCenterTileLat: m.centerTileLat,
        sourceCenterCanvasX: m.centerCanvasX,
        sourceCenterCanvasY: m.centerCanvasY,
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

  /// Whether this is the one gesture-driven snapshot. Its transform is
  /// derived from the complete camera delta rather than one zoom step.
  final bool interactionSnapshot;

  /// Whether the full-viewport blur is allowed. Skipped on web by default
  /// and during direct manipulation, where opacity + transform are cheaper
  /// and keep input responsive.
  final bool blurEnabled;

  const _OldGridOverlay({
    required this.manager,
    required this.size,
    required this.scaleAlignment,
    required this.snapshot,
    required this.animation,
    required this.waiting,
    required this.visualScale,
    required this.blurSigma,
    required this.interactionSnapshot,
    required this.blurEnabled,
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
        tileScale: snapshot.tileScale,
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
    // Disabled on web and during direct manipulation.
    final sigma = !blurEnabled
        ? 0.0
        : (waiting ? blurSigma : blurSigma * (1.0 + (visualScale - 1.0).abs()));
    if (sigma > 0.1) {
      grid = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: grid,
      );
    }

    // Keep the fading overlay glued to the camera. During a pinch the exact
    // transform is derived from the snapshot's original camera and current
    // camera, so any number of zoom levels and focal-point changes compose
    // into one affine transform.
    final Offset panShift;
    if (interactionSnapshot) {
      final currentScale = math.pow(2, manager.zoom - snapshot.zoom).toDouble();
      final currentCenterAtSourceZoom = Offset(
        manager.centerTileLng / currentScale,
        manager.centerTileLat / currentScale,
      );
      final focal = Offset(
        (scaleAlignment.x + 1) * size.width / 2,
        (scaleAlignment.y + 1) * size.height / 2,
      );
      panShift = Offset(
        manager.centerCanvasX -
            focal.dx -
            (snapshot.sourceCenterCanvasX - focal.dx) * currentScale +
            (snapshot.sourceCenterTileLng - currentCenterAtSourceZoom.dx) *
                tileWidth *
                currentScale,
        manager.centerCanvasY -
            focal.dy -
            (snapshot.sourceCenterCanvasY - focal.dy) * currentScale +
            (snapshot.sourceCenterTileLat - currentCenterAtSourceZoom.dy) *
                tileHeight *
                currentScale,
      );
    } else {
      panShift = Offset(
        -(manager.centerTileLng - snapshot.anchorTileLng) * tileWidth,
        -(manager.centerTileLat - snapshot.anchorTileLat) * tileHeight,
      );
    }

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
///   step on every update. A single-pointer release coasts with friction
///   when [enableFling] is enabled. Touching the map stops the motion.
/// - **Pinch to zoom**: with [enableFractionalZoom], display zoom follows
///   the fingers continuously. Otherwise, zoom changes in integer steps
///   as the accumulated scale crosses each rounding
///   boundary. The geographic point under the current focal point stays
///   stationary, and each step plays a zoom animation when
///   [animateZoom] is enabled.
/// - **Double-tap**: zoom in one level with a smooth zoom animation.
/// - **Mouse wheel**: zoom around the cursor when [enableScrollZoom] is enabled.
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
  /// Counts [MapView] rebuilds. Test hook used to prove that several tile
  /// arrivals in one frame produce a single map update.
  @visibleForTesting
  static int debugBuildCount = 0;

  /// Counts zoom-transition starts. Test hook used to prove a multi-level
  /// pinch creates one transition rather than one per crossed integer zoom.
  @visibleForTesting
  static int debugZoomTransitionCount = 0;

  final LatLng latLng;
  final int zoom;

  /// Enables continuous pinch, wheel and animated button/controller zoom.
  /// False by default preserves integer gesture behavior for existing hosts.
  final bool enableFractionalZoom;

  /// Optional controlled display zoom. Supplying it also enables continuous
  /// gestures; [zoom] remains the integer-compatible initial/fallback value.
  final double? fractionalZoom;
  final ValueChanged<double>? onFractionalZoomChanged;

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

  /// Host-owned location source and follow intent. MapView never disposes it.
  final MapLocationController? locationController;
  final bool showUserLocation;
  final bool showLocationControl;
  final Alignment locationControlAlignment;
  final ValueChanged<MapLocationFollowState>? onLocationFollowChanged;

  /// Retargets from the current camera on new fixes. Zero applies instantly.
  final Duration locationFollowAnimationDuration;

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

  /// Filled areas, below routes/markers. List order determines paint order.
  final List<MapPolygon> polygons;

  /// Coordinates of presses that miss interactive markers/routes/polygons.
  final ValueChanged<LatLng>? onTap;
  final ValueChanged<LatLng>? onLongPress;

  /// Global feature callbacks enable selection for every feature of that type.
  final ValueChanged<MapPolylineHit>? onPolylineTap;
  final ValueChanged<MapPolylineHit>? onPolylineLongPress;
  final ValueChanged<MapPolygonHit>? onPolygonTap;
  final ValueChanged<MapPolygonHit>? onPolygonLongPress;

  /// Renders a hosted vector style instead of raster tiles (e.g.
  /// [openFreeMapLiberty]). When set, [tileFetcher] is ignored — the
  /// style document defines all tile sources. Raster mode remains the
  /// default when this is null.
  final VectorMapStyle? vectorStyle;

  final bool showZoomControls;

  /// Show an approximate distance ruler at the camera center's latitude.
  /// Off by default to preserve existing overlay layouts.
  final bool showScaleBar;
  final ScaleBarUnit scaleBarUnit;
  final Alignment scaleBarAlignment;

  /// Maximum ruler length in logical pixels, excluding background padding.
  final double scaleBarMaxWidth;
  final ValueChanged<int>? onZoomChanged;

  /// Called after the user pans or zooms the map. Lets the host track the
  /// camera (e.g. to restore it after switching tile sources). Not called
  /// for programmatic [latLng]/[zoom] widget changes.
  final void Function(LatLng center, int zoom)? onCameraChanged;

  final Alignment zoomControlsAlignment;

  /// Continue a single-pointer pan with decaying momentum after release.
  /// New touches and camera commands stop the motion immediately.
  final bool enableFling;

  /// Zoom around the cursor on vertical wheel input (100 pixels per level).
  /// Disable when the host should handle scrolling over the map.
  final bool enableScrollZoom;

  final bool animateZoom;
  final Duration zoomAnimationDuration;

  /// Which animation the old tile grid plays during zoom transitions
  /// (double-tap, ± buttons, pinch zoom steps) when [animateZoom] is
  /// enabled. Defaults to [ZoomAnimationStyle.scale].
  final ZoomAnimationStyle zoomAnimationStyle;

  /// Budget for estimated RGBA rendered-tile memory. The current grid and
  /// active zoom snapshot are protected and may temporarily exceed it.
  /// Unused images are evicted first. Zero retains only protected images.
  final int maxRenderedCacheBytes;

  /// How long unused rendered tiles remain available for return pans/zooms,
  /// subject to [maxRenderedCacheBytes]. Defaults to 20 seconds.
  final Duration renderedCacheRetention;

  /// Deadline for each HTTP request, including headers and the full body.
  /// Custom fetchers are bounded too; their underlying work cannot be cancelled.
  final Duration requestTimeout;

  /// Optional viewport loading overlay. It ignores pointers so map gestures
  /// and markers remain usable. Raster tiles otherwise retain checkerboards.
  final MapLoadingBuilder? loadingBuilder;

  /// Optional error overlay for style failures or failed visible tiles.
  /// The retry callback reloads a style or retries missing viewport tiles.
  final MapErrorBuilder? errorBuilder;
  final ValueChanged<MapTileFailure>? onTileError;

  const MapView({
    super.key,
    required this.latLng,
    required this.zoom,
    this.enableFractionalZoom = false,
    this.fractionalZoom,
    this.onFractionalZoomChanged,
    this.minZoom = 1,
    this.maxZoom = 19,
    this.cameraBounds,
    this.tileFetcher,
    this.controller,
    this.locationController,
    this.showUserLocation = true,
    this.showLocationControl = true,
    this.locationControlAlignment = Alignment.bottomRight,
    this.onLocationFollowChanged,
    this.locationFollowAnimationDuration = const Duration(milliseconds: 300),
    this.markers,
    this.markerClusterOptions,
    this.polylines = const [],
    this.polygons = const [],
    this.onTap,
    this.onLongPress,
    this.onPolylineTap,
    this.onPolylineLongPress,
    this.onPolygonTap,
    this.onPolygonLongPress,
    this.vectorStyle,
    this.showZoomControls = true,
    this.showScaleBar = false,
    this.scaleBarUnit = ScaleBarUnit.metric,
    this.scaleBarAlignment = Alignment.bottomLeft,
    this.scaleBarMaxWidth = 120,
    this.onZoomChanged,
    this.onCameraChanged,
    this.zoomControlsAlignment = Alignment.bottomRight,
    this.enableFling = true,
    this.enableScrollZoom = true,
    this.animateZoom = true,
    this.zoomAnimationDuration = const Duration(milliseconds: 350),
    this.zoomAnimationStyle = ZoomAnimationStyle.scale,
    this.maxRenderedCacheBytes = RenderedTileCache.defaultMaxBytes,
    this.renderedCacheRetention = RenderedTileCache.defaultRetention,
    this.requestTimeout = TileLoadException.defaultRequestTimeout,
    this.loadingBuilder,
    this.errorBuilder,
    this.onTileError,
  })  : assert(maxRenderedCacheBytes >= 0),
        assert(scaleBarMaxWidth > 0 && scaleBarMaxWidth < double.infinity),
        assert(fractionalZoom == null ||
            (fractionalZoom >= 0 && fractionalZoom <= 30)),
        assert(!(enableFractionalZoom || fractionalZoom != null) ||
            (minZoom >= 0 && maxZoom <= 30));

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView>
    with TickerProviderStateMixin, WidgetsBindingObserver
    implements
        MapControllerDelegate,
        FractionalMapControllerDelegate,
        LocationMapControllerDelegate,
        MapMemoryDelegate {
  @override
  MapLocationController? get locationController => widget.locationController;

  bool _followQueued = false;
  bool _locationOwnsPan = false;
  int? _lastFollowRevision;
  MapLocationFollowState? _lastFollowState;

  void _bindLocationController(MapLocationController? previous) {
    previous?.removeListener(_onLocationChanged);
    if (_locationOwnsPan) _stopPanAnimation();
    _lastFollowRevision = null;
    _lastFollowState = widget.locationController?.state;
    widget.locationController?.addListener(_onLocationChanged);
    _scheduleLocationFollow();
  }

  void _onLocationChanged() {
    if (!mounted) return;
    final locations = widget.locationController;
    if (_locationOwnsPan &&
        (locations == null ||
            !locations.isFollowing ||
            locations.location == null ||
            locations.error != null)) {
      _stopPanAnimation();
    }
    final state = locations?.state;
    if (state != null && state != _lastFollowState) {
      _lastFollowState = state;
      widget.onLocationFollowChanged?.call(state);
      MapLocationFollowChangeNotification(state).dispatch(context);
    }
    setState(() {});
    _scheduleLocationFollow();
  }

  void _scheduleLocationFollow({bool force = false}) {
    if (force) _lastFollowRevision = null;
    final locations = widget.locationController;
    if (!mounted ||
        locations == null ||
        !locations.isFollowing ||
        locations.location == null ||
        locations.error != null ||
        _lastFollowRevision == locations.followRevision ||
        _followQueued) {
      return;
    }
    _followQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followQueued = false;
      if (!mounted) return;
      final current = widget.locationController;
      if (current == null ||
          !current.isFollowing ||
          current.location == null ||
          current.error != null ||
          _tileManager == null ||
          _interacting ||
          _pointers.isNotEmpty ||
          _isAnimating ||
          (_fractionalController?.isAnimating ?? false) ||
          _lastFollowRevision == current.followRevision) {
        return;
      }
      _lastFollowRevision = current.followRevision;
      _moveTo(current.location!.point,
          animate: widget.locationFollowAnimationDuration > Duration.zero &&
              !MediaQuery.disableAnimationsOf(context),
          duration: widget.locationFollowAnimationDuration,
          curve: Curves.easeOut,
          preserveLocationFollow: true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _pauseLocationFollowing() => widget.locationController?.pause();

  final TileWorkScheduler _tileWorkScheduler = TileWorkScheduler();

  /// Cancels the opt-in periodic memory-attribution logger
  /// (`--dart-define=fosm.traceMemory=true`), null when disabled.
  VoidCallback? _memoryTraceCancel;
  TileManager? _tileManager;

  /// Cached world projections for route/area geometry, shared by the
  /// polyline/polygon layers and tap hit testing. Keyed by points-list
  /// identity, so replacing a route's points invalidates automatically and
  /// the retention budget bounds live-updating routes.
  final ShapeGeometryCache _shapeGeometryCache = ShapeGeometryCache();

  int _currentZoom = 0;
  bool _explicitFractional = false;
  bool get _usesFractionalZoom =>
      _explicitFractional ||
      widget.enableFractionalZoom ||
      widget.fractionalZoom != null;
  AnimationController? _fractionalController;
  ZoomFallbackCoverage? _zoomFallback;
  Timer? _zoomFallbackTimer;
  double? _scaleStartCameraZoom;
  Offset? _lastFractionalFocal;

  @override
  double get fractionalZoom =>
      _tileManager?.cameraZoom ??
      widget.fractionalZoom ??
      widget.zoom.toDouble();

  @override
  void setFractionalZoom(double zoom, {bool animate = true}) {
    _explicitFractional = true;
    _setContinuousZoom(zoom, animate: animate);
  }

  // ── Vector style session ────────────────────────────────────────────
  VectorTileRuntime? _vectorRuntime;
  TileLoadException? _vectorError;
  int _styleLoadGeneration = 0;
  MapRequestSession? _styleCancel;

  // ── Zoom animation ──────────────────────────────────────────────────
  late AnimationController _animController;
  Animation<double>? _scaleAnimation;

  /// Visual scale applied to the OLD grid overlay during animation:
  /// 1.0 → 2^(target zoom - snapshot zoom).
  double _visualScale = 1.0;

  /// Focal point for the scale transform (in local widget coords).
  Offset _visualScaleFocal = Offset.zero;

  /// Snapshot of the OLD grid (before zoom change) rendered as an overlay
  /// during the scale transition.
  _GridSnapshot? _animOldSnapshot;

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
  bool _flinging = false;
  final Set<int> _pointers = {};
  bool _gestureHadMultiplePointers = false;
  bool _gestureCancelled = false;
  double _scrollPixels = 0;
  Duration? _lastScrollTime;

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
  // Pan anchors are re-baselined after zoom steps because tile units change.
  // The zoom baseline stays fixed for the entire gesture so 2x scale is one
  // level regardless of how many intermediate updates were delivered.
  double? _scaleStartTileLng;
  double? _scaleStartTileLat;

  /// Zoom baseline for gesture quantization, as a continuous value: the
  /// rebased baseline keeps its fractional offset (at scale √2 a command
  /// zoom of 8 rebases to 7.5, so repeating the unchanged scale lands on
  /// 8 exactly) and only the resulting zoom is quantized.
  double? _scaleStartZoom;
  Offset? _scaleStartFocal;

  /// Last zoom direction, used to damp reversals around a rounding boundary.
  int _pinchZoomDirection = 0;

  /// Coalesced scale updates: pointer events can arrive faster than the
  /// display renders (multi-pointer storms, high-rate touch digitisers).
  /// The first update of a frame applies immediately; later ones only
  /// overwrite this slot and are applied once at the next frame boundary,
  /// using the latest focal point and the recognizer's cumulative scale.
  ScaleUpdateDetails? _pendingScaleUpdate;
  bool _scaleFlushScheduled = false;
  bool _scaleAppliedSinceFrame = false;

  /// Focal point and cumulative scale of the last gesture update that was
  /// actually applied. Camera commands rebase the active gesture onto the
  /// new camera using the freshest of this and [_pendingScaleUpdate].
  Offset? _lastAppliedGestureFocal;
  double? _lastAppliedGestureScale;

  /// Set by camera commands: the active gesture's anchors must refresh
  /// from the live camera before the gesture applies again.
  bool _gestureNeedsRebase = false;

  /// True from gesture start to gesture end. Full-viewport blur is skipped
  /// during direct manipulation so a pinch/drag never pays for an
  /// `ImageFiltered` pass while the camera is moving.
  bool _interacting = false;

  /// Whether the current pinch already started its one zoom transition.
  /// Only the first crossed integer zoom builds a snapshot/wait/scale state;
  /// later steps move the camera and re-anchor that same snapshot instead of
  /// recreating the transition on every level.
  bool _pinchTransitionActive = false;

  // ── Double-tap focal point ──────────────────────────────────────────
  Offset _doubleTapLocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    validateRequestTimeout(widget.requestTimeout);
    if (widget.locationFollowAnimationDuration.isNegative) {
      throw ArgumentError.value(widget.locationFollowAnimationDuration,
          'locationFollowAnimationDuration', 'must not be negative');
    }
    _currentZoom = (widget.fractionalZoom ?? widget.zoom).round();
    if (widget.vectorStyle != null) {
      _loadVectorStyle();
    }

    _animController = AnimationController(
      duration: widget.zoomAnimationDuration,
      vsync: this,
    );
    _animController.addListener(_onAnimTick);
    _animController.addStatusListener(_onAnimStatus);

    // Memory-pressure notifications (iOS/Android memory warnings) drive
    // deliberate cache trimming; see [didHaveMemoryPressure].
    WidgetsBinding.instance.addObserver(this);
    _memoryTraceCancel = MemoryTrace.start(() => memoryAttribution);

    _bindLocationController(null);
    widget.controller?.attach(this);
  }

  Future<void> _loadVectorStyle() async {
    final style = widget.vectorStyle;
    if (style == null) return;
    final generation = ++_styleLoadGeneration;
    _styleCancel?.cancel('Style load replaced');
    final cancel = MapRequestSession();
    _styleCancel = cancel;
    setState(() => _vectorError = null);
    try {
      final loaded = await loadVectorStyle(style,
          requestTimeout: widget.requestTimeout, requestSession: cancel);
      if (!mounted ||
          widget.vectorStyle != style ||
          generation != _styleLoadGeneration) {
        return;
      }
      _vectorRuntime = VectorTileRuntime(
        loaded: loaded,
        namespace: style.id,
        workScheduler: _tileWorkScheduler,
        requestTimeout: widget.requestTimeout,
      );
    } catch (error) {
      if (!mounted ||
          widget.vectorStyle != style ||
          generation != _styleLoadGeneration) {
        return;
      }
      _vectorError =
          TileLoadException.from(error, fallback: TileFailureKind.style);
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    validateRequestTimeout(widget.requestTimeout);
    if (widget.locationFollowAnimationDuration.isNegative) {
      throw ArgumentError.value(widget.locationFollowAnimationDuration,
          'locationFollowAnimationDuration', 'must not be negative');
    }
    if (widget.locationController != oldWidget.locationController) {
      _bindLocationController(oldWidget.locationController);
    }
    if (widget.locationFollowAnimationDuration !=
        oldWidget.locationFollowAnimationDuration) {
      _scheduleLocationFollow(force: true);
    }
    _tileManager?.requestTimeout = widget.requestTimeout;
    _vectorRuntime?.requestTimeout = widget.requestTimeout;
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?.detach(this);
      widget.controller?.attach(this);
    }
    if (widget.zoomAnimationDuration != oldWidget.zoomAnimationDuration) {
      _animController.duration = widget.zoomAnimationDuration;
    }
    if (widget.vectorStyle != oldWidget.vectorStyle) {
      _styleCancel?.cancel('Style changed');
      _stopFractionalAnimation();
      _clearZoomFallback();
      // Style switch: tear everything down and reload.
      _animController.stop();
      _stopPanAnimation();
      _animWaitTimer?.cancel();
      _animWaitTimer = null;
      _clearZoomSnapshot();
      _animWaitingTiles = false;
      _pinchTransitionActive = false;
      _visualScale = 1.0;
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
    if (widget.maxRenderedCacheBytes != oldWidget.maxRenderedCacheBytes ||
        widget.renderedCacheRetention != oldWidget.renderedCacheRetention) {
      _tileManager?.updateRenderedCachePolicy(
        maxBytes: widget.maxRenderedCacheBytes,
        retention: widget.renderedCacheRetention,
      );
    }
    // Hosts often echo onCameraChanged back into latLng/zoom. Those rebuilds
    // acknowledge our current camera rather than interrupting its motion.
    final externalCenter = widget.latLng != oldWidget.latLng &&
        widget.latLng != _tileManager?.centerLatLng;
    final externalFractional =
        widget.fractionalZoom != oldWidget.fractionalZoom &&
            widget.fractionalZoom != _tileManager?.cameraZoom;
    final externalZoom =
        widget.zoom != oldWidget.zoom && widget.zoom != _currentZoom;
    if ((!widget.enableFling && _flinging) ||
        widget.cameraBounds != oldWidget.cameraBounds ||
        externalCenter ||
        externalZoom ||
        externalFractional ||
        widget.minZoom != oldWidget.minZoom ||
        widget.maxZoom != oldWidget.maxZoom) {
      _stopPanAnimation();
      _stopFractionalAnimation();
      _clearZoomFallback();
    }
    if (_usesFractionalZoom &&
        _tileManager != null &&
        (widget.minZoom != oldWidget.minZoom ||
            widget.maxZoom != oldWidget.maxZoom)) {
      final manager = _tileManager!;
      manager.setCameraZoom(manager.cameraZoom
          .clamp(widget.minZoom.toDouble(), widget.maxZoom.toDouble()));
      _currentZoom = manager.zoom;
    }
    if (!widget.enableScrollZoom) _scrollPixels = 0;
    if (widget.cameraBounds != oldWidget.cameraBounds) {
      _tileManager?.setCameraBounds(widget.cameraBounds);
      setState(() {});
    }
    if (externalCenter) {
      _rebaseGestureOntoCamera();
      _tileManager?.setCenterTile(latLng: widget.latLng);
      _tileManager?.calculate();
      setState(() {});
      // External center echo is a programmatic pan: cover the newly
      // revealed cells with the same bounded settle as controller pans.
      _settleZoomFallback();
    }
    if (externalFractional && widget.fractionalZoom != null) {
      _rebaseGestureOntoCamera();
      _tileManager?.setCameraZoom(widget.fractionalZoom!
          .clamp(widget.minZoom.toDouble(), widget.maxZoom.toDouble()));
      _currentZoom = _tileManager?.zoom ?? _currentZoom;
      _settleZoomFallback();
    } else if (externalZoom) {
      _rebaseGestureOntoCamera();
      if (_usesFractionalZoom) {
        _tileManager?.setCameraZoom(widget.zoom.toDouble());
      } else {
        _tileManager?.setZoom(widget.zoom);
      }
      _currentZoom = widget.zoom;
      setState(() {});
      _settleZoomFallback();
    }
    if (externalCenter ||
        externalZoom ||
        externalFractional ||
        widget.cameraBounds != oldWidget.cameraBounds) {
      _scheduleLocationFollow(force: true);
    }
    if ((oldWidget.enableFractionalZoom || oldWidget.fractionalZoom != null) &&
        !widget.enableFractionalZoom &&
        widget.fractionalZoom == null) {
      _explicitFractional = false;
      _stopFractionalAnimation();
      _clearZoomFallback();
      _tileManager?.setZoom(_tileManager!.zoom);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _memoryTraceCancel?.call();
    _memoryTraceCancel = null;
    widget.locationController?.removeListener(_onLocationChanged);
    _tileWorkScheduler.dispose();
    _stopFractionalAnimation();
    _cancelZoomFallbackTimer();
    _zoomFallback?.dispose();
    _zoomFallback = null;
    _styleCancel?.cancel('Map disposed');
    widget.controller?.detach(this);
    _animController.removeListener(_onAnimTick);
    _animController.removeStatusListener(_onAnimStatus);
    _animController.dispose();
    _stopPanAnimation();
    _animWaitTimer?.cancel();
    _clearZoomSnapshot();
    _tileManager?.dispose();
    _vectorRuntime?.dispose();
    super.dispose();
  }

  /// Deliberate memory-pressure response: drop every rebuildable cache
  /// while the visible grid, pinned fallback imagery and camera state
  /// survive. The rendered-image cache keeps active/pinned images; the
  /// byte cache, unused rendered images, parsed vector tiles, raster
  /// source images, prepared labels and geometry rings are released and
  /// repopulate on demand as the camera keeps working.
  @override
  void didHaveMemoryPressure() {
    if (!mounted) return;
    _tileManager?.handleMemoryPressure();
    _vectorRuntime?.handleMemoryPressure();
    _shapeGeometryCache.clear();
  }

  /// Point-in-time attribution of this map's retained memory. Exposed
  /// through [MapController.memoryAttribution] for workload captures.
  @override
  FosmMemoryAttribution get memoryAttribution => FosmMemoryAttribution(
        renderedImages: _tileManager?.renderedCacheStats ??
            const RenderedTileCacheStats.empty(),
        compressedBytes: _tileManager?.byteCacheBytes ?? 0,
        compressedEntries: _tileManager?.byteCacheEntries ?? 0,
        geometryRings: _shapeGeometryCache.ringCount,
        geometryVertexUnits: _shapeGeometryCache.cachedVertexUnits,
        inFlightLoads: _tileManager?.inFlightLoadCount ?? 0,
        queuedLoads: _tileManager?.queuedLoadCount ?? 0,
        pendingPresentations: _tileManager?.pendingPresentationCount ?? 0,
        pendingFetches: _tileManager?.pendingFetchCount ?? 0,
        parsedTiles: _vectorRuntime?.parsedTileCount,
        parsedTileEstimatedBytes: _vectorRuntime?.parsedTileEstimatedBytes,
        rasterTiles: _vectorRuntime?.rasterTileCount,
        rasterTileBytes: _vectorRuntime?.rasterTileBytes,
        preparedLabelTiles: _vectorRuntime?.labelOverlayPreparedTiles,
        preparedLabels: _vectorRuntime?.labelOverlayPreparedLabels,
      );

  void _notify() {
    // Per-region fallback retirement happens at the reconcile in build;
    // here only the wait phase needs to react before setState so it does
    // not spend a frame on the stale overlay.
    if (_animWaitingTiles && !_interacting && _newTilesReady()) {
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
      cameraZoom: widget.fractionalZoom
          ?.clamp(widget.minZoom.toDouble(), widget.maxZoom.toDouble()),
      fetcher: runtime?.fetcher ?? widget.tileFetcher,
      decoder: runtime?.decoder,
      workScheduler: _tileWorkScheduler,
      urlBuilder: runtime?.urlBuilder,
      resourceKeyBuilder: runtime?.resourceKeyBuilder,
      cacheNamespace: runtime?.namespace ?? '',
      // Vector decodes are expensive (MVT parse + style passes + toImage),
      // so the off-screen padding ring is fetched as bytes only and decoded
      // on demand when it scrolls into view. Raster decodes are cheap and
      // keep decoding the padding ring for instant panning.
      byteOnlyPadding: runtime != null,
      // The vector runtime already routes its `Picture.toImage` through
      // the shared scheduler; the manager must not wrap the same decoder
      // in another image-lane reservation. This is scheduling ownership,
      // independent of the padding policy above.
      decoderOwnsImageScheduling: runtime != null,
      cameraBounds: widget.cameraBounds,
      maxRenderedCacheBytes: widget.maxRenderedCacheBytes,
      renderedCacheRetention: widget.renderedCacheRetention,
      requestTimeout: widget.requestTimeout,
    );
    manager.onTilesChanged = _notify;
    manager.onTileError = (error) => widget.onTileError?.call(error);
    // Let the vector runtime abort decodes for tiles that leave the
    // render set before they reach render/`toImage`, and dispatch the
    // newest centre tile first from its presentation lane.
    runtime?.isTileRelevant = manager.isTileRelevant;
    runtime?.tilePriority = manager.tileDecodePriority;
    _tileManager = manager;
    _currentZoom = manager.zoom;
    _scheduleLocationFollow(force: true);

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

  double? _fractionalTarget;

  void _stopFractionalAnimation() {
    final controller = _fractionalController;
    _fractionalController = null;
    _fractionalTarget = null;
    controller?.dispose();
  }

  void _clearZoomFallback() {
    _cancelZoomFallbackTimer();
    _zoomFallback?.clear();
  }

  void _cancelZoomFallbackTimer() {
    _zoomFallbackTimer?.cancel();
    _zoomFallbackTimer = null;
  }

  /// Whether any animated camera motion currently owns the camera: an
  /// animated pan/fling (or location-follow retarget), the fractional
  /// zoom animation, or the two-phase integer zoom transition. A zoom
  /// fallback settle timer armed before the motion must neither fire
  /// mid-motion nor be re-armed by it — every motion's completion path
  /// performs its own settle.
  bool get _cameraMotionActive =>
      _panController != null ||
      (_fractionalController?.isAnimating ?? false) ||
      _isAnimating;

  void _settleZoomFallback() {
    final coverage = _zoomFallback;
    if (coverage == null) return;
    // Regions must reflect the live grid even before a build ran, so the
    // settle decision (and any timeout) sees the current coverage.
    coverage.reconcile();
    if (!coverage.hasRegions) return;
    if (_interacting || _cameraMotionActive) {
      return;
    }
    if (_newTilesReady()) {
      _clearZoomFallback();
      if (mounted) setState(() {});
      return;
    }
    _cancelZoomFallbackTimer();
    _zoomFallbackTimer = Timer(_animWaitTimeout, () {
      // Gesture input or a camera motion that started after this timer
      // was armed owns the camera now: its end path re-settles.
      if (!mounted || _interacting || _cameraMotionActive) return;
      final current = _zoomFallback;
      if (current == null || !current.hasRegions) return;
      // Drop remaining regions (still-missing cells fall back to
      // checkerboards) and keep the fallback suspended until the grid
      // membership changes again.
      current.suspend();
      setState(() {});
    });
  }

  void _applyContinuousZoom(TileManager manager, double value, Offset focal,
      {bool notify = true}) {
    if (value == manager.cameraZoom) return;
    final oldZoom = manager.zoom;
    // No snapshot capture here: the per-region zoom fallback derives its
    // coverage from the rendered cache at the next build, so a zoom step
    // (or a plain pan revealing unloaded cells) is covered geographically
    // without pinning one whole-grid snapshot. The transition pin keeps
    // the old imagery alive across the grid switch itself.
    _zoomFallback?.beginZoomTransition();
    manager.setCameraZoom(value, focalPoint: focal);
    _currentZoom = manager.zoom;
    if (oldZoom != manager.zoom) {
      widget.onZoomChanged?.call(manager.zoom);
      MapZoomChangeNotification(manager.zoom).dispatch(context);
    }
    widget.onFractionalZoomChanged?.call(value);
    if (notify) {
      _notifyCamera(manager);
      MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
              fractionalZoom: manager.cameraZoom)
          .dispatch(context);
      setState(() {});
    }
  }

  void _setContinuousZoom(double value,
      {Offset? focal, LatLng? centerTarget, required bool animate}) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'zoom', 'must be finite');
    }
    final manager = _tileManager;
    if (manager == null) return;
    _rebaseGestureOntoCamera();
    final target = value.clamp(math.max(0, widget.minZoom).toDouble(),
        math.min(30, widget.maxZoom).toDouble());
    _stopPanAnimation();
    _stopFractionalAnimation();
    _animController.stop();
    _animWaitTimer?.cancel();
    _clearZoomSnapshot();
    _animWaitingTiles = false;
    _pinchTransitionActive = false;
    _cancelZoomFallbackTimer();
    final origin =
        focal ?? Offset(manager.centerCanvasX, manager.centerCanvasY);
    if (!animate ||
        widget.zoomAnimationDuration == Duration.zero ||
        (target == manager.cameraZoom && centerTarget == null)) {
      _applyContinuousZoom(manager, target, origin,
          notify: centerTarget == null);
      if (centerTarget != null) {
        manager.setCenterTile(latLng: centerTarget);
        _notifyCamera(manager);
        MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
                fractionalZoom: manager.cameraZoom)
            .dispatch(context);
        setState(() {});
      }
      _settleZoomFallback();
      _scheduleLocationFollow(force: true);
      return;
    }
    final start = manager.cameraZoom;
    final centerStart = Offset(lon2TileX(manager.centerLatLng.longitude, 0),
        lat2TileY(manager.centerLatLng.latitude, 0));
    final centerEnd = centerTarget == null
        ? null
        : Offset(lon2TileX(centerTarget.longitude, 0),
            lat2TileY(centerTarget.latitude, 0));
    final controller = AnimationController(
        vsync: this, duration: widget.zoomAnimationDuration);
    _fractionalController = controller;
    _fractionalTarget = target;
    controller.addListener(() {
      if (!mounted) return;
      final value = start +
          (target - start) * Curves.easeInOut.transform(controller.value);
      _applyContinuousZoom(manager, value, origin,
          notify: centerTarget == null);
      if (centerEnd != null) {
        final t = Curves.easeInOut.transform(controller.value);
        final center = Offset.lerp(centerStart, centerEnd, t)!;
        final factor = math.pow(2, manager.zoom).toDouble();
        manager.setCenterFromTileCoords(center.dx * factor, center.dy * factor);
        _notifyCamera(manager);
        MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
                fractionalZoom: manager.cameraZoom)
            .dispatch(context);
        setState(() {});
      }
    });
    _completeContinuousZoom(controller, controller.forward());
  }

  Future<void> _completeContinuousZoom(
      AnimationController controller, TickerFuture motion) async {
    try {
      await motion.orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || _fractionalController != controller) return;
    _stopFractionalAnimation();
    _settleZoomFallback();
    _scheduleLocationFollow(force: true);
  }

  // ── Zoom trigger methods ────────────────────────────────────────────

  void _zoomIn() => _zoomBy(1, focalLocal: null);
  void _zoomOut() => _zoomBy(-1, focalLocal: null);
  void _zoomInAt(Offset localPosition) {
    _pauseLocationFollowing();
    _zoomBy(1, focalLocal: localPosition);
  }

  void _zoomBy(int delta, {Offset? focalLocal, bool? animate}) {
    if (_usesFractionalZoom) {
      _setContinuousZoom(fractionalZoom + delta,
          focal: focalLocal, animate: animate ?? widget.animateZoom);
      return;
    }
    final manager = _tileManager;
    if (manager == null) return;
    _stopPanAnimation();
    final newZoom =
        (manager.zoom + delta).clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == manager.zoom) {
      _scheduleLocationFollow(force: true);
      return;
    }

    if (!(animate ?? widget.animateZoom)) {
      _applyZoomInstantly(manager, newZoom, focalLocal);
      return;
    }

    _startZoomAnimation(manager, newZoom, focalLocal);
  }

  void _setZoom(int zoom, {bool? animate}) {
    if (_usesFractionalZoom) {
      _setContinuousZoom(zoom.toDouble(),
          animate: animate ?? widget.animateZoom);
      return;
    }
    final manager = _tileManager;
    if (manager == null) return;
    _stopPanAnimation();
    final newZoom = zoom.clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == manager.zoom) {
      _scheduleLocationFollow(force: true);
      return;
    }

    if (!(animate ?? widget.animateZoom)) {
      _applyZoomInstantly(manager, newZoom, null);
      return;
    }

    _startZoomAnimation(manager, newZoom, null);
  }

  void _applyZoomInstantly(
      TileManager manager, int newZoom, Offset? focalLocal) {
    _rebaseGestureOntoCamera();
    _animController.stop();
    _animWaitTimer?.cancel();
    _animWaitTimer = null;
    _clearZoomSnapshot();
    _animWaitingTiles = false;
    _pinchTransitionActive = false;
    _visualScale = 1.0;
    final oldZoom = manager.zoom;
    final focal =
        focalLocal ?? Offset(manager.centerCanvasX, manager.centerCanvasY);
    // Instant integer steps have no animated overlay, so the per-region
    // fallback is the only continuity — pin across the switch.
    _zoomFallback?.beginZoomTransition();
    manager.setZoomWithFocalPoint(newZoom, focal, oldZoom);
    _currentZoom = newZoom;
    widget.onZoomChanged?.call(newZoom);
    MapZoomChangeNotification(newZoom).dispatch(context);
    _notifyCamera(manager);
    MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
            fractionalZoom: manager.cameraZoom)
        .dispatch(context);
    setState(() {});
    _settleZoomFallback();
    _scheduleLocationFollow(force: true);
  }

  void _moveTo(LatLng latLng,
      {bool? animate,
      Duration? duration,
      Curve curve = Curves.easeInOut,
      bool preserveLocationFollow = false}) {
    if (!preserveLocationFollow) _pauseLocationFollowing();
    final manager = _tileManager;
    if (manager == null) return;
    _rebaseGestureOntoCamera();

    _stopPanAnimation();
    _stopFractionalAnimation();
    // A settle timer from an earlier zoom/pan must not suspend coverage
    // while this pan owns the camera; the completion path re-settles.
    _cancelZoomFallbackTimer();
    final target = LatLng(
      latitude: clampLatitude(latLng.latitude),
      longitude: clampLongitude(latLng.longitude),
    );

    if (!(animate ?? widget.animateZoom) || duration == Duration.zero) {
      // setCenterTile does not reconcile the grid (unlike the zoom
      // setters); calculate explicitly so the settle below covers the
      // post-move window, not the pre-move one.
      manager.setCenterTile(latLng: target);
      manager.calculate();
      _notifyCamera(manager);
      MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
              fractionalZoom: manager.cameraZoom)
          .dispatch(context);
      if (mounted) setState(() {});
      // Settle after the move: reconciling before it would cover the old
      // window only, leaving newly revealed regions without a timeout.
      _settleZoomFallback();
      return;
    }

    final startLng = manager.centerTileLng;
    final startLat = manager.centerTileLat;
    final endLng = lon2TileX(target.longitude, manager.zoom);
    final endLat = lat2TileY(target.latitude, manager.zoom);

    final controller = AnimationController(
      duration: duration ?? widget.zoomAnimationDuration,
      vsync: this,
    );
    _panController = controller;
    _locationOwnsPan = preserveLocationFollow;

    final animation = Tween<Offset>(
      begin: Offset(startLng, startLat),
      end: Offset(endLng, endLat),
    ).chain(CurveTween(curve: curve)).animate(controller);

    controller.addListener(() {
      if (!mounted) return;
      final value = animation.value;
      manager.setCenterFromTileCoords(value.dx, value.dy);
      _notifyCamera(manager);
      setState(() {});
    });
    _completePanAnimation(controller, manager, controller.forward());
  }

  Future<void> _completePanAnimation(AnimationController controller,
      TileManager manager, TickerFuture motion) async {
    try {
      await motion.orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || _panController != controller) return;
    _stopPanAnimation();
    // The final tick's frame may not have built yet; refresh the grid so
    // the settle reconciles the post-motion window. Animated pans reveal
    // new cells as they run, and their fallback only becomes
    // timeout-bounded once the motion is over.
    manager.calculate();
    _settleZoomFallback();
    MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
            fractionalZoom: manager.cameraZoom)
        .dispatch(context);
  }

  void _stopPanAnimation() {
    final controller = _panController;
    _panController = null;
    _locationOwnsPan = false;
    _flinging = false;
    controller?.dispose();
  }

  void _startFling(TileManager manager, Offset velocity) {
    final speed = velocity.distance;
    if (!widget.enableFling || !speed.isFinite || speed < 50) return;
    _stopPanAnimation();
    // Fling motion owns the camera until it ends; any earlier settle
    // timer is stale (the fling's completion/stop path re-settles).
    _cancelZoomFallbackTimer();
    final direction = velocity / speed;
    final start = Offset(manager.centerTileLng, manager.centerTileLat);
    final controller = AnimationController.unbounded(vsync: this);
    _panController = controller;
    _flinging = true;
    controller.addListener(() {
      if (!mounted) return;
      final previous = Offset(manager.centerTileLng, manager.centerTileLat);
      final target =
          start - direction * (controller.value / manager.renderedTileWidth);
      manager.setCenterFromTileCoords(target.dx, target.dy);
      final current = Offset(manager.centerTileLng, manager.centerTileLat);
      // Each axis clamps independently, allowing diagonal motion along an
      // edge. Stop the ticker once both axes are blocked by bounds.
      if (controller.value > 0 && (current - previous).distance < 1e-10) {
        _stopPanAnimation();
        manager.calculate();
        _settleZoomFallback();
        MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
                fractionalZoom: manager.cameraZoom)
            .dispatch(context);
        return;
      }
      _notifyCamera(manager);
      setState(() {});
    });
    _completePanAnimation(
        controller,
        manager,
        controller.animateWith(
          FrictionSimulation(0.135, 0, speed.clamp(0, 8000),
              tolerance: const Tolerance(velocity: 10, distance: 0.5)),
        ));
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.locationController?.isFollowing ?? false) {
      _lastFollowRevision = null;
    }
    _stopPanAnimation();
    _stopFractionalAnimation();
    _settleZoomFallback();
    _scrollPixels = 0;
    if (_pointers.isEmpty) {
      _gestureHadMultiplePointers = false;
      _gestureCancelled = false;
    }
    _pointers.add(event.pointer);
    if (_pointers.length > 1) _gestureHadMultiplePointers = true;
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    _scheduleLocationFollow();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    final manager = _tileManager;
    if (!widget.enableScrollZoom ||
        manager == null ||
        _pointers.isNotEmpty ||
        _scaleStartZoom != null ||
        event is! PointerScrollEvent ||
        !event.scrollDelta.dy.isFinite ||
        event.scrollDelta.dy == 0) {
      return;
    }
    final dy = event.scrollDelta.dy;
    if ((dy < 0 && manager.cameraZoom >= widget.maxZoom) ||
        (dy > 0 && manager.cameraZoom <= widget.minZoom)) {
      _scrollPixels = 0;
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _stopPanAnimation();
      if (_usesFractionalZoom) {
        _pauseLocationFollowing();
        // Accumulate against the active target so quick wheel events do not
        // lose distance while the preceding transition is still animating.
        final target = _fractionalTarget ?? manager.cameraZoom;
        _setContinuousZoom(target - dy / 100,
            focal: event.localPosition, animate: widget.animateZoom);
        return;
      }
      if (_lastScrollTime == null ||
          event.timeStamp - _lastScrollTime! >
              const Duration(milliseconds: 200) ||
          _scrollPixels.sign != dy.sign) {
        _scrollPixels = 0;
      }
      _lastScrollTime = event.timeStamp;
      _scrollPixels += dy;
      final levels = (_scrollPixels / 100).truncate();
      if (levels == 0) return;
      _scrollPixels -= levels * 100;
      _pauseLocationFollowing();
      _zoomBy(-levels, focalLocal: event.localPosition);
    });
  }

  /// Frames [bounds] in the viewport, leaving [padding] around it, then
  /// restores free camera movement (unlike [cameraBounds], nothing stays
  /// constrained afterwards). The computed zoom is continuous in fractional
  /// mode and floored in legacy mode, within min/max zoom. If the bounds
  /// cannot fit at [MapView.minZoom], their edges may be clipped.
  void _fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    bool? animate,
  }) {
    final manager = _tileManager;
    if (manager == null) return;

    _pauseLocationFollowing();
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
    double? continuousTarget;
    if (scales.isEmpty) {
      // Degenerate box (single point) → frame it as close as allowed.
      targetZoom = widget.maxZoom;
    } else {
      final scale = scales.reduce(math.min);
      continuousTarget = (math.log(scale) / math.ln2)
          .clamp(widget.minZoom.toDouble(), widget.maxZoom.toDouble());
      targetZoom = math.max(0, math.log(scale) / math.ln2).floor();
      targetZoom = targetZoom.clamp(widget.minZoom, widget.maxZoom);
    }

    // Projected bounds center, shifted for asymmetric padding.
    final projectedCenterX = (lon2TileX(bounds.west, targetZoom) +
            lon2TileX(bounds.east, targetZoom)) /
        2;
    final projectedCenterY = (lat2TileY(bounds.north, targetZoom) +
            lat2TileY(bounds.south, targetZoom)) /
        2;
    final fitZoom = _usesFractionalZoom
        ? (continuousTarget ?? widget.maxZoom.toDouble())
        : targetZoom.toDouble();
    final fitScale = math.pow(2, fitZoom - targetZoom).toDouble();
    final centerTileX = projectedCenterX -
        (padding.left - padding.right) / (2 * tileWidth * fitScale);
    final centerTileY = projectedCenterY -
        (padding.top - padding.bottom) / (2 * tileHeight * fitScale);
    final targetCenter = LatLng(
      latitude: tileY2Lat(centerTileY, targetZoom),
      longitude: tileX2Lng(centerTileX, targetZoom),
    );

    // Zoom first: the manager zoom switches immediately even in the
    // animated two-phase path, so the pan tween below runs at the target
    // zoom. Then pan to the (padding-shifted) center.
    if (_usesFractionalZoom) {
      _setContinuousZoom(fitZoom,
          centerTarget: targetCenter, animate: animateFit);
      return;
    } else if (targetZoom != manager.zoom) {
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
    MapView.debugZoomTransitionCount++;
    _pinchTransitionActive = false;
    _rebaseGestureOntoCamera();
    // Cancel any in-progress animation.
    _animController.stop();
    _stopPanAnimation();
    _animWaitTimer?.cancel();
    _animWaitTimer = null;
    _clearZoomSnapshot();
    _animWaitingTiles = false;

    // 1. Ensure grid is up-to-date and snapshot the OLD grid.
    manager.calculate();
    _animOldSnapshot = _GridSnapshot.from(manager);

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
    MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
            fractionalZoom: manager.cameraZoom)
        .dispatch(context);

    // Re-anchor the snapshot to the POST-step camera so pans from here
    // on shift the overlay by exactly their screen-pixel delta while it
    // fades out. Manager zoom is already the NEW zoom here.
    final snap = _animOldSnapshot!;
    snap.anchorTileLng = manager.centerTileLng;
    snap.anchorTileLat = manager.centerTileLat;

    // 3. The grid was already rebuilt by [setZoomWithFocalPoint] above —
    //    [calculate] is idempotent, so no extra pass is needed here.
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

  /// Captures one old grid for the whole pinch and switches the backing
  /// camera without starting a time-based animation. The snapshot follows
  /// direct manipulation until scale end, then performs one settle/fade.
  void _startPinchTransition(
    TileManager manager,
    int targetZoom,
    Offset focal,
  ) {
    MapView.debugZoomTransitionCount++;
    _animController.stop();
    _stopPanAnimation();
    _animWaitTimer?.cancel();
    _animWaitTimer = null;

    _clearZoomSnapshot();
    manager.calculate();
    _animOldSnapshot = _GridSnapshot.from(manager);
    _visualScaleFocal = focal;
    manager.setZoomWithFocalPoint(targetZoom, focal, manager.zoom);
    _currentZoom = targetZoom;
    widget.onZoomChanged?.call(targetZoom);
    MapZoomChangeNotification(targetZoom).dispatch(context);
    _notifyCamera(manager);
    MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
            fractionalZoom: manager.cameraZoom)
        .dispatch(context);

    _animWaitingTiles = true;
    _visualScale =
        math.pow(2, manager.zoom - _animOldSnapshot!.zoom).toDouble();
    setState(() {});
  }

  /// Returns true when all strict-viewport tiles in the new zoom have
  /// loaded. Padding and off-world cells are ignored, so a vector-mode
  /// padding ring (intentionally bytes-only) never delays the scale
  /// phase. Called from [_notify] (tiles-changed callback) and from the
  /// timeout in [_startZoomAnimation].
  bool _newTilesReady() {
    final manager = _tileManager;
    if (manager == null) return true;
    return manager.visibleTilesReady;
  }

  /// Transitions from phase 1 (blur + wait) to phase 2 (scale + fade).
  void _beginScalePhase() {
    if (!_animWaitingTiles && _animOldSnapshot == null) return;
    _animWaitingTiles = false;
    _animWaitTimer?.cancel();
    _animWaitTimer = null;

    final settleScale = _visualScale;
    final targetScale =
        math.pow(2, _tileManager!.zoom - _animOldSnapshot!.zoom).toDouble();
    _scaleAnimation = Tween<double>(
      begin: _pinchTransitionActive ? settleScale : 1.0,
      end: _pinchTransitionActive ? settleScale : targetScale,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    ));

    if (!_pinchTransitionActive) _visualScale = 1.0;
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
    _clearZoomSnapshot();
    _animWaitingTiles = false;
    _pinchTransitionActive = false;
    _visualScale = 1.0;
    setState(() {});
    // Any per-region fallback still covering never-loaded cells gets the
    // same bounded settle as the fractional path.
    _settleZoomFallback();
    _scheduleLocationFollow(force: true);
  }

  void _clearZoomSnapshot() {
    _animOldSnapshot?.releaseImages();
    _animOldSnapshot = null;
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
      _clearZoomSnapshot();
      _animWaitingTiles = false;
      _pinchTransitionActive = false;
      _visualScale = 1.0;
    }
    _stopPanAnimation();
    _stopFractionalAnimation();
    _cancelZoomFallbackTimer();
    _interacting = false;
    // A fresh gesture starts with a clean coalescing slot so its first
    // update applies immediately.
    _pendingScaleUpdate = null;
    _scaleAppliedSinceFrame = false;
    _lastAppliedGestureFocal = null;
    _lastAppliedGestureScale = null;
    _gestureNeedsRebase = false;
    _scaleStartCameraZoom = manager.cameraZoom;
    _lastFractionalFocal = details.localFocalPoint;

    _scaleStartTileLng = manager.centerTileLng;
    _scaleStartTileLat = manager.centerTileLat;
    _scaleStartZoom = manager.zoom.toDouble();
    _scaleStartFocal = details.localFocalPoint;
    _pinchZoomDirection = 0;
    _pinchTransitionActive = false;
  }

  void _onScaleUpdate(TileManager manager, ScaleUpdateDetails details) {
    // Mark direct manipulation only once the gesture actually moves: a
    // plain tap also raises scale-start, and that must not disable the
    // zoom transition's blur.
    _interacting = true;
    if (details.pointerCount > 1) _gestureHadMultiplePointers = true;
    final startZoom = _scaleStartZoom;
    final startFocal = _scaleStartFocal;
    if (startZoom == null ||
        startFocal == null ||
        !details.scale.isFinite ||
        details.scale <= 0) {
      return;
    }

    _pauseLocationFollowing();
    // A camera command may have re-flagged the gesture: consume the
    // rebase before deciding whether this update steps a zoom level.
    _consumeGestureRebase();
    // Zoom steps are discrete, user-visible transitions (snapshot capture,
    // focal anchoring, re-baselining): they must run at their own event so
    // the step timing and anchors stay identical with and without
    // coalescing. Only the continuous work (pans, fractional zoom) is
    // coalesced to once per frame.
    final stepsZoom =
        !_usesFractionalZoom && _scaleUpdateStepsZoom(manager, details);
    final pending = _pendingScaleUpdate;
    if (stepsZoom && pending != null) {
      _pendingScaleUpdate = null;
      _applyScaleUpdate(manager, pending);
    }
    if (!_scaleAppliedSinceFrame || stepsZoom) {
      // First update of this frame — or a zoom step: apply immediately.
      _scaleAppliedSinceFrame = true;
      _applyScaleUpdate(manager, details);
      // Re-arm the per-frame slot at the next real frame boundary even
      // when nothing was deferred: otherwise the slot stays occupied
      // until some later flush runs, and the first input of a later
      // frame would be delayed for no reason.
      _scheduleScaleFlush();
    } else {
      // Bursts within one frame coalesce to their latest event; the
      // cumulative scale and latest focal point are preserved because
      // the recognizer reports them absolutely from gesture start.
      _pendingScaleUpdate = details;
      _scheduleScaleFlush();
    }
  }

  /// A camera command (controller move/zoom, wheel, host echo, follow
  /// retarget) owns the camera: drop any still-queued gesture update and
  /// mark the active gesture for rebasing onto whatever the camera is
  /// when the gesture next applies. Without the rebase, the next applied
  /// update pans/zooms from the gesture's pre-command baseline and jumps
  /// the camera back to its trajectory.
  void _rebaseGestureOntoCamera() {
    final pending = _pendingScaleUpdate;
    _pendingScaleUpdate = null;
    if (_scaleStartZoom == null || _scaleStartFocal == null) return;
    // The dropped update is the freshest gesture state known.
    if (pending != null) {
      _lastAppliedGestureFocal = pending.localFocalPoint;
      _lastAppliedGestureScale = pending.scale;
    }
    _gestureNeedsRebase = true;
  }

  /// Refreshes the active gesture's anchors from the current camera.
  /// Runs lazily — right before the gesture applies again — so animated
  /// commands and follow retargets land however the camera ended up.
  void _consumeGestureRebase() {
    if (!_gestureNeedsRebase) return;
    _gestureNeedsRebase = false;
    final manager = _tileManager;
    if (manager == null) return;
    // Direct manipulation resumed after a command: it owns the camera now,
    // so any animation the command started must stop before its next tick
    // overwrites the drag. (Same teardown as a fresh gesture start.)
    if (_isAnimating) {
      _animController.stop();
      _animWaitTimer?.cancel();
      _animWaitTimer = null;
      _clearZoomSnapshot();
      _animWaitingTiles = false;
      _pinchTransitionActive = false;
      _visualScale = 1.0;
    }
    _stopPanAnimation();
    _stopFractionalAnimation();
    _cancelZoomFallbackTimer();
    _scaleStartTileLng = manager.centerTileLng;
    _scaleStartTileLat = manager.centerTileLat;
    final focal = _lastAppliedGestureFocal;
    if (focal != null) {
      _scaleStartFocal = focal;
      _lastFractionalFocal = focal;
    }
    final scale = _lastAppliedGestureScale ?? 1;
    if (scale.isFinite && scale > 0) {
      // Map the recognizer's cumulative scale onto the current zoom so
      // quantization continues around the camera the command set: at
      // [scale], the next update must land exactly on [manager.zoom].
      _scaleStartZoom = manager.zoom - math.log(scale) / math.ln2;
      final startCameraZoom = _scaleStartCameraZoom;
      if (startCameraZoom != null) {
        _scaleStartCameraZoom =
            manager.cameraZoom - math.log(scale) / math.ln2;
      }
    }
    _pinchZoomDirection = 0;
  }

  /// Whether applying [details] on the integer-zoom path would cross a
  /// zoom level. Mirrors the quantization in [_applyScaleUpdate].
  bool _scaleUpdateStepsZoom(TileManager manager, ScaleUpdateDetails details) {
    final startZoom = _scaleStartZoom;
    if (startZoom == null ||
        !details.scale.isFinite ||
        details.scale <= 0 ||
        _usesFractionalZoom) {
      return false;
    }
    final continuousZoom = startZoom + math.log(details.scale) / math.ln2;
    var newZoom = continuousZoom.round().clamp(widget.minZoom, widget.maxZoom);
    if ((_pinchZoomDirection > 0 &&
            newZoom < manager.zoom &&
            continuousZoom > manager.zoom - 0.65) ||
        (_pinchZoomDirection < 0 &&
            newZoom > manager.zoom &&
            continuousZoom < manager.zoom + 0.65)) {
      newZoom = manager.zoom;
    }
    return newZoom != manager.zoom;
  }

  /// Applies a coalesced update at the next frame boundary, then re-arms
  /// the per-frame application slot. Never forces a frame by itself.
  void _scheduleScaleFlush() {
    if (_scaleFlushScheduled) return;
    _scaleFlushScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _scaleFlushScheduled = false;
      _scaleAppliedSinceFrame = false;
      final details = _pendingScaleUpdate;
      _pendingScaleUpdate = null;
      final manager = _tileManager;
      if (details != null && manager != null) {
        _applyScaleUpdate(manager, details);
      }
    });
  }

  void _applyScaleUpdate(TileManager manager, ScaleUpdateDetails details) {
    _consumeGestureRebase();
    final startZoom = _scaleStartZoom;
    final startFocal = _scaleStartFocal;
    if (startZoom == null ||
        startFocal == null ||
        !details.scale.isFinite ||
        details.scale <= 0) {
      return;
    }
    final focalLocal = details.localFocalPoint;
    _lastAppliedGestureFocal = focalLocal;
    _lastAppliedGestureScale = details.scale;
    if (_usesFractionalZoom) {
      final delta = focalLocal - (_lastFractionalFocal ?? focalLocal);
      manager.setCenterFromTileCoords(
          manager.centerTileLng - delta.dx / manager.renderedTileWidth,
          manager.centerTileLat - delta.dy / manager.renderedTileHeight);
      _lastFractionalFocal = focalLocal;
      final target =
          (_scaleStartCameraZoom! + math.log(details.scale) / math.ln2)
              .clamp(widget.minZoom.toDouble(), widget.maxZoom.toDouble());
      _applyContinuousZoom(manager, target, focalLocal, notify: false);
      _notifyCamera(manager);
      MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
              fractionalZoom: manager.cameraZoom)
          .dispatch(context);
      setState(() {});
      return;
    }

    // Quantize against the original gesture scale, never against the last
    // rounded zoom. A small reverse deadband prevents tiny span changes
    // during a two-finger pan from toggling the previous zoom step.
    final continuousZoom = startZoom + math.log(details.scale) / math.ln2;
    var newZoom = continuousZoom.round().clamp(widget.minZoom, widget.maxZoom);
    if ((_pinchZoomDirection > 0 &&
            newZoom < manager.zoom &&
            continuousZoom > manager.zoom - 0.65) ||
        (_pinchZoomDirection < 0 &&
            newZoom > manager.zoom &&
            continuousZoom < manager.zoom + 0.65)) {
      newZoom = manager.zoom;
    }

    if (newZoom != manager.zoom) {
      _pinchZoomDirection = (newZoom - manager.zoom).sign;
      if (widget.animateZoom && !_pinchTransitionActive) {
        // First zoom step of this pinch: build the snapshot/wait/scale
        // state exactly once. Later steps within the same gesture are
        // handled below by moving the camera and re-anchoring that snapshot,
        // so a multi-level pinch no longer recreates a full transition (and
        // a full-viewport blur layer) at every crossed integer zoom.
        _pinchTransitionActive = true;
        _startPinchTransition(manager, newZoom, focalLocal);
      } else {
        // Instant (or later) zoom steps of this gesture: no animated
        // overlay holds the old grid, so pin it across the switch for
        // the per-region fallback.
        _zoomFallback?.beginZoomTransition();
        manager.setZoomWithFocalPoint(newZoom, focalLocal, manager.zoom);
        _currentZoom = newZoom;
        widget.onZoomChanged?.call(newZoom);
        MapZoomChangeNotification(newZoom).dispatch(context);
        _notifyCamera(manager);
        // Keep the existing interaction snapshot aligned with the new
        // camera instead of capturing a fresh one.
        final snap = _animOldSnapshot;
        if (snap != null && !_pinchTransitionActive) {
          snap.anchorTileLng = manager.centerTileLng;
          snap.anchorTileLat = manager.centerTileLat;
        }
      }

      // Re-baseline the gesture: the camera (and its tile-space anchor)
      // is now in the NEW zoom's units. Without this, the pan below
      // would mix units from different zoom levels and teleport the
      // camera — tile coordinates double with every zoom step.
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

    final snapshot = _animOldSnapshot;
    if (_pinchTransitionActive && snapshot != null) {
      // Keep the transform origin from the first zoom step. Any later focal
      // drift is already represented by the camera's pan delta; replacing
      // the origin here would apply that drift a second time.
      _visualScale = math.pow(2, manager.zoom - snapshot.zoom).toDouble();
    }

    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final manager = _tileManager;
    // Apply any update still waiting for its frame before the gesture
    // ends, so fling velocity and the final camera agree with the last
    // pointer movement.
    final pending = _pendingScaleUpdate;
    _pendingScaleUpdate = null;
    if (pending != null && manager != null) {
      _applyScaleUpdate(manager, pending);
    }
    if (manager != null) {
      MapCameraChangeNotification(manager.centerLatLng, manager.zoom,
              fractionalZoom: manager.cameraZoom)
          .dispatch(context);
    }
    _scaleStartTileLng = null;
    _scaleStartTileLat = null;
    _scaleStartZoom = null;
    _scaleStartCameraZoom = null;
    _lastFractionalFocal = null;
    _scaleStartFocal = null;
    _lastAppliedGestureFocal = null;
    _lastAppliedGestureScale = null;
    _gestureNeedsRebase = false;
    final wasPanning = _interacting &&
        !_gestureHadMultiplePointers &&
        !_gestureCancelled &&
        details.pointerCount == 0;
    _interacting = false;
    if (wasPanning && manager != null) {
      _startFling(manager, details.velocity.pixelsPerSecond);
    }

    _settleZoomFallback();
    if (_pinchTransitionActive && _animOldSnapshot != null) {
      if (_newTilesReady()) {
        _beginScalePhase();
      } else {
        _animWaitingTiles = true;
        _animWaitTimer?.cancel();
        _animWaitTimer = Timer(_animWaitTimeout, () {
          if (!mounted || !_animWaitingTiles || _interacting) return;
          _beginScalePhase();
        });
      }
      if (mounted) setState(() {});
    }
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
  void _closeOverlayOnMapTap() {
    final markers = widget.markers;
    if (markers == null) return;
    final overlay = markers.overlayMarker;
    if (overlay != null && overlay.overlayConfig.closeOnMapTap) {
      markers.hideOverlay();
    }
  }

  void _onMapPress(Offset position, {bool longPress = false}) {
    final manager = _tileManager;
    if (manager == null) return;
    if (!longPress) _closeOverlayOnMapTap();
    final route = hitTestPolylines(widget.polylines, manager, position,
        longPress: longPress,
        enableAll: longPress
            ? widget.onPolylineLongPress != null
            : widget.onPolylineTap != null,
        cache: _shapeGeometryCache);
    if (route != null) {
      if (longPress) {
        route.polyline.onLongPress?.call(route);
        widget.onPolylineLongPress?.call(route);
        MapPolylineLongPressNotification(route).dispatch(context);
      } else {
        route.polyline.onTap?.call(route);
        widget.onPolylineTap?.call(route);
        MapPolylineTapNotification(route).dispatch(context);
      }
      return;
    }
    final area = hitTestPolygons(widget.polygons, manager, position,
        longPress: longPress,
        enableAll: longPress
            ? widget.onPolygonLongPress != null
            : widget.onPolygonTap != null,
        cache: _shapeGeometryCache);
    if (area != null) {
      if (longPress) {
        area.polygon.onLongPress?.call(area);
        widget.onPolygonLongPress?.call(area);
        MapPolygonLongPressNotification(area).dispatch(context);
      } else {
        area.polygon.onTap?.call(area);
        widget.onPolygonTap?.call(area);
        MapPolygonTapNotification(area).dispatch(context);
      }
      return;
    }
    final point = manager.screenToLatLng(position);
    if (longPress) {
      widget.onLongPress?.call(point);
      MapLongPressNotification(point, position).dispatch(context);
    } else {
      widget.onTap?.call(point);
      MapTapNotification(point, position).dispatch(context);
    }
  }

  // ── Build ───────────────────────────────────────────────────────────

  /// Shown while a vector style loads (style JSON + TileJSON fetch) or if
  /// it failed — no tile grid can be built until sources resolve.
  Widget _buildStylePlaceholder() {
    final state =
        MapLoadState(stage: MapLoadingStage.style, styleError: _vectorError);
    if (_vectorError != null) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(context, state, _loadVectorStyle);
      }
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
              _retryButton(_loadVectorStyle),
            ],
          ),
        ),
      );
    }
    if (widget.loadingBuilder != null) {
      return widget.loadingBuilder!(context, state);
    }
    return const ColoredBox(
      color: Color(0xFFF5F5F5),
      child: Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _retryButton(VoidCallback retry) => Material(
        type: MaterialType.transparency,
        child: TextButton(onPressed: retry, child: const Text('Retry')),
      );

  Widget _tileErrorOverlay(MapLoadState state, VoidCallback retry) => Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 2,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_off, size: 20),
                const SizedBox(width: 8),
                const Flexible(child: Text('Some map tiles could not load')),
                _retryButton(retry),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    MapView.debugBuildCount++;
    if (widget.vectorStyle != null && _vectorRuntime == null) {
      return _buildStylePlaceholder();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final manager = _ensureManager(size);

        // Rebuild the visible grid (cheap: integer math + cache hits).
        manager.calculate();
        final loadState = manager.loadState;

        // Per-region zoom fallback: cover each missing visible cell with
        // retained imagery from neighbouring zooms. The coverage object
        // follows the manager (recreated on style switches); reconcile is
        // a no-op unless the grid/content revision changed.
        var coverage = _zoomFallback;
        if (coverage == null || coverage.manager != manager) {
          coverage?.dispose();
          coverage = ZoomFallbackCoverage(manager);
          _zoomFallback = coverage;
        }
        coverage.reconcile();
        // While the two-phase zoom animation holds its fully opaque old
        // grid over the viewport, the fallback beneath is invisible — skip
        // painting it. Direct manipulation keeps it active so a pan past
        // the snapshot's extent still shows fallback at the leading edge.
        final fallbackSuppressed =
            !_interacting && _animWaitingTiles && _animOldSnapshot != null;
        final fallbackActive = coverage.hasRegions && !fallbackSuppressed;

        final runtime = _vectorRuntime;

        // During scale animation, render two layers.
        final isAnimatingZoom = _isAnimating && _animOldSnapshot != null;

        // Compute scale alignment from focal point.
        final alignmentX =
            size.width > 0 ? 2 * _visualScaleFocal.dx / size.width - 1 : 0.0;
        final alignmentY =
            size.height > 0 ? 2 * _visualScaleFocal.dy / size.height - 1 : 0.0;
        final scaleAlignment = Alignment(
          alignmentX.clamp(-1.0, 1.0),
          alignmentY.clamp(-1.0, 1.0),
        );

        return Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          onPointerCancel: (event) {
            _gestureCancelled = true;
            _onPointerUp(event);
          },
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
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
                    onTapUp: (details) => _onMapPress(details.localPosition),
                    onLongPressStart: (details) =>
                        _onMapPress(details.localPosition, longPress: true),
                    child: Stack(
                      children: [
                        // ── Per-region zoom fallback (below the grid) ──
                        // Missing cells paint retained ancestor/descendant
                        // imagery over the checkerboard; loaded cells only
                        // get the opaque base so transparent replacement
                        // tiles blend against the plain-grid background.
                        if (fallbackActive)
                          Positioned.fill(
                            child: CustomPaint(
                              size: size,
                              painter: ZoomFallbackPainter(
                                coverage: coverage,
                                manager: manager,
                              ),
                            ),
                          ),
                        // ── Current tile grid ─
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
                              tileScale: manager.zoomScale,
                              paintBackground: !fallbackActive,
                              paintPlaceholders: !fallbackActive,
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
                            interactionSnapshot: _pinchTransitionActive,
                            blurEnabled: !kIsWeb && !_interacting,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                if (widget.polygons.isNotEmpty)
                  Positioned.fill(
                      child: PolygonLayer(
                          polygons: widget.polygons,
                          manager: manager,
                          cache: _shapeGeometryCache)),

                // ── Polylines (above tiles, below markers and labels) ──
                if (widget.polylines.isNotEmpty) ...[
                  Positioned.fill(
                    child: PolylineLayer(
                      polylines: widget.polylines,
                      manager: manager,
                      cache: _shapeGeometryCache,
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
                        MapMarkerLongPressNotification(marker)
                            .dispatch(context);
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
                          // Labels prepare after their base image is published
                          // and notify this notifier; only the label surface
                          // repaints, leaving tiles, markers, controls alone.
                          repaint: runtime.labelsNotifier,
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
                          tileScale: manager.zoomScale,
                          zoom: manager.zoom,
                          overlay: runtime.labelOverlay,
                        ),
                      ),
                    ),
                  ),
                ],

                if (widget.showUserLocation &&
                    widget.locationController?.location != null)
                  Positioned.fill(
                      child: UserLocationLayer(
                          location: widget.locationController!.location!,
                          manager: manager,
                          stale: widget.locationController!.error != null)),

                if (loadState.isLoading && widget.loadingBuilder != null)
                  Positioned.fill(
                      child: IgnorePointer(
                          child: widget.loadingBuilder!(context, loadState))),
                if (loadState.hasError)
                  Positioned.fill(
                      child: widget.errorBuilder?.call(
                              context, loadState, manager.retryVisibleTiles) ??
                          _tileErrorOverlay(
                              loadState, manager.retryVisibleTiles)),

                // ── Zoom controls (not affected by scale) ────────────
                if (widget.showZoomControls) ...[
                  Positioned.fill(
                    child: MapZoomControls(
                      zoom: _usesFractionalZoom
                          ? manager.cameraZoom
                          : _currentZoom,
                      minZoom: widget.minZoom,
                      maxZoom: widget.maxZoom,
                      alignment: widget.zoomControlsAlignment,
                      onZoomIn: _zoomIn,
                      onZoomOut: _zoomOut,
                    ),
                  ),
                ],

                if (widget.showLocationControl &&
                    widget.locationController != null)
                  Positioned.fill(
                      child: MapLocationControl(
                          controller: widget.locationController!,
                          alignment: widget.locationControlAlignment)),

                if (widget.showScaleBar)
                  Positioned.fill(
                    child: MapScaleBar(
                      latitude: manager.centerLatLng.latitude,
                      zoom: manager.cameraZoom,
                      unit: widget.scaleBarUnit,
                      alignment: widget.scaleBarAlignment,
                      maxWidth: widget.scaleBarMaxWidth,
                    ),
                  ),

                // ── Attribution (required by vector tile providers) ───
                if (runtime != null &&
                    runtime.loaded.attribution.isNotEmpty) ...[
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
          ),
        );
      },
    );
  }
}
