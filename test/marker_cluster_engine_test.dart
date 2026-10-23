import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
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

    test('duplicate identities keep legacy singleton and group semantics', () {
      final marker = ClusterMarker(
        point: const LatLng(latitude: 0, longitude: 0),
        child: const SizedBox(),
      );
      manager.addAll([marker, marker]);
      final singles = MarkerClusterEngine(
              manager: manager,
              zoom: 10,
              options: const MarkerClusterOptions(minSize: 3))
          .cluster();
      expect(singles, hasLength(1));
      expect((singles.single as SingleClusterMarkerItem).marker, same(marker));
      // The old engine counts both occurrences when they form a group.
      final grouped = MarkerClusterEngine(
              manager: manager, zoom: 10, options: const MarkerClusterOptions())
          .cluster();
      expect(grouped, hasLength(1));
      expect((grouped.single as ClusterGroupItem).cluster.markers,
          orderedEquals([marker, marker]));
      // Above maxZoom duplicates render separately with distinct entry keys.
      final expanded = MarkerClusterEngine(
              manager: manager, zoom: 20, options: const MarkerClusterOptions())
          .cluster();
      expect(expanded, hasLength(2));
      expect((expanded[0] as SingleClusterMarkerItem).entry,
          isNot(same((expanded[1] as SingleClusterMarkerItem).entry)));
    });

    for (final point in const [
      LatLng(latitude: 86, longitude: 8),
      LatLng(latitude: -86, longitude: 8),
      LatLng(latitude: 0, longitude: 190),
      LatLng(latitude: 0, longitude: -190),
      LatLng(latitude: 89.9, longitude: 190),
      LatLng(latitude: -89.9, longitude: -190),
      LatLng(latitude: 47, longitude: 8),
    ]) {
      test(
          'cached badge follows public centroid at '
          '${point.latitude}/${point.longitude}', () {
        manager.addAll([
          for (var i = 0; i < 2; i++)
            ClusterMarker(point: point, child: const SizedBox()),
        ]);
        for (final zoom in [0, 3, 10, 20]) {
          final item = MarkerClusterEngine(
            manager: manager,
            zoom: zoom,
            options: const MarkerClusterOptions(maxZoom: 20),
          ).cluster().single as ClusterGroupItem;
          final centroid = item.cluster.point;
          expect(
              centroid.latitude, closeTo(clampLatitude(point.latitude), 1e-10));
          expect(centroid.longitude,
              closeTo(clampLongitude(point.longitude), 1e-10));
          expect(item.nx, lon2TileX(centroid.longitude, 0));
          expect(item.ny, lat2TileY(centroid.latitude, 0));
          // The layer scales cached coordinates instead of projecting the
          // public point; badge rendering must still land at that point.
          final worldSize = 256.0 * math.pow(2.0, zoom).toDouble();
          expect(
              item.nx * worldSize, lon2TileX(centroid.longitude, zoom) * 256.0);
          expect(
              item.ny * worldSize, lat2TileY(centroid.latitude, zoom) * 256.0);
        }
      });
    }

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
      final cluster = (items.first as ClusterGroupItem);
      expect(cluster.cluster.point.latitude.abs(),
          lessThanOrEqualTo(85.0511287798066));
      expect(cluster.cluster.point.longitude.abs(), lessThanOrEqualTo(180.0));
    });
  });

  group('MarkerClusterEngine cached-coordinate parity', () {
    // Reference implementation of the pre-index engine: projects every
    // marker directly with trigonography at the query zoom. The engine
    // now scales cached normalized coordinates by a power of two, which
    // is exact in IEEE-754 — this test guards that grouping rules and
    // outputs stay bit-identical.
    final random = math.Random(987654321);

    (double, double) project(LatLng point, int zoom) {
      return (
        lon2TileX(point.longitude, zoom) * 256.0,
        lat2TileY(point.latitude, zoom) * 256.0,
      );
    }

    List<ClusterRenderItem> referenceCluster(
      List<ClusterMarker> markers,
      int zoom,
      MarkerClusterOptions options,
    ) {
      if (zoom > options.maxZoom) {
        return markers
            .map<ClusterRenderItem>(SingleClusterMarkerItem.new)
            .toList();
      }

      final byGroup = <String, List<ClusterMarker>>{};
      for (final marker in markers) {
        byGroup.putIfAbsent(marker.clusterGroup, () => []).add(marker);
      }

      final items = <ClusterRenderItem>[];
      final used = <ClusterMarker>{};

      for (final entry in byGroup.entries) {
        final group = entry.key;
        final groupMarkers = entry.value;
        if (groupMarkers.isEmpty) continue;

        final worldPixels = <(double, double)>[];
        for (final marker in groupMarkers) {
          worldPixels.add(project(marker.point, zoom));
        }

        final cellSize = options.radius;
        final cells = <(int, int), List<int>>{};
        for (var i = 0; i < worldPixels.length; i++) {
          final p = worldPixels[i];
          cells.putIfAbsent(
              ((p.$1 / cellSize).floor(), (p.$2 / cellSize).floor()),
              () => []).add(i);
        }

        for (var i = 0; i < groupMarkers.length; i++) {
          final marker = groupMarkers[i];
          if (used.contains(marker)) continue;

          final p = worldPixels[i];
          final candidateIndices = <int>[];
          final cx = (p.$1 / cellSize).floor();
          final cy = (p.$2 / cellSize).floor();

          for (var dx = -1; dx <= 1; dx++) {
            for (var dy = -1; dy <= 1; dy++) {
              final cellIndices = cells[(cx + dx, cy + dy)];
              if (cellIndices == null) continue;
              for (final j in cellIndices) {
                if (used.contains(groupMarkers[j])) continue;
                final q = worldPixels[j];
                final dist = math
                    .sqrt(math.pow(p.$1 - q.$1, 2) + math.pow(p.$2 - q.$2, 2));
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
          var sumX = 0.0, sumY = 0.0;
          for (final j in candidateIndices) {
            used.add(groupMarkers[j]);
            groupMembers.add(groupMarkers[j]);
            sumX += worldPixels[j].$1;
            sumY += worldPixels[j].$2;
          }
          final avgX = sumX / candidateIndices.length;
          final avgY = sumY / candidateIndices.length;
          final tileX = avgX / 256.0;
          final tileY = avgY / 256.0;
          items.add(ClusterGroupItem(
            MarkerCluster(
              point: LatLng(
                latitude: clampLatitude(tileY2Lat(tileY, zoom)),
                longitude: clampLongitude(tileX2Lng(tileX, zoom)),
              ),
              group: group,
              markers: List.unmodifiable(groupMembers),
            ),
            avgX / (256.0 * math.pow(2.0, zoom).toDouble()),
            avgY / (256.0 * math.pow(2.0, zoom).toDouble()),
          ));
        }
      }

      return items;
    }

    test('grouping matches direct trigonographic projection', () {
      for (final zoom in [0, 5, 10, 15, 17]) {
        // Clusters of markers around a few hot spots plus stragglers, in
        // multiple groups — exercises merge, split and boundary cases.
        final hotSpots = [
          for (var h = 0; h < 5; h++)
            (
              -60 + random.nextDouble() * 120,
              -120 + random.nextDouble() * 240,
            ),
        ];
        final markers = <ClusterMarker>[
          for (var h = 0; h < hotSpots.length; h++)
            for (var i = 0; i < 60; i++)
              ClusterMarker(
                clusterGroup: 'group-${i % 3}',
                point: LatLng(
                  latitude: hotSpots[h].$1 + (random.nextDouble() - 0.5) * 0.5,
                  longitude: hotSpots[h].$2 + (random.nextDouble() - 0.5) * 0.5,
                ),
                child: const Placeholder(),
              ),
        ];
        markers.shuffle(random);

        for (final options in [
          const MarkerClusterOptions(),
          const MarkerClusterOptions(radius: 24, minSize: 3),
          const MarkerClusterOptions(radius: 200, maxZoom: 12),
        ]) {
          final manager = MarkerManager()..addAll(markers);
          final engine = MarkerClusterEngine(
            manager: manager,
            zoom: zoom,
            options: options,
          );
          final actual = engine.cluster();
          final expected = referenceCluster(markers, zoom, options);

          expect(actual, hasLength(expected.length),
              reason: 'zoom $zoom options $options');
          for (var i = 0; i < expected.length; i++) {
            final a = actual[i];
            final e = expected[i];
            if (e is SingleClusterMarkerItem) {
              expect(a, isA<SingleClusterMarkerItem>(),
                  reason: 'zoom $zoom item $i');
              expect((a as SingleClusterMarkerItem).marker, same(e.marker));
            } else {
              e as ClusterGroupItem;
              a as ClusterGroupItem;
              // Same members in the same order…
              expect(a.cluster.markers, orderedEquals(e.cluster.markers));
              // …same centroid bit-for-bit (identical arithmetic)…
              expect(a.cluster.point.latitude, e.cluster.point.latitude);
              expect(a.cluster.point.longitude, e.cluster.point.longitude);
              // …and normalized centroids that project back onto it.
              final scale = math.pow(2.0, zoom).toDouble();
              expect(
                  a.nx * scale * 256.0,
                  closeTo(lon2TileX(e.cluster.point.longitude, zoom) * 256.0,
                      1e-6));
            }
          }
        }
      }
    });
  });
}
