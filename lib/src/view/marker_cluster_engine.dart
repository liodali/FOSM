import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/geo_point.dart';
import '../api/marker_cluster.dart';
import '../api/marker_index.dart';
import '../api/marker_manager.dart';
import '../common/marker_trace.dart';
import '../common/osm_transformation_utilities.dart';

/// Render item produced by the clustering engine.
sealed class ClusterRenderItem {
  const ClusterRenderItem();
}

/// A single [ClusterMarker] that should render normally.
class SingleClusterMarkerItem extends ClusterRenderItem {
  final ClusterMarker marker;

  /// Identifies an insertion occurrence when duplicates render separately
  /// above maxZoom. The marker alone cannot provide a unique widget key.
  final MarkerIndexEntry? entry;

  const SingleClusterMarkerItem(this.marker, {this.entry});
}

/// A generated cluster that should render as a badge.
///
/// [nx]/[ny] are the centroid's normalized world coordinates, cached so
/// the layer can position the badge affinely each frame instead of
/// re-projecting [MarkerCluster.point] with trigonography.
class ClusterGroupItem extends ClusterRenderItem {
  final MarkerCluster cluster;
  final double nx;
  final double ny;

  const ClusterGroupItem(this.cluster, this.nx, this.ny);
}

/// Pure, camera-independent clustering engine.
///
/// The engine groups [ClusterMarker]s by [ClusterMarker.clusterGroup] using
/// world-pixel coordinates at the current integer zoom. This makes clusters
/// stable across panning: an item that crosses a viewport edge does not
/// change cluster membership.
///
/// Marker positions come from the manager's geographic index, whose cached
/// normalized world coordinates scale to world pixels at any zoom by an
/// exact power-of-two multiplication — bit-identical to projecting each
/// marker directly, so grouping results are unchanged, but without the
/// per-marker trigonography on every recomputation.
class MarkerClusterEngine {
  final MarkerManager manager;
  final int zoom;
  final MarkerClusterOptions options;

  /// Number of `cluster()` invocations. Regression tests use it to prove
  /// results are reused across pans and fractional-zoom intervals instead
  /// of being recomputed each frame.
  @visibleForTesting
  static int debugComputations = 0;

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
    return MarkerTrace.sync('cluster', _cluster);
  }

  List<ClusterRenderItem> _cluster() {
    debugComputations++;

    final entries = manager.index.entries;
    if (zoom > options.maxZoom) {
      return [
        for (final entry in entries)
          if (entry.marker is ClusterMarker)
            SingleClusterMarkerItem(entry.marker as ClusterMarker,
                entry: entry),
      ];
    }

    final clusterEntries = <MarkerIndexEntry>[];
    for (final entry in entries) {
      if (entry.marker is ClusterMarker) clusterEntries.add(entry);
    }

    if (clusterEntries.isEmpty) return const [];

    // 256 world pixels per tile at this zoom. Cached normalized
    // coordinates × worldSize are bit-identical to projecting each
    // marker at [zoom].
    final worldSize = 256.0 * math.pow(2.0, zoom).toDouble();

    final byGroup = <String, List<MarkerIndexEntry>>{};
    for (final entry in clusterEntries) {
      byGroup
          .putIfAbsent((entry.marker as ClusterMarker).clusterGroup, () => [])
          .add(entry);
    }

    final items = <ClusterRenderItem>[];
    final used = <ClusterMarker>{};

    for (final entry in byGroup.entries) {
      final group = entry.key;
      final markers = entry.value;
      if (markers.isEmpty) continue;

      final worldPixels = <(double x, double y)>[];
      for (final markerEntry in markers) {
        worldPixels
            .add((markerEntry.nx * worldSize, markerEntry.ny * worldSize));
      }

      final cellSize = options.radius;
      final cells = <(int cx, int cy), List<int>>{};
      for (var i = 0; i < worldPixels.length; i++) {
        final p = worldPixels[i];
        final key = (_cell(p.$1, cellSize), _cell(p.$2, cellSize));
        cells.putIfAbsent(key, () => []).add(i);
      }

      for (var i = 0; i < markers.length; i++) {
        final markerEntry = markers[i];
        if (used.contains(markerEntry.marker)) continue;

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
              if (used.contains(markers[j].marker)) continue;
              final q = worldPixels[j];
              final ddx = p.$1 - q.$1;
              final ddy = p.$2 - q.$2;
              final dist = math.sqrt(ddx * ddx + ddy * ddy);
              if (dist <= options.radius) {
                candidateIndices.add(j);
              }
            }
          }
        }

        if (candidateIndices.length < options.minSize) {
          items.add(SingleClusterMarkerItem(markerEntry.marker as ClusterMarker,
              entry: markerEntry));
          used.add(markerEntry.marker as ClusterMarker);
          continue;
        }

        candidateIndices.sort();
        final groupMembers = <ClusterMarker>[];
        for (final j in candidateIndices) {
          used.add(markers[j].marker as ClusterMarker);
          groupMembers.add(markers[j].marker as ClusterMarker);
        }

        final centroid = _centroid(worldPixels, candidateIndices);
        items.add(ClusterGroupItem(
          MarkerCluster(
            point: centroid.point,
            group: group,
            markers: List.unmodifiable(groupMembers),
          ),
          centroid.nx,
          centroid.ny,
        ));
      }
    }

    return items;
  }

  static int _cell(double value, double cellSize) {
    return (value / cellSize).floor();
  }

  /// Computes the centroid of a group of markers as both a [LatLng] (for
  /// public consumption) and normalized world coordinates (for affine
  /// per-frame positioning).
  ({LatLng point, double nx, double ny}) _centroid(
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
    return (
      point: LatLng(latitude: lat, longitude: lng),
      // Cache the same clamped point exposed to builders and tap/focal-zoom
      // handlers. Raw averages can lie outside the Mercator/world bounds.
      // This projection runs once per cluster, never during camera frames.
      nx: lon2TileX(lng, 0),
      ny: lat2TileY(lat, 0),
    );
  }
}
