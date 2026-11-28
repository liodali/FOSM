import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/lane_budget.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_manager.dart';

Future<void> _flush(WidgetTester tester, {int turns = 20}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('lane budget drives the manager lanes', () {
    testWidgets('the foreground lane is as wide as the budget says', (
      tester,
    ) async {
      var running = 0;
      var peak = 0;
      final manager = TileManager.init(
        width: 512,
        height: 512,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) {
          running++;
          if (running > peak) peak = running;
          // Never completes: the lane stays full.
          return Completer<Uint8List>().future;
        },
        decoder: (bytes, z, x, y) => Tile.decodeImage(bytes),
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        visibleLoads: 12,
        backgroundLoads: 12,
        laneBudget: LaneBudget(initialWidth: 3, minimumWidth: 3),
      );
      addTearDown(manager.dispose);
      manager.calculate();
      await _flush(tester);
      expect(manager.visibleTileCount, greaterThan(3));
      expect(
        peak,
        3,
        reason: 'the budget, not the fixed 12, bounds the requests',
      );
    });

    testWidgets('without a budget the fixed width applies', (tester) async {
      var running = 0;
      var peak = 0;
      final manager = TileManager.init(
        width: 512,
        height: 512,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) {
          running++;
          if (running > peak) peak = running;
          return Completer<Uint8List>().future;
        },
        decoder: (bytes, z, x, y) => Tile.decodeImage(bytes),
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        visibleLoads: 4,
        backgroundLoads: 4,
      );
      addTearDown(manager.dispose);
      manager.calculate();
      await _flush(tester);
      expect(peak, 4);
    });
  });

  group('stale request cancellation', () {
    late HttpServer server;
    late String base;
    // Fresh per test: the previous test's sockets close during its teardown
    // and must not report into this test's collections.
    late List<String> started;
    late Set<String> closed;
    final managers = <TileManager>[];

    // Real sockets, real time: these run outside fake async.
    Future<void> wait(Duration duration) => Future<void>.delayed(duration);

    Future<bool> until(
      bool Function() condition, {
      Duration limit = const Duration(seconds: 5),
    }) async {
      final stop = DateTime.now().add(limit);
      while (!condition()) {
        if (DateTime.now().isAfter(stop)) return false;
        await wait(const Duration(milliseconds: 10));
      }
      return true;
    }

    setUp(() async {
      final seen = started = <String>[];
      final hungUp = closed = <String>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final key = request.uri.path.substring(1);
        seen.add(key);
        // Hold every request open; note when the client hangs up.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () => hungUp.add(key),
          onError: (_) {
            hungUp.add(key);
          },
        );
      });
    });

    tearDown(() async {
      for (final manager in managers) {
        manager.dispose();
      }
      managers.clear();
      await server.close(force: true);
    });

    Future<TileManager> build({
      required bool cancel,
      List<Object>? errors,
      Duration grace = const Duration(milliseconds: 150),
    }) async {
      final manager = TileManager.init(
        width: 512,
        height: 512,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) =>
            Future<Uint8List>.error(StateError('HTTP worker was not ready')),
        urlBuilder: (z, x, y) => '$base/$z/$x/$y',
        decoder: (bytes, z, x, y) => Tile.decodeImage(bytes),
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        visibleLoads: 4,
        backgroundLoads: 4,
        cancelStaleLoads: cancel,
        cancelStaleGrace: grace,
      );
      managers.add(manager);
      if (errors != null) {
        manager.onTileError = (failure) => errors.add(failure);
      }
      // Let the HTTP worker spawn before the first request.
      await wait(const Duration(milliseconds: 300));
      manager.calculate();
      return manager;
    }

    int startedAt(int zoom) =>
        started.where((key) => key.startsWith('$zoom/')).length;

    test('requests the camera left are aborted for the new viewport', () async {
      final errors = <Object>[];
      final manager = await build(cancel: true, errors: errors);
      expect(
        await until(() => startedAt(12) == 4),
        isTrue,
        reason: 'the 4 wide lane fills with level 12 requests',
      );
      final level12 = started.toList();

      manager.setCameraZoom(13);

      expect(
        await until(() => level12.every(closed.contains)),
        isTrue,
        reason: 'the sockets of the stale requests are closed',
      );
      expect(
        await until(() => startedAt(13) >= 4),
        isTrue,
        reason: 'their slots go to the level 13 viewport',
      );
      expect(errors, isEmpty, reason: 'an abort is not a tile failure');
    });

    test('without cancellation stale requests keep the lane', () async {
      final manager = await build(cancel: false);
      expect(await until(() => startedAt(12) == 4), isTrue);

      manager.setCameraZoom(13);
      await wait(const Duration(milliseconds: 400));

      expect(closed, isEmpty);
      expect(startedAt(13), 0, reason: 'the baseline this change fixes');
    });

    test('requests that are still wanted are not aborted', () async {
      final manager = await build(cancel: true);
      expect(await until(() => startedAt(12) == 4), isTrue);

      // A tiny move keeps the same tiles on screen.
      manager.setCameraZoom(12.05);
      await wait(const Duration(milliseconds: 400));

      expect(closed, isEmpty);
    });

    test(
      'a camera that comes back inside the grace period aborts nothing',
      () async {
        final manager = await build(
          cancel: true,
          grace: const Duration(seconds: 2),
        );
        expect(await until(() => startedAt(12) == 4), isTrue);

        // The pinch oscillates: out to level 13 and back before the grace ends.
        manager.setCameraZoom(13);
        await wait(const Duration(milliseconds: 300));
        manager.setCameraZoom(12);
        await wait(const Duration(milliseconds: 300));
        manager.setCameraZoom(13);
        await wait(const Duration(milliseconds: 300));
        manager.setCameraZoom(12);
        await wait(const Duration(milliseconds: 400));

        expect(
          closed,
          isEmpty,
          reason: 'nothing was unwanted for the whole grace period',
        );
      },
    );

    test('a request unwanted for the whole grace period is aborted', () async {
      final manager = await build(
        cancel: true,
        grace: const Duration(milliseconds: 600),
      );
      expect(await until(() => startedAt(12) == 4), isTrue);
      final level12 = started.toList();

      manager.setCameraZoom(13);
      await wait(const Duration(milliseconds: 200));
      expect(closed, isEmpty, reason: 'still inside the grace period');

      expect(
        await until(() => level12.every(closed.contains)),
        isTrue,
        reason: 'aborted once the grace period ended, without a new event',
      );
    });

    test(
      'an aborted tile is requested again when the camera returns',
      () async {
        final errors = <Object>[];
        final manager = await build(cancel: true, errors: errors);
        expect(await until(() => startedAt(12) == 4), isTrue);
        final firstLevel12 = startedAt(12);

        manager.setCameraZoom(13);
        expect(await until(() => closed.length >= 4), isTrue);

        manager.setCameraZoom(12);
        expect(
          await until(() => startedAt(12) > firstLevel12),
          isTrue,
          reason: 'nothing marked the tiles failed, so they load again',
        );
        expect(errors, isEmpty);
      },
    );
  });

  group('stale requests that share the link with the viewport', () {
    late HttpServer server;
    late String base;
    late List<String> started;
    late Set<String> closed;
    var answered = 0;
    var immediateUntil = 0;
    final managers = <TileManager>[];

    // A 1x1 PNG the decoder accepts.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );

    Future<void> wait(Duration duration) => Future<void>.delayed(duration);

    Future<bool> until(
      bool Function() condition, {
      Duration limit = const Duration(seconds: 5),
    }) async {
      final stop = DateTime.now().add(limit);
      while (!condition()) {
        if (DateTime.now().isAfter(stop)) return false;
        await wait(const Duration(milliseconds: 10));
      }
      return true;
    }

    /// A link measured at about 2.5 tiles in the pipe (the size of the PNG the
    /// server answers with): a total width of 5.
    LaneBudget measuredBudget() {
      final budget = LaneBudget();
      final base = TileManager.fetchClockMicros;
      for (var i = 0; i < 10; i++) {
        budget.fetchStarted(base);
      }
      for (var i = 1; i <= 10; i++) {
        budget.fetchFinished(
          base + i * 40000,
          bytes: png.length,
          firstByteUs: 100000,
        );
      }
      expect(budget.totalWidth, 5);
      return budget;
    }

    setUp(() async {
      final seen = started = <String>[];
      final hungUp = closed = <String>{};
      answered = 0;
      immediateUntil = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final key = request.uri.path.substring(1);
        seen.add(key);
        if (answered < immediateUntil) {
          answered++;
          // The latency the budget was measured with.
          await wait(const Duration(milliseconds: 100));
          request.response.add(png);
          await request.response.close();
          return;
        }
        // Hold the request open; note when the client hangs up.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () => hungUp.add(key),
          onError: (_) {
            hungUp.add(key);
          },
        );
      });
    });

    tearDown(() async {
      for (final manager in managers) {
        manager.dispose();
      }
      managers.clear();
      await server.close(force: true);
    });

    /// Loads the level 12 viewport (answered at once), leaves its padding
    /// ring held in flight on the background lane, then moves to level 13.
    Future<void> zoomAwayFromHeldPadding({required bool cancel}) async {
      final budget = measuredBudget();
      final manager = TileManager.init(
        width: 512,
        height: 512,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) =>
            Future<Uint8List>.error(StateError('HTTP worker was not ready')),
        urlBuilder: (z, x, y) => '$base/$z/$x/$y',
        decoder: (bytes, z, x, y) => Tile.decodeImage(bytes),
        tilePadding: 1,
        preloadAdjacentZoom: false,
        byteOnlyPadding: true,
        laneBudget: budget,
        cancelStaleLoads: cancel,
        cancelStaleGrace: const Duration(milliseconds: 150),
      );
      managers.add(manager);
      await wait(const Duration(milliseconds: 300));
      manager.calculate();
      immediateUntil = manager.visibleTileCount;
      final visible = manager.visibleTileCount;
      expect(
        await until(() => started.length >= visible + 2),
        isTrue,
        reason: 'the padding ring goes out on the background lane',
      );
      final viewport12 = started.take(visible).toSet();

      manager.setCameraZoom(13);

      if (cancel) {
        expect(
          await until(() => closed.isNotEmpty),
          isTrue,
          reason:
              'the link carries more than its width: skipped padding '
              'is aborted although the foreground lane has room',
        );
        expect(
          closed.every(
            (key) => key.startsWith('12/') && !viewport12.contains(key),
          ),
          isTrue,
          reason:
              'only the padding the camera left is aborted, never the '
              'new viewport',
        );
      } else {
        await wait(const Duration(milliseconds: 600));
        expect(closed, isEmpty);
      }
    }

    test('skipped padding is aborted while the new viewport loads', () async {
      await zoomAwayFromHeldPadding(cancel: true);
    });

    test('without cancellation the skipped padding keeps its share', () async {
      await zoomAwayFromHeldPadding(cancel: false);
    });
  });

  group('a cold start', () {
    test('first requests wait for the starting HTTP worker', () async {
      var served = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        served++;
        await request.response.close();
      });
      var fallbackCalls = 0;
      final manager = TileManager.init(
        width: 512,
        height: 512,
        centerLatLng: const LatLng(latitude: 0, longitude: 0),
        zoom: 12,
        fetcher: (z, x, y) {
          fallbackCalls++;
          return Future<Uint8List>.error(StateError('fallback used'));
        },
        urlBuilder: (z, x, y) => 'http://127.0.0.1:${server.port}/$z/$x/$y',
        decoder: (bytes, z, x, y) => Tile.decodeImage(bytes),
        tilePadding: 0,
        preloadAdjacentZoom: false,
        visibleLoads: 4,
      );
      addTearDown(manager.dispose);

      // No wait for the worker: the camera's first wave goes out right away.
      manager.calculate();

      final stop = DateTime.now().add(const Duration(seconds: 5));
      while (served < manager.visibleTileCount &&
          DateTime.now().isBefore(stop)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(served, greaterThanOrEqualTo(manager.visibleTileCount),
          reason: 'the worker took the first wave');
      expect(fallbackCalls, 0,
          reason: 'the fallback fetcher stays out of a starting worker');
    });
  });
}
