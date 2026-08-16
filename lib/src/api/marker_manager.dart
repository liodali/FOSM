import 'package:flutter/foundation.dart';

import 'marker.dart';

/// Owns the marker collection shown on a [MapView].
///
/// Pass an instance to `MapView(markers: …)` and mutate it at any time —
/// the map listens and re-renders; no `setState` needed in the host:
///
/// ```dart
/// final markers = MarkerManager();
///
/// MapView(
///   latLng: const LatLng(latitude: 47.4358, longitude: 8.4737),
///   zoom: 7,
///   markers: markers,
/// );
///
/// // Later — anywhere:
/// markers.add(Marker.text('Zurich', LatLng(latitude: 47.3769, longitude: 8.5417)));
/// ```
///
/// [Marker]s are compared by identity for [remove]; hold on to the
/// instances you plan to remove individually, or use [removeWhere].
///
/// ### Overlay
/// At most one marker's overlay ([Marker.overlayBuilder]) is visible at a
/// time. It is toggled by tapping the marker, or programmatically via
/// [showOverlay] / [hideOverlay]. [onOverlayShown] / [onOverlayHidden]
/// fire on every transition — including automatic dismissals
/// (`removeOnMove`, map tap) and marker removal.
class MarkerManager extends ChangeNotifier {
  final List<Marker> _markers = [];

  Marker? _overlayMarker;

  /// The marker whose overlay is currently visible, if any.
  Marker? get overlayMarker => _overlayMarker;

  /// Fired when a marker's overlay appears — via tap, [showOverlay], or
  /// switching from another marker's overlay.
  void Function(Marker marker)? onOverlayShown;

  /// Fired when the visible overlay disappears — via tap toggle,
  /// [hideOverlay], `removeOnMove`, map tap, or removal of its marker.
  /// When one overlay replaces another, this fires for the old marker
  /// before [onOverlayShown] fires for the new one.
  void Function(Marker marker)? onOverlayHidden;

  /// The current markers, oldest first. Read-only view.
  List<Marker> get markers => List.unmodifiable(_markers);

  /// Number of markers currently managed.
  int get length => _markers.length;

  bool get isEmpty => _markers.isEmpty;

  bool get isNotEmpty => _markers.isNotEmpty;

  /// Adds a marker and notifies listeners.
  void add(Marker marker) {
    _markers.add(marker);
    notifyListeners();
  }

  /// Adds all markers in [markers] (one notification).
  void addAll(Iterable<Marker> markers) {
    final list = markers.toList();
    if (list.isEmpty) return;
    _markers.addAll(list);
    notifyListeners();
  }

  /// Removes [marker] (matched by identity). Returns whether it was found.
  /// Hides its overlay first if it was open.
  bool remove(Marker marker) {
    final removed = _markers.remove(marker);
    if (removed) {
      _hideOverlayIfOpen(marker);
      notifyListeners();
    }
    return removed;
  }

  /// Removes every marker matching [test] (one notification if anything
  /// was removed). Returns whether at least one marker was removed.
  /// Hides the overlay if its marker was removed.
  bool removeWhere(bool Function(Marker marker) test) {
    final overlayBefore = _overlayMarker;
    final before = _markers.length;
    _markers.removeWhere(test);
    final removed = _markers.length != before;
    if (removed) {
      if (overlayBefore != null && !_markers.contains(overlayBefore)) {
        _hideOverlayIfOpen(overlayBefore);
      }
      notifyListeners();
    }
    return removed;
  }

  /// Removes all markers and notifies listeners. Hides any open overlay.
  void clear() {
    if (_markers.isEmpty) return;
    final overlay = _overlayMarker;
    if (overlay != null) _hideOverlayIfOpen(overlay);
    _markers.clear();
    notifyListeners();
  }

  // ── Overlay control ─────────────────────────────────────────────────

  /// Shows [marker]'s overlay ([Marker.overlayBuilder]), replacing any
  /// other open overlay. Returns `false` without side effects when the
  /// marker has no overlay builder or is not in this manager.
  bool showOverlay(Marker marker) {
    if (marker.overlayBuilder == null) return false;
    if (!_markers.contains(marker)) return false;
    if (_overlayMarker == marker) return true;

    final previous = _overlayMarker;
    _overlayMarker = marker;
    if (previous != null) onOverlayHidden?.call(previous);
    onOverlayShown?.call(marker);
    notifyListeners();
    return true;
  }

  /// Hides the open overlay, if any. Returns whether one was open.
  bool hideOverlay() {
    final marker = _overlayMarker;
    if (marker == null) return false;
    _hideOverlayIfOpen(marker);
    notifyListeners();
    return true;
  }

  void _hideOverlayIfOpen(Marker marker) {
    if (_overlayMarker != marker) return;
    _overlayMarker = null;
    onOverlayHidden?.call(marker);
  }
}
