import 'dart:async';

enum TileFailureKind { timeout, http, network, decode, style, cancelled }

/// A transport or rendering failure. Built-in messages omit request URLs
/// and credentials; applications may also supply their own [message].
class TileLoadException implements Exception {
  const TileLoadException(this.kind, this.message, {this.statusCode});

  static const Duration defaultRequestTimeout = Duration(seconds: 30);
  final TileFailureKind kind;
  final String message;
  final int? statusCode;

  bool get isRetryable => switch (kind) {
        TileFailureKind.cancelled || TileFailureKind.style => false,
        TileFailureKind.http => statusCode == 408 ||
            statusCode == 429 ||
            (statusCode != null && statusCode! >= 500),
        _ => true,
      };

  static TileLoadException from(Object error,
      {TileFailureKind fallback = TileFailureKind.network}) {
    if (error is TileLoadException) return error;
    if (error is TimeoutException) {
      return const TileLoadException(
          TileFailureKind.timeout, 'Map request timed out');
    }
    return TileLoadException(
        fallback,
        switch (fallback) {
          TileFailureKind.decode => 'Unable to render map tile',
          TileFailureKind.style => 'Unable to load map style',
          _ => 'Unable to download map data',
        });
  }

  @override
  String toString() => 'TileLoadException(${kind.name}, $message'
      '${statusCode == null ? '' : ', HTTP $statusCode'})';
}

void validateRequestTimeout(Duration timeout) {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'requestTimeout', 'must be positive');
  }
}

class MapTileFailure {
  const MapTileFailure(
      {required this.zoom,
      required this.x,
      required this.y,
      required this.error});
  final int zoom;
  final int x;
  final int y;
  final TileLoadException error;
}

enum MapLoadingStage { style, tiles }

/// Loading progress for the current viewport, excluding padding/preloads.
class MapLoadState {
  MapLoadState({
    this.stage = MapLoadingStage.tiles,
    this.totalTiles = 0,
    this.loadedTiles = 0,
    this.loadingTiles = 0,
    List<MapTileFailure> failures = const [],
    this.styleError,
  }) : failures = List.unmodifiable(failures);

  final MapLoadingStage stage;
  final int totalTiles;
  final int loadedTiles;
  final int loadingTiles;
  final List<MapTileFailure> failures;
  final TileLoadException? styleError;
  int get failedTiles => failures.length;
  TileLoadException? get error =>
      styleError ?? (failures.isEmpty ? null : failures.first.error);
  bool get hasError => error != null;
  bool get isLoading =>
      stage == MapLoadingStage.style ? styleError == null : loadingTiles > 0;
}
