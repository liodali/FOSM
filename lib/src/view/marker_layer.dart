import 'package:flutter/material.dart';

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

class _MarkerLayerState extends State<MarkerLayer> {
  @override
  void initState() {
    super.initState();
    widget.markers.addListener(_onMarkersChanged);
  }

  @override
  void didUpdateWidget(MarkerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.markers != oldWidget.markers) {
      oldWidget.markers.removeListener(_onMarkersChanged);
      widget.markers.addListener(_onMarkersChanged);
    }
  }

  @override
  void dispose() {
    widget.markers.removeListener(_onMarkersChanged);
    super.dispose();
  }

  void _onMarkersChanged() {
    if (mounted) setState(() {});
  }

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

      children.add(
        Positioned(
          left: position.dx,
          top: position.dy,
          child: FractionalTranslation(
            translation: Offset(
              -(alignment.x + 1.0) / 2.0,
              -(alignment.y + 1.0) / 2.0,
            ),
            child: marker.child,
          ),
        ),
      );
    }

    return Stack(children: children);
  }

  /// Padding around the viewport that keeps partially visible markers
  /// from popping at the edges. One tile width covers typical pin and
  /// text marker sizes.
  static const double _cullMargin = 256.0;
}
