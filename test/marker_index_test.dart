import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:fosm/src/api/marker_index.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';

Marker _m(double lat, double lng) => Marker(
      point: LatLng(latitude: lat, longitude: lng),
      child: const SizedBox(width: 4, height: 4),
    );

void main() {
  final random = math.Random(20261023);

  group('MarkerIndex', () {
    test('entries keep insertion order', () {
      final index = MarkerIndex();
      final markers = [_m(10, 10), _m(-10, -170), _m(47, 8), _m(0, 0)];
      index.insertAll(markers);
      expect(index.entries.map((e) => e.marker), orderedEquals(markers));
    });

    test('remove removes only the first duplicate occurrence', () {
      final index = MarkerIndex();
      final marker = _m(47, 8);
      final other = _m(0, 0);
      index.insert(marker);
      index.insert(other);
      index.insert(marker); // same instance twice — mirrors List semantics

      expect(index.length, 3);
      expect(index.remove(marker), isTrue);
      expect(index.length, 2);
      expect(
          index.entries.map((e) => e.marker), orderedEquals([other, marker]));
      // Lookup still resolves while any occurrence remains.
      expect(index[marker], isNotNull);
      expect(index.remove(marker), isTrue);
      expect(index[marker], isNull);
      expect(index.remove(marker), isFalse);
    });

    test('removeWhere keeps stable order and lookups consistent', () {
      final index = MarkerIndex();
      final kept = [_m(10, 10), _m(30, 30)];
      final dropped = [_m(20, 20), _m(40, 40)];
      index.insertAll(kept);
      index.insertAll(dropped);
      final removed = index.removeWhere((m) => dropped.contains(m));
      expect(removed, 2);
      expect(index.entries.map((e) => e.marker), orderedEquals(kept));
      for (final marker in dropped) {
        expect(index.contains(marker), isFalse);
      }
      for (final marker in kept) {
        expect(index.contains(marker), isTrue);
      }
    });

    test('bulk filtering preserves entries, duplicates and predicate order',
        () {
      final index = MarkerIndex();
      final a = _m(0, 0), b = _m(1, 1), c = _m(2, 2);
      index.insertAll([a, b, a, c]);
      final original = [...index.entries];
      final visited = <Marker>[];
      expect(index.removeWhere((marker) {
        visited.add(marker);
        return identical(marker, b);
      }), 1);
      expect(visited, orderedEquals([a, b, a, c]));
      expect(index.entries,
          orderedEquals([original[0], original[2], original[3]]));
      expect(index[a], same(original[0]));
      expect(index.remove(a), isTrue);
      expect(index[a], same(original[2]));
      expect(index.queryRect(0, 0, 1, 1),
          orderedEquals([original[2], original[3]]));
      expect(index.removeWhere((_) => true), 2);
      expect(index.length, 0);
      expect(index.contains(a), isFalse);
      expect(index.queryRect(0, 0, 1, 1), isEmpty);
    });

    test('a throwing bulk predicate leaves all index structures consistent',
        () {
      final index = MarkerIndex();
      final a = _m(0, 0), b = _m(1, 1);
      index.insertAll([a, b]);
      final before = [...index.entries];
      expect(
          () => index.removeWhere((marker) {
                if (identical(marker, b)) throw StateError('predicate failed');
                return true;
              }),
          throwsStateError);
      expect(index.entries, orderedEquals(before));
      expect(index[a], same(before[0]));
      expect(index.queryRect(0, 0, 1, 1), orderedEquals(before));
    });

    test('non-projectable markers retain collection semantics without cells',
        () {
      final manager = MarkerManager();
      addTearDown(manager.dispose);
      final pole = _m(-90, 0);
      final invalid = _m(double.nan, 0);
      final normal = _m(0, 0);
      manager.addAll([pole, normal, pole, invalid]);
      expect(manager.length, 4);
      expect(manager.revision, 1);
      expect(manager.containsMarker(pole), isTrue);
      expect(manager.index[pole]!.isProjectable, isFalse);
      expect(
          manager.index.queryRect(0, 0, 1, 1).map((e) => e.marker), [normal]);
      expect(manager.remove(pole), isTrue);
      expect(manager.containsMarker(pole), isTrue);
      expect(manager.removeWhere((m) => identical(m, invalid)), isTrue);
      expect(manager.markers, orderedEquals([normal, pole]));
      expect(manager.remove(pole), isTrue);
      expect(manager.containsMarker(pole), isFalse);
      expect(
          manager.index.queryRect(0, 0, 1, 1).map((e) => e.marker), [normal]);
    });

    test('clear empties all structures', () {
      final index = MarkerIndex();
      index.insertAll([_m(1, 1), _m(2, 2)]);
      index.clear();
      expect(index.isEmpty, isTrue);
      expect(index.entries, isEmpty);
      expect(index.queryRect(0, 0, 1, 1), isEmpty);
      // Reusable after clear.
      index.insert(_m(3, 3));
      expect(index.queryRect(0, 0, 1, 1), hasLength(1));
    });

    test('cached coordinates match direct projection', () {
      final marker = _m(47.3769, 8.5417);
      final index = MarkerIndex()..insert(marker);
      final entry = index[marker]!;
      expect(entry.nx, lon2TileX(marker.point.longitude, 0));
      expect(entry.ny, lat2TileY(marker.point.latitude, 0));
    });

    test('queryRect matches brute-force scan across random cameras', () {
      // Parity guard: whatever the rect, the index must return exactly the
      // entries a slack-padded full linear scan would keep (a superset so
      // float boundary cases over-select; callers apply the exact test),
      // never miss a strictly-inside entry, and preserve insertion order.
      const slack = 1e-7;
      final markers = <Marker>[
        for (var i = 0; i < 500; i++)
          _m(
            -89 + random.nextDouble() * 178,
            -180 + random.nextDouble() * 360,
          ),
        // Off-world markers behave like direct (unwrapped) projection.
        _m(0, 190),
        _m(0, -190),
        _m(89.9, 0),
        _m(-89.9, 0),
      ];
      final index = MarkerIndex()..insertAll(markers);

      var rect = (0.0, 0.0, 0.0, 0.0);
      bool inRect(MarkerIndexEntry e, double pad) =>
          e.nx >= rect.$1 - pad &&
          e.nx <= rect.$3 + pad &&
          e.ny >= rect.$2 - pad &&
          e.ny <= rect.$4 + pad;

      for (var trial = 0; trial < 200; trial++) {
        final cx = random.nextDouble();
        final cy = random.nextDouble();
        final halfW = 0.001 + random.nextDouble() * 0.4;
        final halfH = 0.001 + random.nextDouble() * 0.4;
        rect = (cx - halfW, cy - halfH, cx + halfW, cy + halfH);

        final strict = <MarkerIndexEntry>{};
        final padded = <MarkerIndexEntry>[];
        for (final entry in index.entries) {
          if (inRect(entry, 0)) strict.add(entry);
          if (inRect(entry, slack)) padded.add(entry);
        }

        final indexed = index.queryRect(rect.$1, rect.$2, rect.$3, rect.$4);
        expect(indexed, orderedEquals(padded),
            reason: 'rect $rect must match the padded linear scan');
        expect(indexed.where(strict.contains).length, strict.length,
            reason: 'rect $rect must keep every strictly-inside entry');
      }
    });

    test('whole-world query matches brute-force scan', () {
      final markers = [
        for (var i = 0; i < 100; i++) _m(-80 + random.nextDouble() * 160, 0),
      ];
      final index = MarkerIndex()..insertAll(markers);
      final result = index.queryRect(0.0, 0.4, 1.0, 0.6);
      expect(
        result,
        orderedEquals(
            index.entries.where((e) => e.ny >= 0.4 && e.ny <= 0.6).toList()),
      );
    });
  });

  group('MarkerManager index maintenance', () {
    test('mutations keep manager list and index consistent', () {
      final manager = MarkerManager();
      final a = _m(1, 1);
      final b = _m(2, 2);
      final c = _m(3, 3);
      manager.addAll([a, b, c]);
      expect(manager.markers, orderedEquals([a, b, c]));
      expect(
          manager.index.entries.map((e) => e.marker), orderedEquals([a, b, c]));

      manager.remove(b);
      expect(manager.markers, orderedEquals([a, c]));
      expect(manager.index.entries.map((e) => e.marker), orderedEquals([a, c]));

      manager.removeWhere((m) => m == a);
      expect(manager.markers, orderedEquals([c]));
      expect(manager.index.entries.map((e) => e.marker), orderedEquals([c]));

      manager.clear();
      expect(manager.index.isEmpty, isTrue);
      expect(manager.markers, isEmpty);
    });

    test('revision bumps on every mutation kind', () {
      final manager = MarkerManager();
      final marker = _m(1, 1);
      manager.add(marker);
      final afterAdd = manager.revision;
      manager.add(_m(2, 2));
      expect(manager.revision, afterAdd + 1);
      manager.remove(marker);
      expect(manager.revision, afterAdd + 2);
      manager.clear();
      expect(manager.revision, afterAdd + 3);
    });

    test('containsMarker avoids collection copies and uses identity', () {
      final manager = MarkerManager();
      final marker = _m(47, 8);
      manager.add(marker);
      expect(manager.containsMarker(marker), isTrue);
      expect(manager.containsMarker(_m(47, 8)), isFalse,
          reason: 'identity comparison, like remove');
    });
  });
}
