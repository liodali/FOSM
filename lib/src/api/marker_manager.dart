import 'package:flutter/foundation.dart';

import 'marker.dart';
import 'marker_index.dart';

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
  /// Geographic index maintained incrementally by every mutation. The
  /// revision below tracks mutation count; the index is always consistent
  /// with the current revision. Internal — layers query it instead of
  /// scanning the whole collection each frame.
  final MarkerIndex _index = MarkerIndex();

  int _revision = 0;

  Marker? _overlayMarker;

  /// Monotonically increasing revision counter bumped on every mutation
  /// (including removals and clears). Used internally to invalidate
  /// cached cluster computations and to reason about [index] freshness.
  int get revision => _revision;

  /// The geographic index over the current markers. Internal.
  MarkerIndex get index => _index;

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

  /// The current markers, oldest first. Read-only view (an O(n) copy —
  /// prefer [index] for iteration-heavy internal work).
  List<Marker> get markers =>
      List.unmodifiable([for (final e in _index.entries) e.marker]);

  /// Number of markers currently managed.
  int get length => _index.length;

  bool get isEmpty => _index.isEmpty;

  bool get isNotEmpty => _index.isNotEmpty;

  /// Whether [marker] is present (identity comparison), without copying
  /// the collection.
  bool containsMarker(Marker marker) => _index.contains(marker);

  /// Adds a marker and notifies listeners.
  void add(Marker marker) {
    _index.insert(marker);
    _revision++;
    notifyListeners();
  }

  /// Adds all markers in [markers] (one notification).
  void addAll(Iterable<Marker> markers) {
    final list = markers.toList();
    if (list.isEmpty) return;
    _index.insertAll(list);
    _revision++;
    notifyListeners();
  }

  /// Removes [marker] (matched by identity, first occurrence). Returns
  /// whether it was found. Hides its overlay first if it was open.
  bool remove(Marker marker) {
    final removed = _index.remove(marker);
    if (removed) {
      _revision++;
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
    final removed = _index.removeWhere(test);
    if (removed > 0) {
      _revision++;
      if (overlayBefore != null && !_index.contains(overlayBefore)) {
        _hideOverlayIfOpen(overlayBefore);
      }
      notifyListeners();
    }
    return removed > 0;
  }

  /// Removes all markers and notifies listeners. Hides any open overlay.
  void clear() {
    if (_index.isEmpty) return;
    final overlay = _overlayMarker;
    if (overlay != null) _hideOverlayIfOpen(overlay);
    _index.clear();
    _revision++;
    notifyListeners();
  }

  // ── Overlay control ─────────────────────────────────────────────────

  /// Shows [marker]'s overlay ([Marker.overlayBuilder]), replacing any
  /// other open overlay. Returns `false` without side effects when the
  /// marker has no overlay builder or is not in this manager.
  bool showOverlay(Marker marker) {
    if (marker.overlayBuilder == null) return false;
    if (!_index.contains(marker)) return false;
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
