import 'dart:async';

import 'package:flutter/foundation.dart';

import 'map_location.dart';

/// [waiting] and [following] express follow intent. Panning changes it to
/// [paused]; [off] means following was never requested or explicitly stopped.
enum MapLocationFollowState { off, waiting, following, paused }

/// Owns a location-stream subscription and follow intent independently of a
/// MapView's lifecycle. The host owns/disposes this controller and supplies
/// positions after handling its provider's permission and service state.
class MapLocationController extends ChangeNotifier {
  MapLocationController({Stream<MapLocation>? locations, bool follow = false})
      : _followingRequested = follow {
    if (locations != null) setStream(locations);
  }

  MapLocation? _location;
  DateTime? _lastTimestamp;
  Object? _error;
  bool _followingRequested;
  bool _paused = false;
  bool _disposed = false;
  bool _streamActive = false;
  int _sourceGeneration = 0;
  int _followRevision = 0;
  StreamSubscription<MapLocation>? _subscription;

  MapLocation? get location => _location;
  Object? get error => _error;
  bool get isStreamActive => _streamActive;
  bool get isFollowing => _followingRequested;

  MapLocationFollowState get state => _followingRequested
      ? (_location == null
          ? MapLocationFollowState.waiting
          : MapLocationFollowState.following)
      : (_paused ? MapLocationFollowState.paused : MapLocationFollowState.off);

  /// Changes only when a new camera target or an explicit recenter is needed.
  /// Accuracy/bearing-only updates repaint the location without restarting pan.
  int get followRevision => _followRevision;

  void _checkAlive() {
    if (_disposed) throw StateError('MapLocationController is disposed');
  }

  /// Accepts a valid fix; returns false for an older timestamp. Coordinates
  /// use physical latitude [-90,90]; MapView clamps poles to Web Mercator.
  /// Invalid direct calls throw. Invalid stream samples populate [error] and
  /// leave the last valid location intact; the stream remains subscribed.
  bool updateLocation(MapLocation value) {
    _checkAlive();
    if (!value.isValid) {
      throw ArgumentError.value(
          value, 'location', 'invalid coordinates, accuracy or bearing');
    }
    final previous = _location;
    if (_lastTimestamp != null &&
        value.timestamp != null &&
        value.timestamp!.isBefore(_lastTimestamp!)) {
      return false;
    }
    if (previous == null || previous.point != value.point || _error != null) {
      _followRevision++;
    }
    _location = value;
    if (value.timestamp != null) _lastTimestamp = value.timestamp;
    _error = null;
    notifyListeners();
    return true;
  }

  /// Request/restart following and recenter on the newest fix, even when
  /// already following. With no fix, waits for the next accepted position.
  void follow() {
    _checkAlive();
    _followingRequested = true;
    _paused = false;
    _followRevision++;
    notifyListeners();
  }

  /// Pause until [follow] is called. New fixes still update the position dot.
  void pause() {
    _checkAlive();
    if (!_followingRequested) return;
    _followingRequested = false;
    _paused = true;
    notifyListeners();
  }

  void stop() {
    _checkAlive();
    if (!_followingRequested && !_paused) return;
    _followingRequested = false;
    _paused = false;
    notifyListeners();
  }

  /// Removes a stale/unauthorized fix. Follow intent is retained as [waiting].
  void clearLocation() {
    _checkAlive();
    _location = null;
    _lastTimestamp = null;
    _error = null;
    _followRevision++;
    notifyListeners();
  }

  /// Replaces/cancels the owned stream while retaining the last valid fix and
  /// follow intent. Call [clearLocation] too when a fix must no longer show.
  /// Late events from replaced sources are ignored, even if cancellation is
  /// asynchronous. Stream errors are recoverable; completion only marks the
  /// source inactive and retains the last location.
  void setStream(Stream<MapLocation>? source) {
    _checkAlive();
    final generation = ++_sourceGeneration;
    _cancel(_subscription);
    _subscription = null;
    _streamActive = source != null;
    _error = null;
    if (source != null) {
      try {
        final subscription = source.listen((value) {
          if (_disposed || generation != _sourceGeneration) return;
          try {
            updateLocation(value);
          } catch (error) {
            _recordError(error);
          }
        }, onError: (Object error, StackTrace stack) {
          if (!_disposed && generation == _sourceGeneration) {
            _recordError(error);
          }
        }, onDone: () {
          if (_disposed || generation != _sourceGeneration) return;
          _streamActive = false;
          _subscription = null;
          notifyListeners();
        });
        if (!_disposed && generation == _sourceGeneration && _streamActive) {
          _subscription = subscription;
        } else {
          _cancel(subscription);
        }
      } catch (error) {
        _streamActive = false;
        _recordError(error);
      }
    }
    notifyListeners();
  }

  void _recordError(Object error) {
    _error = error;
    notifyListeners();
  }

  // Cancellation may finish after disposal. Its failure cannot be delivered
  // to a disposed notifier or allowed to escape as an unhandled async error.
  void _cancel(StreamSubscription<MapLocation>? subscription) {
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sourceGeneration++;
    _cancel(_subscription);
    _subscription = null;
    _streamActive = false;
    super.dispose();
  }
}
