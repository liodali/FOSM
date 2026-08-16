import 'package:flutter/material.dart';

import 'geo_point.dart';

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

  const Marker({
    required this.point,
    required this.child,
    this.alignment = Alignment.center,
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
