import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/view/marker_cluster_engine.dart';

void main() {
  group('MarkerClusterEngine', () {
    late MarkerManager manager;

    setUp(() {
      manager = MarkerManager();
    });

    MarkerClusterOptions options({double radius = 64}) {
      return MarkerClusterOptions(radius: radius);
    }

    test('empty manager returns no items', () {
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 10,
        options: options(),
      );
      expect(engine.cluster(), isEmpty);
    });

    test('single cluster marker returns single item', () {
      manager.add(
        ClusterMarker(
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
      );
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 10,
        options: options(),
      );
      final items = engine.cluster();
      expect(items, hasLength(1));
      expect(items.first, isA<SingleClusterMarkerItem>());
    });

    test('nearby markers cluster at low zoom', () {
      manager.addAll([
        ClusterMarker(
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
        ClusterMarker(
          point: const LatLng(latitude: 47.0001, longitude: 8.0001),
          child: const Placeholder(),
        ),
      ]);
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 10,
        options: options(),
      );
      final items = engine.cluster();
      expect(items, hasLength(1));
      expect(items.first, isA<ClusterGroupItem>());
      expect((items.first as ClusterGroupItem).cluster.count, 2);
    });

    test('same markers split as zoom increases', () {
      manager.addAll([
        ClusterMarker(
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
        ClusterMarker(
          point: const LatLng(latitude: 47.0001, longitude: 8.0001),
          child: const Placeholder(),
        ),
      ]);
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 16,
        options: options(),
      );
      final items = engine.cluster();
      expect(items, hasLength(2));
      expect(items.every((i) => i is SingleClusterMarkerItem), isTrue);
    });

    test('above maxZoom every cluster marker is single', () {
      manager.addAll([
        ClusterMarker(
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
        ClusterMarker(
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
      ]);
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 16,
        options: MarkerClusterOptions(maxZoom: 15),
      );
      final items = engine.cluster();
      expect(items, hasLength(2));
      expect(items.every((i) => i is SingleClusterMarkerItem), isTrue);
    });

    test('plain markers are excluded from clustering', () {
      manager.add(
        Marker(
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
      );
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 10,
        options: options(),
      );
      expect(engine.cluster(), isEmpty);
    });

    test('different groups never merge', () {
      manager.addAll([
        ClusterMarker(
          clusterGroup: 'a',
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
        ClusterMarker(
          clusterGroup: 'b',
          point: const LatLng(latitude: 47.0001, longitude: 8.0001),
          child: const Placeholder(),
        ),
      ]);
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 10,
        options: options(),
      );
      final items = engine.cluster();
      expect(items, hasLength(2));
      expect(items.every((i) => i is SingleClusterMarkerItem), isTrue);
    });

    test('minSize is respected', () {
      manager.addAll([
        ClusterMarker(
          point: const LatLng(latitude: 47.0, longitude: 8.0),
          child: const Placeholder(),
        ),
        ClusterMarker(
          point: const LatLng(latitude: 47.0001, longitude: 8.0001),
          child: const Placeholder(),
        ),
      ]);
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 10,
        options: MarkerClusterOptions(minSize: 3),
      );
      final items = engine.cluster();
      expect(items, hasLength(2));
      expect(items.every((i) => i is SingleClusterMarkerItem), isTrue);
    });

    test('centroid is within valid lat/lng bounds', () {
      manager.addAll([
        ClusterMarker(
          point: const LatLng(latitude: 85.0, longitude: 180.0),
          child: const Placeholder(),
        ),
        ClusterMarker(
          point: const LatLng(latitude: 85.0, longitude: 180.0),
          child: const Placeholder(),
        ),
      ]);
      final engine = MarkerClusterEngine(
        manager: manager,
        zoom: 10,
        options: options(),
      );
      final items = engine.cluster();
      expect(items, hasLength(1));
      final cluster = (items.first as ClusterGroupItem).cluster;
      expect(cluster.point.latitude.abs(), lessThanOrEqualTo(85.0511287798066));
      expect(cluster.point.longitude.abs(), lessThanOrEqualTo(180.0));
    });
  });
}
