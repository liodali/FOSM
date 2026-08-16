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
class MarkerManager extends ChangeNotifier {
  final List<Marker> _markers = [];

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
  bool remove(Marker marker) {
    final removed = _markers.remove(marker);
    if (removed) notifyListeners();
    return removed;
  }

  /// Removes every marker matching [test] (one notification if anything
  /// was removed). Returns whether at least one marker was removed.
  bool removeWhere(bool Function(Marker marker) test) {
    final before = _markers.length;
    _markers.removeWhere(test);
    final removed = _markers.length != before;
    if (removed) notifyListeners();
    return removed;
  }

  /// Removes all markers and notifies listeners.
  void clear() {
    if (_markers.isEmpty) return;
    _markers.clear();
    notifyListeners();
  }
}
