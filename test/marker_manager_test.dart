import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/marker.dart';
import 'package:fosm/src/api/marker_manager.dart';

Marker _marker(double lat, double lng) => Marker(
      point: LatLng(latitude: lat, longitude: lng),
      child: const SizedBox.shrink(),
    );

void main() {
  group('MarkerManager collection operations', () {
    test('starts empty', () {
      final manager = MarkerManager();
      expect(manager.markers, isEmpty);
      expect(manager.length, 0);
      expect(manager.isEmpty, isTrue);
      expect(manager.isNotEmpty, isFalse);
    });

    test('add appends and exposes the marker', () {
      final manager = MarkerManager();
      final a = _marker(1, 1);
      final b = _marker(2, 2);
      manager.add(a);
      manager.add(b);
      expect(manager.markers, [a, b]);
      expect(manager.length, 2);
    });

    test('addAll keeps insertion order', () {
      final manager = MarkerManager();
      final a = _marker(1, 1);
      final b = _marker(2, 2);
      manager.addAll([a, b]);
      expect(manager.markers, [a, b]);
    });

    test('remove matches by identity, not equality of coordinates', () {
      final manager = MarkerManager();
      final original = _marker(1, 1);
      manager.add(original);
      // Same coordinates, different instance — must NOT remove.
      expect(manager.remove(_marker(1, 1)), isFalse);
      expect(manager.length, 1);
      expect(manager.remove(original), isTrue);
      expect(manager.isEmpty, isTrue);
      expect(manager.remove(original), isFalse);
    });

    test('removeWhere removes only matching markers', () {
      final manager = MarkerManager();
      final north = _marker(10, 0);
      final south = _marker(-10, 0);
      manager.addAll([north, south]);
      final removed =
          manager.removeWhere((m) => m.point.latitude > 0);
      expect(removed, isTrue);
      expect(manager.markers, [south]);
    });

    test('clear empties the manager', () {
      final manager = MarkerManager();
      manager.addAll([_marker(1, 1), _marker(2, 2)]);
      manager.clear();
      expect(manager.isEmpty, isTrue);
    });

    test('markers view is unmodifiable', () {
      final manager = MarkerManager();
      manager.add(_marker(1, 1));
      expect(() => manager.markers.add(_marker(2, 2)), throwsUnsupportedError);
    });
  });

  group('MarkerManager notifications', () {
    test('add notifies listeners once per call', () {
      final manager = MarkerManager();
      var notifications = 0;
      manager.addListener(() => notifications++);

      manager.add(_marker(1, 1));
      expect(notifications, 1);

      manager.addAll([_marker(2, 2), _marker(3, 3)]);
      expect(notifications, 2); // single notification for addAll
    });

    test('no-ops do not notify', () {
      final manager = MarkerManager();
      var notifications = 0;
      manager.addListener(() => notifications++);

      manager.addAll(const []);
      expect(notifications, 0);

      manager.remove(_marker(9, 9)); // not present
      expect(notifications, 0);

      manager.removeWhere((m) => false);
      expect(notifications, 0);

      manager.clear(); // already empty
      expect(notifications, 0);
    });

    test('remove, removeWhere and clear notify when they change something',
        () {
      final manager = MarkerManager();
      var notifications = 0;
      manager.addListener(() => notifications++);

      final marker = _marker(1, 1);
      manager.add(marker);
      expect(notifications, 1);

      manager.remove(marker);
      expect(notifications, 2);

      manager.addAll([marker, _marker(2, 2)]);
      manager.removeWhere((m) => identical(m, marker));
      expect(notifications, 4);

      manager.clear();
      expect(notifications, 5);
    });
  });

  group('Marker.text', () {
    test('builds a text child for the given point', () {
      const point = LatLng(latitude: 47.3769, longitude: 8.5417);
      final marker = Marker.text('Zurich', point);
      expect(marker.point, point);
      expect(marker.child, isA<Text>());
      expect((marker.child as Text).data, 'Zurich');
    });

    test('forwards the text style', () {
      const style = TextStyle(fontSize: 20);
      final marker = Marker.text(
        'Big',
        const LatLng(latitude: 0, longitude: 0),
        style: style,
      );
      expect((marker.child as Text).style, style);
    });
  });
}
