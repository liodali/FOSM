import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/scheduler.dart';

import '../api/marker.dart';
import '../api/marker_cluster.dart';
import '../api/marker_manager.dart';
import '../api/tile_manager.dart';
import 'marker_cluster_engine.dart';

/// Renders the markers of a [MarkerManager] at their projected positions,
/// above the tile grid and below the vector label overlay.
///
/// Internal — [MapView] hosts this layer; hosts interact with markers
/// through the manager only.
///
/// Repositioning rides the map's own rebuild cycle: `_MapViewState` calls
/// `setState` on every pan/zoom frame, which rebuilds this layer with the
/// current camera. The layer additionally listens to the manager so
/// add/remove mutations repaint on their own.
///
/// Also hosts the marker overlay ("info window") system: markers with
/// [Marker.overlayBuilder] get tap-to-toggle overlays anchored to the
/// marker widget and following it across camera changes. Overlays with
/// `MarkerOverlayConfig.removeOnMove` are dismissed from [didUpdateWidget]
/// as soon as the camera snapshot changes — outside the build phase, so
/// the dismissal never renders a stale frame.
class MarkerLayer extends StatefulWidget {
  final MarkerManager markers;

  /// Camera + projection source. Grid state is read synchronously during
  /// build, matching how the tile painter consumes it.
  final TileManager manager;

  /// Clustering configuration. When null, no clustering is performed.
  final MarkerClusterOptions? clusterOptions;

  /// Called when a marker is tapped.
  final ValueChanged<Marker>? onMarkerTap;

  /// Called when a marker is long-pressed.
  final ValueChanged<Marker>? onMarkerLongPress;

  /// Called when a generated cluster is tapped.
  final ValueChanged<MarkerCluster>? onClusterTap;

  /// Called when a marker's overlay is shown.
  final ValueChanged<Marker>? onOverlayShown;

  /// Called when a marker's overlay is hidden.
  final ValueChanged<Marker>? onOverlayHidden;

  const MarkerLayer({
    super.key,
    required this.markers,
    required this.manager,
    this.clusterOptions,
    this.onMarkerTap,
    this.onMarkerLongPress,
    this.onClusterTap,
    this.onOverlayShown,
    this.onOverlayHidden,
  });

  @override
  State<MarkerLayer> createState() => _MarkerLayerState();
}

class _MarkerLayerState extends State<MarkerLayer>
    with SingleTickerProviderStateMixin {
  /// Entrance animation for the visible overlay; value 1 when idle-shown.
  late final AnimationController _overlayController;

  /// The marker the controller is currently animating for — lets a
  /// show → switch → hide sequence restart the entrance correctly.
  Marker? _animatedOverlayMarker;

  /// The last overlay marker reported to [onOverlayShown]/[onOverlayHidden]
  /// callbacks, used to avoid duplicate calls.
  Marker? _lastOverlayMarker;

  /// Camera snapshot used to detect movement between parent rebuilds.
  ({double lng, double lat, int zoom})? _lastCamera;

  /// Measured sizes of overlay-capable markers, keyed by identity. The
  /// overlay anchors to the marker widget's edge, which requires its size.
  final Map<Marker, Size> _markerSizes = {};

  /// Cached clustering result and the key under which it was computed.
  List<ClusterRenderItem>? _clusterItems;
  _ClusterCacheKey? _clusterCacheKey;

  @override
  void initState() {
    super.initState();
    _overlayController = AnimationController(vsync: this, value: 1.0);
    _overlayController.addListener(_onOverlayTick);
    widget.markers.addListener(_onMarkersChanged);
    _lastOverlayMarker = widget.markers.overlayMarker;
    _snapshotCamera();
  }

  @override
  void didUpdateWidget(MarkerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.markers != oldWidget.markers) {
      oldWidget.markers.removeListener(_onMarkersChanged);
      widget.markers.addListener(_onMarkersChanged);
      _clusterCacheKey = null;
      _clusterItems = null;
      _syncOverlayAnimation();
    }
    if (widget.clusterOptions != oldWidget.clusterOptions) {
      _clusterCacheKey = null;
      _clusterItems = null;
    }
    // Camera check must run outside build: hideOverlay notifies, which
    // setStates via the manager listener.
    _handleCameraMaybeChanged();
  }

  @override
  void dispose() {
    widget.markers.removeListener(_onMarkersChanged);
    _overlayController.removeListener(_onOverlayTick);
    _overlayController.dispose();
    super.dispose();
  }

  void _snapshotCamera() {
    final manager = widget.manager;
    _lastCamera = (
      lng: manager.centerTileLng,
      lat: manager.centerTileLat,
      zoom: manager.zoom,
    );
  }

  /// Dismisses the overlay when the camera moved and its config says so.
  /// Tile-grid rebuilds (tiles arriving) leave the camera untouched and
  /// are naturally ignored.
  void _handleCameraMaybeChanged() {
    final manager = widget.manager;
    final camera = (
      lng: manager.centerTileLng,
      lat: manager.centerTileLat,
      zoom: manager.zoom,
    );
    if (camera == _lastCamera) return;
    _lastCamera = camera;

    final overlay = widget.markers.overlayMarker;
    if (overlay != null && overlay.overlayConfig.removeOnMove) {
      widget.markers.hideOverlay();
    }
  }

  void _onMarkersChanged() {
    final live = widget.markers.markers;
    _markerSizes.removeWhere((marker, _) => !live.contains(marker));

    final currentOverlay = widget.markers.overlayMarker;
    if (currentOverlay != _lastOverlayMarker) {
      if (_lastOverlayMarker != null) {
        widget.onOverlayHidden?.call(_lastOverlayMarker!);
      }
      if (currentOverlay != null) {
        widget.onOverlayShown?.call(currentOverlay);
      }
      _lastOverlayMarker = currentOverlay;
    }

    _clusterCacheKey = null;
    _clusterItems = null;
    _syncOverlayAnimation();
    if (mounted) setState(() {});
  }

  /// Starts, restarts or resets the entrance animation to match the
  /// manager's current overlay marker.
  void _syncOverlayAnimation() {
    final current = widget.markers.overlayMarker;
    if (identical(current, _animatedOverlayMarker)) return;
    _animatedOverlayMarker = current;

    if (current == null) {
      _overlayController.stop();
      _overlayController.value = 0;
      return;
    }
    final duration = current.overlayConfig.animationDuration;
    if (duration == Duration.zero) {
      _overlayController.stop();
      _overlayController.value = 1;
    } else {
      _overlayController.duration = duration;
      _overlayController.forward(from: 0);
    }
  }

  void _onOverlayTick() {
    if (mounted) setState(() {});
  }

  // ── Marker gestures ─────────────────────────────────────────────────

  void _handleMarkerTap(Marker marker) {
    marker.onTap?.call();
    widget.onMarkerTap?.call(marker);
    final markers = widget.markers;
    if (marker.overlayBuilder != null) {
      if (markers.overlayMarker == marker) {
        markers.hideOverlay();
      } else {
        markers.showOverlay(marker);
      }
    } else if (markers.overlayMarker != null &&
        markers.overlayMarker!.overlayConfig.closeOnMapTap) {
      // Tapping a marker without its own overlay behaves like tapping the
      // bare map.
      markers.hideOverlay();
    }
  }

  void _handleClusterTap(MarkerCluster cluster, Offset position) {
    widget.onClusterTap?.call(cluster);
    // Optional focal zoom is handled by the parent MapView.
  }

  // ── Marker measurement ──────────────────────────────────────────────

  void _onMarkerSizeChanged(Marker marker, Size size) {
    final previous = _markerSizes[marker];
    _markerSizes[marker] = size;
    if (previous == size) return;
    if (widget.markers.overlayMarker == marker) {
      // Layout-time — reposition on the next frame.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  // ── Clustering ──────────────────────────────────────────────────────

  List<ClusterRenderItem> _computeClusters() {
    final options = widget.clusterOptions;
    if (options == null) return const [];

    final key = _ClusterCacheKey(
      manager: widget.markers,
      managerRevision: widget.markers.revision,
      zoom: widget.manager.zoom,
      options: options,
    );
    if (_clusterCacheKey == key) {
      return _clusterItems!;
    }

    final engine = MarkerClusterEngine(
      manager: widget.markers,
      zoom: widget.manager.zoom,
      options: options,
    );
    final items = engine.cluster();
    _clusterItems = items;
    _clusterCacheKey = key;
    return items;
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;

    final options = widget.clusterOptions;
    final hasClustering = options != null;
    final clusterItems = hasClustering ? _computeClusters() : null;

    // Hide overlay of any marker that is currently grouped into a cluster.
    final groupedMarkers = <Marker>{};
    if (hasClustering && clusterItems != null) {
      for (final item in clusterItems) {
        if (item is ClusterGroupItem) {
          for (final m in item.cluster.markers) {
            groupedMarkers.add(m);
          }
        }
      }
    }
    final overlayMarker = widget.markers.overlayMarker;
    if (overlayMarker != null && groupedMarkers.contains(overlayMarker)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.markers.hideOverlay();
      });
    }

    // Overlay paints above all markers (later Stack child).
    final overlay = _buildOverlay(manager);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (hasClustering && clusterItems != null) ...[
          for (final item in clusterItems)
            switch (item) {
              SingleClusterMarkerItem(:final marker) =>
                _buildMarkerWidget(context, manager, marker),
              ClusterGroupItem(:final cluster) =>
                _buildClusterWidget(context, manager, cluster),
            },
          // Plain markers are not part of the clustering result; render them
          // on top so they remain interactive above generated clusters.
          for (final marker in widget.markers.markers)
            if (marker is! ClusterMarker)
              _buildMarkerWidget(context, manager, marker),
        ] else ...[
          for (final marker in widget.markers.markers)
            _buildMarkerWidget(context, manager, marker),
        ],
        if (overlay != null) overlay,
      ],
    );
  }

  Widget _buildMarkerWidget(
    BuildContext context,
    TileManager manager,
    Marker marker,
  ) {
    final position = manager.latLngToScreen(marker.point);

    // Viewport culling: markers whose anchor is off-screen (beyond the
    // margin that lets wide/tall widgets stay visible while partially
    // on screen) are skipped entirely — not built, laid out or painted.
    if (!_isVisible(position, manager)) return const SizedBox.shrink();

    // FractionalTranslation shifts by a fraction of the child's own
    // size, so the anchor works without knowing the widget's
    // dimensions: center → (-0.5, -0.5), bottomCenter → (-0.5, -1.0), …
    final alignment = marker.alignment;

    final child = _buildMarkerChild(marker);

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: FractionalTranslation(
        translation: Offset(
          -(alignment.x + 1.0) / 2.0,
          -(alignment.y + 1.0) / 2.0,
        ),
        child: child,
      ),
    );
  }

  Widget _buildClusterWidget(
    BuildContext context,
    TileManager manager,
    MarkerCluster cluster,
  ) {
    final position = manager.latLngToScreen(cluster.point);
    if (!_isVisible(position, manager)) return const SizedBox.shrink();

    final child = _buildClusterChild(context, cluster);

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: child,
      ),
    );
  }

  bool _isVisible(Offset position, TileManager manager) {
    return position.dx >= -_cullMargin &&
        position.dy >= -_cullMargin &&
        position.dx <= manager.width + _cullMargin &&
        position.dy <= manager.height + _cullMargin;
  }

  /// Wraps the marker child with its gesture handlers when it has any;
  /// overlay-capable markers are additionally measured so the overlay can
  /// anchor to the marker widget's edge.
  Widget _buildMarkerChild(Marker marker) {
    var child = marker.child;

    final needsMeasure = marker.overlayBuilder != null;
    final needsGestures =
        marker.onTap != null || marker.onLongPress != null || needsMeasure;
    if (needsGestures) {
      child = GestureDetector(
        // Opaque makes the whole marker box tappable even when the child
        // (e.g. a bare SizedBox) has no hit area of its own. Panning from
        // the marker still works: the arena only resolves to the marker
        // when the finger doesn't move.
        behavior: HitTestBehavior.opaque,
        onTap: needsGestures ? () => _handleMarkerTap(marker) : null,
        onLongPress: marker.onLongPress != null
            ? () {
                marker.onLongPress?.call();
                widget.onMarkerLongPress?.call(marker);
              }
            : null,
        child: child,
      );
      // Hand cursor over tappable markers on pointer devices.
      child = MouseRegion(cursor: SystemMouseCursors.click, child: child);
    }
    if (needsMeasure) {
      child = _MeasureSize(
        onSizeChanged: (size) => _onMarkerSizeChanged(marker, size),
        child: child,
      );
    }
    return child;
  }

  Widget _buildClusterChild(BuildContext context, MarkerCluster cluster) {
    final builder = widget.clusterOptions?.builder;
    final child = builder != null
        ? builder(context, cluster)
        : _DefaultClusterBadge(count: cluster.count);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          _handleClusterTap(cluster, manager.latLngToScreen(cluster.point)),
      child: child,
    );
  }

  TileManager get manager => widget.manager;

  /// Builds the visible overlay, or null. Anchored to the marker widget
  /// (via its measured size) at the configured side and offset, and
  /// repositioned on every rebuild — which happens on each pan/zoom frame.
  Widget? _buildOverlay(TileManager manager) {
    final marker = widget.markers.overlayMarker;
    final builder = marker?.overlayBuilder;
    if (marker == null || builder == null) return null;

    final position = manager.latLngToScreen(marker.point);
    if (!_isVisible(position, manager)) return null;

    final config = marker.overlayConfig;
    final alignment = marker.alignment;
    final translation = Offset(
      -(alignment.x + 1.0) / 2.0,
      -(alignment.y + 1.0) / 2.0,
    );
    final size = _markerSizes[marker];

    // Marker child geometry: top-left = anchor + alignmentTranslation ×
    // size (unmeasured markers fall back to the raw geographic anchor).
    Offset topLeft = position;
    if (size != null) {
      topLeft = position +
          Offset(translation.dx * size.width, translation.dy * size.height);
    }

    Offset pivot;
    Alignment overlayAlignment;
    Alignment scaleAlignment;
    switch (config.anchor) {
      case MarkerOverlayAnchor.above:
        pivot = size != null
            ? topLeft +
                Offset(size.width / 2 + config.offset.dx, -config.offset.dy)
            : position + Offset(config.offset.dx, -config.offset.dy);
        overlayAlignment = Alignment.bottomCenter;
        scaleAlignment = const Alignment(0, 1); // grows out of the marker
      case MarkerOverlayAnchor.below:
        pivot = size != null
            ? topLeft +
                Offset(size.width / 2 + config.offset.dx,
                    size.height + config.offset.dy)
            : position + config.offset;
        overlayAlignment = Alignment.topCenter;
        scaleAlignment = const Alignment(0, -1);
      case MarkerOverlayAnchor.center:
        pivot = size != null
            ? topLeft +
                Offset(size.width / 2 + config.offset.dx,
                    size.height / 2 + config.offset.dy)
            : position + config.offset;
        overlayAlignment = Alignment.center;
        scaleAlignment = Alignment.center;
    }

    Widget content = Builder(builder: builder);
    if (config.animationDuration != Duration.zero) {
      final curved = CurvedAnimation(
        parent: _overlayController,
        curve: Curves.easeOutCubic,
      );
      content = FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
          alignment: scaleAlignment,
          child: content,
        ),
      );
    }

    return Positioned(
      left: pivot.dx,
      top: pivot.dy,
      child: FractionalTranslation(
        translation: Offset(
          -(overlayAlignment.x + 1.0) / 2.0,
          -(overlayAlignment.y + 1.0) / 2.0,
        ),
        child: GestureDetector(
          // Keep bare taps inside the overlay from reaching the map's
          // close-on-tap handler; interactive children deeper in the tree
          // still win the arena for their own taps.
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: content,
        ),
      ),
    );
  }

  /// Padding around the viewport that keeps partially visible markers
  /// from popping at the edges. One tile width covers typical pin and
  /// text marker sizes.
  static const double _cullMargin = 256.0;
}

/// Reports its child's size after layout. Used to anchor overlays to the
/// marker widget's edge without constrained layout.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({
    required this.onSizeChanged,
    required super.child,
  });

  final ValueChanged<Size> onSizeChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onSizeChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasureSize renderObject,
  ) {
    renderObject.onSizeChanged = onSizeChanged;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onSizeChanged);

  ValueChanged<Size> onSizeChanged;
  Size? _lastSize;

  @override
  void performLayout() {
    super.performLayout();
    if (child == null) return;
    if (_lastSize == child!.size) return;
    _lastSize = child!.size;
    onSizeChanged(child!.size);
  }
}

/// Default cluster badge: a circular badge showing the member count.
class _DefaultClusterBadge extends StatelessWidget {
  final int count;

  const _DefaultClusterBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Key used to cache cluster engine results.
class _ClusterCacheKey {
  final MarkerManager manager;
  final int managerRevision;
  final int zoom;
  final MarkerClusterOptions options;

  const _ClusterCacheKey({
    required this.manager,
    required this.managerRevision,
    required this.zoom,
    required this.options,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _ClusterCacheKey &&
        other.manager == manager &&
        other.managerRevision == managerRevision &&
        other.zoom == zoom &&
        other.options == options;
  }

  @override
  int get hashCode => Object.hash(manager, managerRevision, zoom, options);
}
