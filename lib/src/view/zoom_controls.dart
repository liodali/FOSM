import 'package:flutter/material.dart';

/// Floating zoom controls overlay (+/− buttons).
///
/// Styled after Google Maps: semi-transparent white background,
/// rounded corners, subtle shadow. Disabled buttons are grayed out.
///
/// ### Usage
/// ```dart
/// Stack(
///   children: [
///     MapView(...),
///     MapZoomControls(
///       zoom: 7,
///       minZoom: 1,
///       maxZoom: 19,
///       onZoomIn: () => zoomIn(),
///       onZoomOut: () => zoomOut(),
///     ),
///   ],
/// )
/// ```
///
/// Or just pass `showZoomControls: true` to [MapView] and it handles
/// everything automatically.
class MapZoomControls extends StatelessWidget {
  /// Current zoom level.
  final int zoom;

  /// Minimum allowed zoom.
  final int minZoom;

  /// Maximum allowed zoom.
  final int maxZoom;

  /// Called when the user taps the + button.
  final VoidCallback onZoomIn;

  /// Called when the user taps the − button.
  final VoidCallback onZoomOut;

  /// Position of the controls on the map.
  final Alignment alignment;

  const MapZoomControls({
    super.key,
    required this.zoom,
    required this.minZoom,
    required this.maxZoom,
    required this.onZoomIn,
    required this.onZoomOut,
    this.alignment = Alignment.bottomRight,
  });

  @override
  Widget build(BuildContext context) {
    final atMin = zoom <= minZoom;
    final atMax = zoom >= maxZoom;

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Zoom in button
              SizedBox(
                width: 44,
                height: 44,
                child: InkWell(
                  onTap: atMax ? null : onZoomIn,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8),
                  ),
                  child: Icon(
                    Icons.add,
                    size: 24,
                    color: atMax ? Colors.grey[400] : Colors.grey[800],
                  ),
                ),
              ),
              // Divider
              Container(
                height: 1,
                width: 32,
                color: Colors.grey[300],
              ),
              // Zoom out button
              SizedBox(
                width: 44,
                height: 44,
                child: InkWell(
                  onTap: atMin ? null : onZoomOut,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(8),
                  ),
                  child: Icon(
                    Icons.remove,
                    size: 24,
                    color: atMin ? Colors.grey[400] : Colors.grey[800],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
