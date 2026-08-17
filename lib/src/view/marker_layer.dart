import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/scheduler.dart';

import '../api/marker.dart';
import '../api/marker_manager.dart';
import '../api/tile_manager.dart';

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

  const MarkerLayer({
    super.key,
    required this.markers,
    required this.manager,
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

  /// Camera snapshot used to detect movement between parent rebuilds.
  ({double lng, double lat, int zoom})? _lastCamera;

  /// Measured sizes of overlay-capable markers, keyed by identity. The
  /// overlay anchors to the marker widget's edge, which requires its size.
  final Map<Marker, Size> _markerSizes = {};

  @override
  void initState() {
    super.initState();
    _overlayController = AnimationController(vsync: this, value: 1.0);
    _overlayController.addListener(_onOverlayTick);
    widget.markers.addListener(_onMarkersChanged);
    _snapshotCamera();
  }

  @override
  void didUpdateWidget(MarkerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.markers != oldWidget.markers) {
      oldWidget.markers.removeListener(_onMarkersChanged);
      widget.markers.addListener(_onMarkersChanged);
      _syncOverlayAnimation();
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

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final children = <Widget>[];

    for (final marker in widget.markers.markers) {
      final position = manager.latLngToScreen(marker.point);

      // Viewport culling: markers whose anchor is off-screen (beyond the
      // margin that lets wide/tall widgets stay visible while partially
      // on screen) are skipped entirely — not built, laid out or painted.
      final visible =
          position.dx >= -_cullMargin &&
          position.dy >= -_cullMargin &&
          position.dx <= manager.width + _cullMargin &&
          position.dy <= manager.height + _cullMargin;
      if (!visible) continue;

      // FractionalTranslation shifts by a fraction of the child's own
      // size, so the anchor works without knowing the widget's
      // dimensions: center → (-0.5, -0.5), bottomCenter → (-0.5, -1.0), …
      final alignment = marker.alignment;

      var child = _buildMarkerChild(marker);

      children.add(
        Positioned(
          left: position.dx,
          top: position.dy,
          child: FractionalTranslation(
            translation: Offset(
              -(alignment.x + 1.0) / 2.0,
              -(alignment.y + 1.0) / 2.0,
            ),
            child: child,
          ),
        ),
      );
    }

    // Overlay paints above all markers (later Stack child).
    final overlay = _buildOverlay(manager);
    if (overlay != null) children.add(overlay);

    return Stack(children: children);
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
        onLongPress:
            marker.onLongPress != null ? () => marker.onLongPress!() : null,
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

  /// Builds the visible overlay, or null. Anchored to the marker widget
  /// (via its measured size) at the configured side and offset, and
  /// repositioned on every rebuild — which happens on each pan/zoom frame.
  Widget? _buildOverlay(TileManager manager) {
    final marker = widget.markers.overlayMarker;
    final builder = marker?.overlayBuilder;
    if (marker == null || builder == null) return null;

    final position = manager.latLngToScreen(marker.point);
    final visible =
        position.dx >= -_cullMargin &&
        position.dy >= -_cullMargin &&
        position.dx <= manager.width + _cullMargin &&
        position.dy <= manager.height + _cullMargin;
    if (!visible) return null;

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
                Offset(
                    size.width / 2 + config.offset.dx, -config.offset.dy)
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
