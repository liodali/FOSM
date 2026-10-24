import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/api/tile_source.dart';
import 'package:fosm/src/common/tile_work_scheduler.dart';

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.value();
  }
}

void main() {
  test('render and label checkpoints share one budget and frame wait',
      () async {
    var elapsed = Duration.zero;
    var frameRequests = 0;
    final frame = Completer<void>();
    final scheduler = TileWorkScheduler(
      now: () => elapsed,
      nextFrame: () {
        frameRequests++;
        return frame.future;
      },
    );
    addTearDown(scheduler.dispose);
    await scheduler.checkpoint();
    elapsed = const Duration(milliseconds: 1);
    await scheduler.checkpoint();
    elapsed = const Duration(milliseconds: 2);
    var renders = 0;
    var labels = 0;
    final rendering = scheduler.checkpoint().then((_) => renders++);
    final labeling = scheduler.checkpoint().then((_) => labels++);
    await _flush();
    expect(frameRequests, 1);
    expect([renders, labels], [0, 0]);
    frame.complete();
    await Future.wait([rendering, labeling]);
    expect([renders, labels], [1, 1]);
    // Time spent in the other job counts toward this job's next checkpoint.
    elapsed += const Duration(milliseconds: 1);
    await scheduler.checkpoint();
    expect(frameRequests, 1);
  });

  test('idle gaps start a fresh allowance without waiting for a frame',
      () async {
    var elapsed = Duration.zero;
    var frameRequests = 0;
    final scheduler = TileWorkScheduler(
      now: () => elapsed,
      nextFrame: () async => frameRequests++,
    );
    addTearDown(scheduler.dispose);
    await scheduler.checkpoint();
    elapsed = const Duration(milliseconds: 1);
    await scheduler.checkpoint();
    expect(frameRequests, 0);

    // Network wait / idle map: no checkpointed work for a long time. The
    // stale slice must not charge this idle time to the next burst.
    elapsed += const Duration(milliseconds: 300);
    await scheduler.checkpoint();
    expect(frameRequests, 0,
        reason: 'fresh work after idle must not wait for another frame');
    elapsed += const Duration(milliseconds: 1);
    await scheduler.checkpoint();
    expect(frameRequests, 0);
    // Real work within the resumed slice still exhausts and waits as usual.
    elapsed += const Duration(milliseconds: 1);
    await scheduler.checkpoint();
    expect(frameRequests, 1);
  });

  test('an idle image lane resumes submissions without a frame wait', () async {
    var elapsed = Duration.zero;
    var frameRequests = 0;
    final scheduler = TileWorkScheduler(
      now: () => elapsed,
      maxImageStartsPerFrame: 1,
      nextFrame: () async => frameRequests++,
    );
    addTearDown(scheduler.dispose);
    expect(await scheduler.image(() async => 1), 1);
    expect(frameRequests, 0);

    // The lane fully drained, then a long idle gap before new work.
    elapsed += const Duration(milliseconds: 300);
    expect(await scheduler.image(() async => 2), 2,
        reason: 'a resumed lane must not wait a frame for its first start');
    expect(frameRequests, 0);
  });

  test('image starts are bounded by frame and active limits; demand reorders',
      () async {
    final frames = <Completer<void>>[];
    final scheduler = TileWorkScheduler(
      now: () => Duration.zero,
      nextFrame: () {
        final frame = Completer<void>();
        frames.add(frame);
        return frame.future;
      },
    );
    addTearDown(scheduler.dispose);
    final started = <int>[];
    final releases = <int, Completer<int>>{};
    var firstPriority = 1;
    Future<int> submit(int id, int Function() priority) => scheduler.image(() {
          started.add(id);
          return (releases[id] = Completer<int>()).future;
        }, priority: priority);
    final one = submit(1, () => firstPriority);
    final two = submit(2, () => 2);
    final three = submit(3, () => 3);
    await _flush();
    expect(started, [3, 2]);
    expect(frames, isEmpty,
        reason: 'full image slots should not request frames');
    releases[3]!.complete(3);
    await _flush();
    expect(started, [3, 2]);
    expect(frames, hasLength(1));
    final four = submit(4, () => 4);
    firstPriority = 10; // New camera demand promotes an already queued tile.
    frames.single.complete();
    await _flush();
    expect(started, [3, 2, 1]);
    releases[2]!.complete(2);
    await _flush();
    expect(started, [3, 2, 1, 4]);
    releases[1]!.complete(1);
    releases[4]!.complete(4);
    expect(await Future.wait([one, two, three, four]), [1, 2, 3, 4]);
  });

  test('a stale queued image never enters image creation', () async {
    final frame = Completer<void>();
    final scheduler = TileWorkScheduler(
      now: () => Duration.zero,
      maxImageStartsPerFrame: 1,
      nextFrame: () => frame.future,
    );
    addTearDown(scheduler.dispose);
    await scheduler.image(() async => 1);
    var relevant = true;
    var created = false;
    final dropped = scheduler.image(() async {
      created = true;
      return 2;
    }, isRelevant: () => relevant);
    final expectation = expectLater(dropped, throwsA(isA<TileDecodeAborted>()));
    await _flush();
    relevant = false;
    frame.complete();
    await expectation;
    expect(created, isFalse);
  });

  test('image errors release the lane without cancelling other tiles',
      () async {
    final scheduler = TileWorkScheduler(now: () => Duration.zero);
    addTearDown(scheduler.dispose);
    final failed = scheduler.image<int>(() => throw StateError('codec'));
    final valid = scheduler.image(() async => 42);
    await expectLater(failed, throwsStateError);
    expect(await valid, 42);
  });

  test('disposal releases queued images and jobs waiting for a frame',
      () async {
    var elapsed = Duration.zero;
    final frame = Completer<void>();
    final scheduler = TileWorkScheduler(
      now: () => elapsed,
      nextFrame: () => frame.future,
    );
    await scheduler.checkpoint();
    elapsed = const Duration(milliseconds: 3);
    final waiting = scheduler.checkpoint();
    final image = scheduler.image(() async => 1);
    final waitCheck = expectLater(waiting, throwsA(isA<TileDecodeAborted>()));
    final imageCheck = expectLater(image, throwsA(isA<TileDecodeAborted>()));
    await _flush();
    scheduler.dispose();
    await Future.wait([waitCheck, imageCheck]);
    frame.complete(); // A late frame must not complete futures twice.
    await _flush();
    await expectLater(
        scheduler.image(() async => 2), throwsA(isA<TileDecodeAborted>()));
  });

  testWidgets('exhausted work resumes after Flutter paints the next frame',
      (tester) async {
    var elapsed = Duration.zero;
    final scheduler = TileWorkScheduler(now: () => elapsed);
    addTearDown(scheduler.dispose);
    await scheduler.checkpoint();
    elapsed = const Duration(milliseconds: 3);
    final order = <String>[];
    final work = scheduler.checkpoint().then((_) => order.add('work'));
    SchedulerBinding.instance.addPostFrameCallback((_) => order.add('painted'));
    expect(order, isEmpty);
    await tester.pump();
    await work;
    expect(order, ['painted', 'work']);
  });
}
