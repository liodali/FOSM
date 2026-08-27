import 'package:flutter/material.dart';

import '../api/geo_point.dart';
import '../api/map_controller.dart';
import '../api/map_notification.dart';
import '../api/marker.dart';
import '../api/marker_cluster.dart';

/// Mixin for parent [State]s that want to react to map events.
///
/// Wrap the [MapView] with [listenToMap] and override the hooks you care
/// about:
///
/// ```dart
/// class _MyPageState extends State<MyPage> with MapEventListenerMixin {
///   @override
///   Widget build(BuildContext context) {
///     return listenToMap(
///       MapView(
///         latLng: initialCenter,
///         zoom: 7,
///       ),
///     );
///   }
///
///   @override
///   void onMapMarkerTapped(Marker marker) {
///     debugPrint('Tapped ${marker.point}');
///   }
/// }
/// ```
///
/// Notifications bubble, so you can also nest multiple listeners at
/// different levels of the tree.
mixin MapEventListenerMixin<T extends StatefulWidget> on State<T> {
  /// Wraps [child] with a [NotificationListener] that forwards map
  /// notifications to the mixin hooks.
  Widget listenToMap(Widget child) {
    return NotificationListener<MapNotification>(
      onNotification: _handleMapNotification,
      child: child,
    );
  }

  bool _handleMapNotification(MapNotification notification) {
    switch (notification) {
      case MapReadyNotification(:final controller):
        onMapReady(controller);
      case MapCameraChangeNotification(:final center, :final zoom):
        onMapCameraChanged(center, zoom);
      case MapZoomChangeNotification(:final zoom):
        onMapZoomChanged(zoom);
      case MapMarkerTapNotification(:final marker):
        onMapMarkerTapped(marker);
      case MapMarkerLongPressNotification(:final marker):
        onMapMarkerLongPressed(marker);
      case MapMarkerClusterTapNotification(:final cluster):
        onMapMarkerClusterTapped(cluster);
      case MapOverlayShownNotification(:final marker):
        onMapOverlayShown(marker);
      case MapOverlayHiddenNotification(:final marker):
        onMapOverlayHidden(marker);
    }
    return false;
  }

  /// Called once after the map grid is laid out and the controller is
  /// attached.
  void onMapReady(MapController controller) {}

  /// Called whenever the map camera changes (pan or zoom).
  void onMapCameraChanged(LatLng center, int zoom) {}

  /// Called when the zoom level changes.
  void onMapZoomChanged(int zoom) {}

  /// Called when a marker is tapped.
  void onMapMarkerTapped(Marker marker) {}

  /// Called when a marker is long-pressed.
  void onMapMarkerLongPressed(Marker marker) {}

  /// Called when a generated marker cluster is tapped.
  void onMapMarkerClusterTapped(MarkerCluster cluster) {}

  /// Called when a marker's overlay is shown.
  void onMapOverlayShown(Marker marker) {}

  /// Called when a marker's overlay is hidden.
  void onMapOverlayHidden(Marker marker) {}
}
