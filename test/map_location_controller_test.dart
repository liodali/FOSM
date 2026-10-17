import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

const _first = MapLocation(
    point: LatLng(latitude: 1, longitude: 2), accuracyMeters: 10, bearing: 90);
const _second = MapLocation(point: LatLng(latitude: 2, longitude: 3));

void main() {
  test('follow intent waits, follows, pauses, recenters and stops', () {
    final controller = MapLocationController();
    addTearDown(controller.dispose);
    expect(controller.state, MapLocationFollowState.off);
    controller.follow();
    expect(controller.state, MapLocationFollowState.waiting);
    controller.updateLocation(_first);
    expect(controller.state, MapLocationFollowState.following);
    controller.pause();
    controller.updateLocation(_second);
    expect(controller.state, MapLocationFollowState.paused);
    expect(controller.location, same(_second));
    controller.follow();
    expect(controller.isFollowing, isTrue);
    final revision = controller.followRevision;
    controller.follow();
    expect(controller.followRevision, revision + 1,
        reason: 'recenter works even if already following');
    controller.stop();
    expect(controller.state, MapLocationFollowState.off);
    controller.pause();
    expect(controller.state, MapLocationFollowState.off);
  });

  test('accuracy/bearing updates do not restart the camera target', () {
    final controller = MapLocationController(follow: true);
    addTearDown(controller.dispose);
    controller.updateLocation(_first);
    final revision = controller.followRevision;
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.updateLocation(const MapLocation(
        point: LatLng(latitude: 1, longitude: 2),
        accuracyMeters: 20,
        bearing: 180));
    expect(controller.followRevision, revision);
    expect(notifications, 1);
    expect(controller.location!.bearing, 180);
  });

  test(
      'older timestamps are ignored across untimed fixes; clearing resets order',
      () {
    final controller = MapLocationController(follow: true);
    addTearDown(controller.dispose);
    final time = DateTime.utc(2026, 10, 17, 12);
    controller
        .updateLocation(MapLocation(point: _first.point, timestamp: time));
    controller.updateLocation(_second);
    var notifications = 0;
    controller.addListener(() => notifications++);
    expect(
        controller.updateLocation(MapLocation(
            point: _first.point,
            timestamp: time.subtract(const Duration(seconds: 1)))),
        isFalse);
    expect(controller.location, same(_second));
    expect(notifications, 0);
    controller.clearLocation();
    expect(controller.state, MapLocationFollowState.waiting);
    expect(
        controller.updateLocation(MapLocation(
            point: _first.point,
            timestamp: time.subtract(const Duration(seconds: 1)))),
        isTrue);
  });

  test('invalid values throw without changing the last fix', () {
    final controller = MapLocationController()..updateLocation(_first);
    addTearDown(controller.dispose);
    for (final value in [
      const MapLocation(point: LatLng(latitude: double.nan, longitude: 0)),
      const MapLocation(point: LatLng(latitude: 91, longitude: 0)),
      const MapLocation(point: LatLng(latitude: 0, longitude: 181)),
      MapLocation(point: _first.point, accuracyMeters: -1),
      MapLocation(point: _first.point, accuracyMeters: double.infinity),
      MapLocation(point: _first.point, bearing: 360),
    ]) {
      expect(() => controller.updateLocation(value), throwsArgumentError);
      expect(controller.location, same(_first));
    }
    expect(
        const MapLocation(
                point: LatLng(latitude: 90, longitude: -180),
                accuracyMeters: 0,
                bearing: 0)
            .isValid,
        isTrue);
  });

  test('stream errors and malformed fixes retain position and recover',
      () async {
    final source = StreamController<MapLocation>();
    final controller =
        MapLocationController(locations: source.stream, follow: true);
    addTearDown(controller.dispose);
    source.add(_first);
    await Future<void>.delayed(Duration.zero);
    final revision = controller.followRevision;
    source.addError(StateError('permission lost'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isA<StateError>());
    expect(controller.location, same(_first));
    source.add(
        const MapLocation(point: LatLng(latitude: double.nan, longitude: 0)));
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isA<ArgumentError>());
    source.add(_first);
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isNull);
    expect(controller.followRevision, greaterThan(revision));
    expect(controller.state, MapLocationFollowState.following);
    await source.close();
    expect(controller.isStreamActive, isFalse);
    expect(controller.location, same(_first));
  });

  test('stream replacement accepts new fixes while old cancellation finishes',
      () async {
    final cancellation = Completer<void>();
    var cancellations = 0;
    final first = StreamController<MapLocation>(onCancel: () {
      cancellations++;
      return cancellation.future;
    });
    final second = StreamController<MapLocation>();
    final controller =
        MapLocationController(locations: first.stream, follow: true);
    first.add(_first);
    await Future<void>.delayed(Duration.zero);
    controller.setStream(second.stream);
    expect(cancellations, 1);
    second.add(_second);
    await Future<void>.delayed(Duration.zero);
    expect(controller.location, same(_second));
    controller.setStream(null);
    expect(controller.isStreamActive, isFalse);
    expect(controller.location, same(_second));
    expect(controller.isFollowing, isTrue);
    cancellation.complete();
    await first.close();
    await second.close();
    controller.dispose();
  });

  test('disposal cancels the source and guards later operations', () async {
    var cancellations = 0;
    final source =
        StreamController<MapLocation>(onCancel: () => cancellations++);
    final controller = MapLocationController(locations: source.stream);
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.dispose();
    expect(cancellations, 1);
    source.add(_first);
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 0);
    expect(() => controller.follow(), throwsStateError);
    expect(() => controller.updateLocation(_first), throwsStateError);
    await source.close();
  });
}
