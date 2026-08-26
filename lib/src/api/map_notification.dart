import 'package:flutter/material.dart';

import 'geo_point.dart';
import 'map_controller.dart';
import 'marker.dart';

/// Base class for notifications dispatched by [MapView].
///
/// All map notifications bubble up the widget tree, so any ancestor can
/// listen with [NotificationListener] or via [MapEventListenerMixin].
sealed class MapNotification extends Notification {
  const MapNotification();
}

/// Dispatched once after the map grid is first laid out and the
/// [MapController] is attached.
class MapReadyNotification extends MapNotification {
  /// The controller for the map that just became ready.
  final MapController controller;

  const MapReadyNotification(this.controller);
}

/// Dispatched whenever the camera center or zoom changes.
class MapCameraChangeNotification extends MapNotification {
  /// The new geographic center.
  final LatLng center;

  /// The new integer zoom level.
  final int zoom;

  const MapCameraChangeNotification(this.center, this.zoom);
}

/// Dispatched when the zoom level changes.
///
/// This is a subset of [MapCameraChangeNotification] for hosts that only
/// care about zoom.
class MapZoomChangeNotification extends MapNotification {
  /// The new integer zoom level.
  final int zoom;

  const MapZoomChangeNotification(this.zoom);
}

/// Dispatched when a marker is tapped.
class MapMarkerTapNotification extends MapNotification {
  /// The marker that was tapped.
  final Marker marker;

  const MapMarkerTapNotification(this.marker);
}

/// Dispatched when a marker is long-pressed.
class MapMarkerLongPressNotification extends MapNotification {
  /// The marker that was long-pressed.
  final Marker marker;

  const MapMarkerLongPressNotification(this.marker);
}

/// Dispatched when a marker's overlay is shown.
class MapOverlayShownNotification extends MapNotification {
  /// The marker whose overlay became visible.
  final Marker marker;

  const MapOverlayShownNotification(this.marker);
}

/// Dispatched when a marker's overlay is hidden.
class MapOverlayHiddenNotification extends MapNotification {
  /// The marker whose overlay was dismissed.
  final Marker marker;

  const MapOverlayHiddenNotification(this.marker);
}
