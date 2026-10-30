import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show EdgeInsets;

import '../common/memory_attribution.dart';
import '../common/tile_coverage.dart';
import 'geo_point.dart';
import 'lat_lng_bounds.dart';
import 'map_load_state.dart';
import 'marker.dart';
import 'marker_manager.dart';
import 'map_location_controller.dart';

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

/// Optional continuous-zoom capability implemented by MapView.
abstract class FractionalMapControllerDelegate {
  double get fractionalZoom;
  void setFractionalZoom(double zoom, {bool animate = true});
}

/// Optional location-following capability; existing delegates stay compatible.
abstract class LocationMapControllerDelegate {
  MapLocationController? get locationController;
}

/// Optional memory-attribution capability implemented by MapView.
///
/// Exposes the retained-memory buckets of the attached map (rendered
/// images, compressed bytes, parsed vector data, labels, geometry) for
/// workload captures and long-session memory measurement.
abstract class MapMemoryDelegate {
  /// Point-in-time attribution of the attached map's retained memory.
  FosmMemoryAttribution get memoryAttribution;
}

/// Exposes the strict-viewport coverage of the attached map for workload
/// captures: which visible cells published imagery and which show their
/// own current-zoom (sharp) image.
abstract class MapCoverageDelegate {
  /// Point-in-time coverage of the attached map's strict viewport.
  FosmTileCoverage get tileCoverage;
}

/// Optional workload-capture capability implemented by MapView: cache-state
/// control and loading attribution for measurement harnesses.
abstract class MapWorkloadDelegate {
  /// Drops the rebuildable in-memory tile caches: the compressed byte cache
  /// and rendered images not protected by the live grid. The persistent
  /// disk cache, parsed vector tiles, prepared labels, load state and
  /// failure tracking survive, so the next frames re-render from warm
  /// parsed data and disk bytes.
  void dropRebuildableCaches({bool includeVisibleImages = false});

  /// Current loading progress for the attached map's viewport, or `null`
  /// when detached. Failures listed here declare unreachable coverage
  /// (failed requests) instead of silently missing tiles.
  MapLoadState? get loadState;

  /// Logical tiles (`z/x/y`) whose label preparation completed for the
  /// attached vector map, including tiles that prepared successfully
  /// with zero labels. Empty in raster mode; an empty set for a detached
  /// map.
  Set<String> get labelPreparedTileKeys;
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

  /// Display zoom, including its fractional component; null when detached.
  double? get fractionalZoom {
    final delegate = _delegate;
    return delegate is FractionalMapControllerDelegate
        ? (delegate as FractionalMapControllerDelegate).fractionalZoom
        : delegate?.zoom.toDouble();
  }

  /// Sets a continuous zoom. MapView clamps to its min/max zoom limits.
  /// Legacy delegates receive the nearest integer zoom instead.
  void setFractionalZoom(double zoom, {bool animate = true}) {
    if (!zoom.isFinite) {
      throw ArgumentError.value(zoom, 'zoom', 'must be finite');
    }
    final delegate = _delegate;
    if (delegate is FractionalMapControllerDelegate) {
      (delegate as FractionalMapControllerDelegate)
          .setFractionalZoom(zoom, animate: animate);
    } else {
      delegate?.setZoom(zoom.round(), animate: animate);
    }
  }

  MapLocationController? get _locations {
    final delegate = _delegate;
    return delegate is LocationMapControllerDelegate
        ? (delegate as LocationMapControllerDelegate).locationController
        : null;
  }

  /// Point-in-time attribution of the attached map's retained memory
  /// (rendered images, compressed bytes, parsed vector data, labels,
  /// geometry), or `null` when detached.
  ///
  /// Read periodically during captured workloads to observe which bucket
  /// grows; see [FosmMemoryAttribution] for what each bucket counts.
  FosmMemoryAttribution? get memoryAttribution {
    final delegate = _delegate;
    return delegate is MapMemoryDelegate
        ? (delegate as MapMemoryDelegate).memoryAttribution
        : null;
  }

  /// Point-in-time strict-viewport coverage of the attached map, or
  /// `null` when detached.
  ///
  /// Sample per frame during captured workloads to record time to
  /// first/all covered cells, sharp-coverage time and blank fraction
  /// over time; see [FosmTileCoverage] for what each counter means.
  FosmTileCoverage? get tileCoverage {
    final delegate = _delegate;
    return delegate is MapCoverageDelegate
        ? (delegate as MapCoverageDelegate).tileCoverage
        : null;
  }

  /// Drops the attached map's rebuildable in-memory tile caches (compressed
  /// bytes and non-protected rendered images) while keeping the disk cache,
  /// parsed vector tiles and prepared labels — a no-op when detached or
  /// when the map does not support it.
  ///
  /// Workload harnesses use this to measure a warm-parsed/cold-images
  /// render pass; the equivalent user-visible trigger is a system
  /// memory-pressure notification for the default mode.
  ///
  /// Set [includeVisibleImages] only for a settled workload capture. This
  /// releases fallback/snapshot pins and reloads visible imagery while
  /// preserving parsed vector data. Active presentations cause StateError.
  void dropRebuildableCaches({bool includeVisibleImages = false}) {
    final delegate = _delegate;
    if (delegate is MapWorkloadDelegate) {
      (delegate as MapWorkloadDelegate)
          .dropRebuildableCaches(includeVisibleImages: includeVisibleImages);
    }
  }

  /// Point-in-time loading progress for the attached map's viewport
  /// (including tile failures), or `null` when detached.
  MapLoadState? get loadState {
    final delegate = _delegate;
    return delegate is MapWorkloadDelegate
        ? (delegate as MapWorkloadDelegate).loadState
        : null;
  }

  /// Logical tiles (`z/x/y`) whose label preparation completed for the
  /// attached vector map — including tiles that prepared successfully
  /// with zero labels — or an empty set when detached or in raster mode.
  ///
  /// Workload harnesses use this to prove label readiness for a viewport
  /// (every sharp cell's tile present) instead of relying on stable
  /// prepared counts, which a temporarily empty preparation queue can
  /// satisfy while other visible tiles have not queued their work yet.
  Set<String> get labelPreparedTileKeys {
    final delegate = _delegate;
    return delegate is MapWorkloadDelegate
        ? (delegate as MapWorkloadDelegate).labelPreparedTileKeys
        : const <String>{};
  }

  /// Follow/recenter on the latest supplied location; waits if no fix exists.
  void followLocation() => _locations?.follow();

  void pauseLocationFollowing() => _locations?.pause();
  void stopLocationFollowing() => _locations?.stop();
  MapLocationFollowState? get locationFollowState => _locations?.state;

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
  /// afterwards the user can pan away freely. Continuous cameras choose
  /// a fractional display zoom; legacy cameras choose an integer zoom.
  /// Both respect min/max zoom: if the bounds cannot fit at minZoom,
  /// the view centers on them but their edges may be clipped.
  /// A no-op when the controller is detached.
  void fitBounds(
    LatLngBounds bounds, {
    EdgeInsets padding = EdgeInsets.zero,
    bool animate = true,
  }) =>
      _delegate?.fitBounds(bounds, padding: padding, animate: animate);
}
