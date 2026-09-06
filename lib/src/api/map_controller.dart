import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show EdgeInsets;

import 'geo_point.dart';
import 'lat_lng_bounds.dart';
import 'marker.dart';
import 'marker_manager.dart';

/// Delegate implemented by [MapView] state.
///
/// This is an internal contract between [MapController] and [MapView].
/// Hosts should not implement this directly; create a [MapController]
/// and pass it to [MapView.controller].
abstract class MapControllerDelegate {
  /// Current map center, or the widget's initial center before the grid
  /// has been laid out.
  LatLng get center;

  /// Current zoom level, or the widget's initial zoom before the grid
  /// has been laid out.
  int get zoom;

  /// Sets the zoom level, optionally animating the transition.
  void setZoom(int zoom, {bool animate});

  /// Zooms in ([delta] > 0) or out ([delta] < 0) by the given number of
  /// levels, optionally animating the transition.
  void zoomBy(int delta, {bool animate});

  /// Moves the camera to [latLng], optionally animating the pan.
  void moveTo(LatLng latLng, {bool animate});

  /// Navigates the camera so [bounds] fits the viewport (minus
  /// [padding]), without constraining the camera afterwards.
  void fitBounds(LatLngBounds bounds, {EdgeInsets padding, bool animate});

  /// The marker manager attached to the map, if any.
  MarkerManager? get markerManager;
}

/// Programmatic control surface for a [MapView].
///
/// Create a controller outside the widget tree, pass it to [MapView],
/// then call its methods from buttons, streams, or business logic:
///
/// ```dart
/// final mapController = MapController();
///
/// MapView(
///   controller: mapController,
///   latLng: initialCenter,
///   zoom: 7,
///   markers: markerManager,
/// )
///
/// // Elsewhere:
/// mapController.moveTo(newCenter, animate: true);
/// mapController.zoomIn();
/// mapController.addMarker(Marker(...));
/// ```
///
/// The controller is a [ChangeNotifier]. Listening to it lets a host
/// rebuild when the controller attaches to or detaches from a map
/// (for example, across raster/vector mode switches that give the map
/// a new key).
class MapController extends ChangeNotifier {
  MapControllerDelegate? _delegate;

  /// Whether this controller is currently attached to a [MapView].
  bool get isAttached => _delegate != null;

  /// The current map center, or `null` when not attached.
  LatLng? get center => _delegate?.center;

  /// The current zoom level, or `null` when not attached.
  int? get zoom => _delegate?.zoom;

  /// Attaches the controller to a map state.
  ///
  /// Called by [MapView] in [State.initState]. Host code should not call
  /// this directly.
  void attach(MapControllerDelegate delegate) {
    if (_delegate == delegate) return;
    _delegate = delegate;
    notifyListeners();
  }

  /// Detaches the controller from the map state.
  ///
  /// Called by [MapView] in [State.dispose]. Host code should not call
  /// this directly. Only detaches if [delegate] is the currently attached
  /// delegate, preventing a stale dispose from clobbering a newer attach.
  void detach(MapControllerDelegate delegate) {
    if (_delegate != delegate) return;
    _delegate = null;
    notifyListeners();
  }

  /// Adds [marker] to the map's [MarkerManager].
  ///
  /// No-op when the map has no marker manager. Use [removeMarker] with
  /// the same instance to remove it later.
  void addMarker(Marker marker) => _delegate?.markerManager?.add(marker);

  /// Removes [marker] (matched by identity) from the map's
  /// [MarkerManager].
  bool removeMarker(Marker marker) =>
      _delegate?.markerManager?.remove(marker) ?? false;

  /// Removes all markers from the map's [MarkerManager].
  void clearMarkers() => _delegate?.markerManager?.clear();

  /// Sets the zoom level, clamped to the map's min/max zoom.
  ///
  /// [animate] overrides [MapView.animateZoom] for this call. When
  /// `false`, the zoom changes instantly.
  void setZoom(int zoom, {bool animate = true}) =>
      _delegate?.setZoom(zoom, animate: animate);

  /// Zooms in by one level.
  void zoomIn({bool animate = true}) => _delegate?.zoomBy(1, animate: animate);

  /// Zooms out by one level.
  void zoomOut({bool animate = true}) =>
      _delegate?.zoomBy(-1, animate: animate);

  /// Moves the camera to [latLng].
  ///
  /// [animate] overrides [MapView.animateZoom] for this call. When
  /// `false`, the camera jumps instantly.
  void moveTo(LatLng latLng, {bool animate = true}) =>
      _delegate?.moveTo(latLng, animate: animate);

  /// Frames [bounds] in the viewport (minus [padding]).
  ///
  /// Unlike [MapView.cameraBounds], this only navigates the camera —
  /// afterwards the user can pan away freely. The resulting zoom is an
  /// integer clamped to the map's min/max zoom, so the box is fully
  /// visible subject to the configured minZoom: if the bounds cannot fit
  /// at minZoom, the view centers on them but their edges may be clipped.
  /// A no-op when the controller is detached.
  void fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    bool animate = true,
  }) =>
      _delegate?.fitBounds(bounds, padding: padding, animate: animate);
}
