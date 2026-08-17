import 'package:flutter/material.dart';

import 'geo_point.dart';

/// Which side of the marker widget an overlay is anchored to.
enum MarkerOverlayAnchor {
  /// Overlay floats above the marker (its bottom edge faces the marker).
  above,

  /// Overlay hangs below the marker (its top edge faces the marker).
  below,

  /// Overlay is centered on the marker — replaces it visually.
  center,
}

/// Behavior of the overlay shown when a [Marker] with [Marker.overlayBuilder]
/// is tapped.
///
/// Defaults follow the "follow the marker" style: the overlay stays anchored
/// while the camera pans and zooms. Set [removeOnMove] to dismiss it as soon
/// as the camera changes instead.
///
/// ```dart
/// const MarkerOverlayConfig(
///   removeOnMove: true,
///   anchor: MarkerOverlayAnchor.below,
///   offset: Offset(0, 12),
/// )
/// ```
class MarkerOverlayConfig {
  /// Dismiss the overlay as soon as the camera changes — any pan, zoom or
  /// programmatic move. When `false` (default) the overlay follows its
  /// marker across camera changes.
  final bool removeOnMove;

  /// Dismiss the overlay when the user taps the bare map (default) or a
  /// different marker that has no overlay. Taps inside the overlay itself
  /// never dismiss it.
  final bool closeOnMapTap;

  /// Which side of the marker widget the overlay sits on.
  final MarkerOverlayAnchor anchor;

  /// Extra gap between the marker and the overlay, in logical pixels.
  /// Applied along the [anchor] direction — `dy` for [MarkerOverlayAnchor.above]
  /// / [MarkerOverlayAnchor.below], both axes for
  /// [MarkerOverlayAnchor.center]. Defaults to 8 px.
  final Offset offset;

  /// Entrance animation (fade + scale) duration. [Duration.zero] shows the
  /// overlay instantly.
  final Duration animationDuration;

  const MarkerOverlayConfig({
    this.removeOnMove = false,
    this.closeOnMapTap = true,
    this.anchor = MarkerOverlayAnchor.above,
    this.offset = const Offset(0, 8),
    this.animationDuration = const Duration(milliseconds: 200),
  });
}

/// A widget anchored to a geographic position on the map.
///
/// The [child] can be any Flutter widget — an icon pin, a badge, a button,
/// anything. [alignment] picks which point of the child sits exactly on
/// [point]: a pin icon whose tip is at the bottom of the asset wants
/// [Alignment.bottomCenter], text usually looks best centered.
///
/// ```dart
/// const Marker(
///   point: LatLng(latitude: 47.4358, longitude: 8.4737),
///   alignment: Alignment.bottomCenter,
///   child: Icon(Icons.location_on, size: 40, color: Colors.red),
/// );
/// ```
///
/// ### Gestures
/// Set [onTap] / [onLongPress] to make the marker interactive. Panning the
/// map by dragging a marker still works — the gesture arena only resolves
/// to the marker when the finger doesn't move. Interactive markers (and
/// those with [overlayBuilder]) show a hand cursor on pointer devices.
///
/// ### Overlay
/// Give the marker an [overlayBuilder] and it gains a tap-to-toggle overlay
/// (an "info window"): any Flutter widget, anchored to the marker and
/// following it across pans and zooms. Behavior is shaped by
/// [overlayConfig]; the [MarkerManager] also exposes programmatic control
/// ([MarkerManager.showOverlay] / [MarkerManager.hideOverlay]) and
/// [MarkerManager.onOverlayShown] / [MarkerManager.onOverlayHidden]
/// listeners. Only one overlay is visible at a time.
///
/// Markers are added to a [MarkerManager] which is passed to [MapView];
/// they render above the tile grid (and below vector labels) and track
/// the camera on every pan and zoom.
class Marker {
  /// Geographic anchor of the marker.
  final LatLng point;

  /// The widget rendered at [point].
  final Widget child;

  /// Which point of [child] is pinned to [point]. Defaults to the widget's
  /// center. For pin icons use [Alignment.bottomCenter] so the tip lands
  /// on the coordinate.
  final Alignment alignment;

  /// Called when the marker is tapped. Fires alongside the overlay toggle
  /// when [overlayBuilder] is also set.
  final VoidCallback? onTap;

  /// Called when the marker is long-pressed.
  final VoidCallback? onLongPress;

  /// Overlay widget shown when the marker is tapped. Set this to opt into
  /// the built-in tap-to-toggle overlay; leave it null for callback-only
  /// markers.
  final WidgetBuilder? overlayBuilder;

  /// How the overlay from [overlayBuilder] behaves.
  final MarkerOverlayConfig overlayConfig;

  /// Whether this marker participates in the overlay system — either as a
  /// tap-to-toggle marker ([overlayBuilder] set) or as a bare-map-tap-like
  /// dismiss target when another marker's overlay is open.
  bool get hasOverlay => overlayBuilder != null;

  const Marker({
    required this.point,
    required this.child,
    this.alignment = Alignment.center,
    this.onTap,
    this.onLongPress,
    this.overlayBuilder,
    this.overlayConfig = const MarkerOverlayConfig(),
  });

  /// Convenience constructor for a plain text marker.
  ///
  /// ```dart
  /// Marker.text('Hello', LatLng(latitude: 47.4358, longitude: 8.4737));
  /// ```
  factory Marker.text(
    String text,
    LatLng point, {
    TextStyle? style,
    Alignment alignment = Alignment.center,
  }) {
    return Marker(
      point: point,
      alignment: alignment,
      child: Text(text, style: style),
    );
  }
}
