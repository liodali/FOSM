import 'dart:math' as math;

import '../api/geo_point.dart';
import '../api/marker_cluster.dart';
import '../api/marker_manager.dart';
import '../common/osm_transformation_utilities.dart';

/// Render item produced by the clustering engine.
sealed class ClusterRenderItem {
  const ClusterRenderItem();
}

/// A single [ClusterMarker] that should render normally.
class SingleClusterMarkerItem extends ClusterRenderItem {
  final ClusterMarker marker;

  const SingleClusterMarkerItem(this.marker);
}

/// A generated cluster that should render as a badge.
class ClusterGroupItem extends ClusterRenderItem {
  final MarkerCluster cluster;

  const ClusterGroupItem(this.cluster);
}

/// Pure, camera-independent clustering engine.
///
/// The engine groups [ClusterMarker]s by [ClusterMarker.clusterGroup] using
/// world-pixel coordinates at the current integer zoom. This makes clusters
/// stable across panning: an item that crosses a viewport edge does not
/// change cluster membership.
class MarkerClusterEngine {
  final MarkerManager manager;
  final int zoom;
  final MarkerClusterOptions options;

  const MarkerClusterEngine({
    required this.manager,
    required this.zoom,
    required this.options,
  });

  /// Computes the list of render items for the current state.
  ///
  /// The result preserves manager insertion order as much as possible:
  /// groups appear at the position of their first member, and ungrouped
  /// single markers keep their original order.
  List<ClusterRenderItem> cluster() {
    if (zoom > options.maxZoom) {
      return manager.markers
          .whereType<ClusterMarker>()
          .map<ClusterRenderItem>(SingleClusterMarkerItem.new)
          .toList();
    }

    final clusterMarkers = <ClusterMarker>[];
    for (final marker in manager.markers) {
      if (marker is ClusterMarker) clusterMarkers.add(marker);
    }

    if (clusterMarkers.isEmpty) return const [];

    final byGroup = <String, List<ClusterMarker>>{};
    for (final marker in clusterMarkers) {
      byGroup.putIfAbsent(marker.clusterGroup, () => []).add(marker);
    }

    final items = <ClusterRenderItem>[];
    final used = <ClusterMarker>{};

    for (final entry in byGroup.entries) {
      final group = entry.key;
      final markers = entry.value;
      if (markers.isEmpty) continue;

      final worldPixels = <(double x, double y)>[];
      for (final marker in markers) {
        worldPixels.add(_project(marker.point, zoom));
      }

      final cellSize = options.radius;
      final cells = <(int cx, int cy), List<int>>{};
      for (var i = 0; i < worldPixels.length; i++) {
        final p = worldPixels[i];
        final key = (_cell(p.$1, cellSize), _cell(p.$2, cellSize));
        cells.putIfAbsent(key, () => []).add(i);
      }

      for (var i = 0; i < markers.length; i++) {
        final marker = markers[i];
        if (used.contains(marker)) continue;

        final p = worldPixels[i];
        final candidateIndices = <int>[];
        final cx = _cell(p.$1, cellSize);
        final cy = _cell(p.$2, cellSize);

        for (var dx = -1; dx <= 1; dx++) {
          for (var dy = -1; dy <= 1; dy++) {
            final cell = (cx + dx, cy + dy);
            final cellIndices = cells[cell];
            if (cellIndices == null) continue;
            for (final j in cellIndices) {
              if (used.contains(markers[j])) continue;
              final q = worldPixels[j];
              final dist = math.sqrt(
                math.pow(p.$1 - q.$1, 2) + math.pow(p.$2 - q.$2, 2),
              );
              if (dist <= options.radius) {
                candidateIndices.add(j);
              }
            }
          }
        }

        if (candidateIndices.length < options.minSize) {
          items.add(SingleClusterMarkerItem(marker));
          used.add(marker);
          continue;
        }

        candidateIndices.sort();
        final groupMembers = <ClusterMarker>[];
        for (final j in candidateIndices) {
          used.add(markers[j]);
          groupMembers.add(markers[j]);
        }

        final clusterPoint =
            _centroid(groupMembers, worldPixels, candidateIndices);
        items.add(ClusterGroupItem(
          MarkerCluster(
            point: clusterPoint,
            group: group,
            markers: List.unmodifiable(groupMembers),
          ),
        ));
      }
    }

    return items;
  }

  /// Projects a geographic coordinate to world pixels at the given zoom.
  static (double x, double y) _project(LatLng point, int zoom) {
    final tileX = lon2TileX(point.longitude, zoom);
    final tileY = lat2TileY(point.latitude, zoom);
    return (tileX * 256.0, tileY * 256.0);
  }

  static int _cell(double value, double cellSize) {
    return (value / cellSize).floor();
  }

  /// Computes the centroid of a group of markers and converts it back to
  /// [LatLng].
  LatLng _centroid(
    List<ClusterMarker> members,
    List<(double x, double y)> worldPixels,
    List<int> indices,
  ) {
    var sumX = 0.0;
    var sumY = 0.0;
    for (final i in indices) {
      final p = worldPixels[i];
      sumX += p.$1;
      sumY += p.$2;
    }
    final avgX = sumX / indices.length;
    final avgY = sumY / indices.length;

    final tileX = avgX / 256.0;
    final tileY = avgY / 256.0;
    final lat = clampLatitude(tileY2Lat(tileY, zoom));
    final lng = clampLongitude(tileX2Lng(tileX, zoom));
    return LatLng(latitude: lat, longitude: lng);
  }
}
