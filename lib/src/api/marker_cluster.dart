import 'package:flutter/material.dart';

import 'geo_point.dart';
import 'marker.dart';

/// A marker that may be grouped with nearby cluster markers.
///
/// It behaves exactly like a normal [Marker] when isolated or when the map
/// is zoomed in past [MarkerClusterOptions.maxZoom]. At lower zooms, nearby
/// markers with the same [clusterGroup] collapse into a single cluster badge.
class ClusterMarker extends Marker {
  /// Identifies which cluster set this marker belongs to. Markers in
  /// different groups are never clustered together.
  final String clusterGroup;

  const ClusterMarker({
    required super.point,
    required super.child,
    this.clusterGroup = 'default',
    super.alignment,
    super.onTap,
    super.onLongPress,
    super.overlayBuilder,
    super.overlayConfig,
  });
}

/// A read-only group produced by the clustering engine.
class MarkerCluster {
  /// Geographic anchor of the cluster (centroid of its members).
  final LatLng point;

  /// The group name shared by all members.
  final String group;

  /// The markers that make up this cluster.
  final List<ClusterMarker> markers;

  int get count => markers.length;

  const MarkerCluster({
    required this.point,
    required this.group,
    required this.markers,
  });
}

/// Builder used to render a [MarkerCluster].
typedef MarkerClusterBuilder = Widget Function(
  BuildContext context,
  MarkerCluster cluster,
);

/// Called when a generated cluster is tapped.
typedef MarkerClusterTapCallback = void Function(MarkerCluster cluster);

/// Options that control marker clustering on a [MapView].
///
/// Clustering is active at zoom levels <= [maxZoom]. Above [maxZoom], every
/// [ClusterMarker] is rendered as a normal marker, including markers at
/// identical coordinates.
class MarkerClusterOptions {
  /// Grouping radius in logical pixels. Two points closer than this value
  /// (in world pixels at the current zoom) are merged into a cluster.
  final double radius;

  /// Maximum zoom at which clustering is applied. At zoom levels above this,
  /// all [ClusterMarker]s render individually.
  final int maxZoom;

  /// Minimum number of markers required to form a cluster. Defaults to 2;
  /// a value below 2 would create single-marker clusters.
  final int minSize;

  /// Builder for the cluster badge. When null, a default circular count badge
  /// is used.
  final MarkerClusterBuilder? builder;

  /// Optional callback invoked when a cluster is tapped.
  final MarkerClusterTapCallback? onTap;

  /// Whether tapping a cluster zooms in one level using the cluster's
  /// screen position as the focal point.
  final bool zoomOnTap;

  const MarkerClusterOptions({
    this.radius = 64.0,
    this.maxZoom = 15,
    this.minSize = 2,
    this.builder,
    this.onTap,
    this.zoomOnTap = true,
  })  : assert(radius > 0, 'radius must be positive'),
        assert(minSize >= 2, 'minSize must be at least 2'),
        assert(maxZoom >= 0, 'maxZoom must be non-negative');

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MarkerClusterOptions &&
        other.radius == radius &&
        other.maxZoom == maxZoom &&
        other.minSize == minSize &&
        other.zoomOnTap == zoomOnTap;
  }

  @override
  int get hashCode => Object.hash(radius, maxZoom, minSize, zoomOnTap);
}
