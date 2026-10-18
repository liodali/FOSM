import 'dart:async';

import 'package:flutter/scheduler.dart';

import '../api/tile_source.dart' show TileDecodeAborted;

/// Shared cooperative UI-work allowance for one map. Checkpoints in separate
/// render/label jobs consume the same interval, rather than each getting a
/// fresh budget. Waiting yields through a Flutter frame, including its paint.
/// A single Canvas/text/codec operation cannot be preempted.
///
/// Idle gaps (network waits, frames without tile work) do not consume the
/// allowance: work resuming after [idleResetInterval] starts a fresh slice
/// and idle image lanes accept submissions without waiting another frame.
class TileWorkScheduler {
  TileWorkScheduler({
    this.budget = const Duration(milliseconds: 2),
    this.maxImageStartsPerFrame = 2,
    this.maxActiveImages = 2,
    Duration Function()? now,
    Future<void> Function()? nextFrame,
  })  : _now = now ?? _clock(),
        _nextFrame = nextFrame ?? _flutterFrame {
    if (budget <= Duration.zero ||
        maxImageStartsPerFrame < 1 ||
        maxActiveImages < 1) {
      throw ArgumentError('Work budget and image limits must be positive');
    }
  }

  final Duration budget;
  final int maxImageStartsPerFrame;
  final int maxActiveImages;
  final Duration Function() _now;
  final Future<void> Function() _nextFrame;
  Duration? _sliceStart;
  Duration? _lastCheckpointAt;
  Completer<void>? _frameWaiter;
  final List<_ImageWork> _images = [];
  int _imageStarts = 0;
  int _activeImages = 0;
  bool _pumping = false;
  bool _disposed = false;

  /// Checkpoint gaps longer than one nominal frame start a fresh allowance
  /// instead of inheriting a stale one. A gap this large means no
  /// checkpointed work ran across at least one frame boundary (network
  /// waits, an idle map), so fresh work must not wait for yet another
  /// frame. Single expensive engine calls that cannot checkpoint (a
  /// CanvasKit `toImage` can take 5–15 ms) sit below the interval; the
  /// worst case of misclassifying one is a single extra [budget] of work.
  static const Duration idleResetInterval = Duration(milliseconds: 16);

  static Duration Function() _clock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  static Future<void> _flutterFrame() => SchedulerBinding.instance.endOfFrame;

  void _check(bool Function()? isRelevant) {
    if (_disposed || (isRelevant != null && !isRelevant())) {
      throw const TileDecodeAborted();
    }
  }

  Future<void> checkpoint({bool Function()? isRelevant}) async {
    _check(isRelevant);
    final now = _now();
    final lastCheckpoint = _lastCheckpointAt;
    _lastCheckpointAt = now;
    if (lastCheckpoint != null && now - lastCheckpoint > idleResetInterval) {
      // Idle gap: network waits, frames without tile work, an empty map.
      // The allowance restarts against the boundary that already passed
      // instead of charging fresh work for elapsed idle time.
      _sliceStart = now;
      return;
    }
    _sliceStart ??= now;
    if (now - _sliceStart! >= budget) {
      await _waitForFrame();
      _check(isRelevant);
    }
  }

  /// Whether [now] resumes work after a real idle gap rather than
  /// continuing a checkpointed burst.
  bool _resumesAfterIdle(Duration now) {
    final lastCheckpoint = _lastCheckpointAt;
    return lastCheckpoint == null ||
        now - lastCheckpoint > idleResetInterval;
  }

  Future<void> _waitForFrame() {
    if (_disposed) return Future<void>.value();
    final existing = _frameWaiter;
    if (existing != null) return existing.future;
    final waiter = Completer<void>();
    _frameWaiter = waiter;
    _nextFrame().then((_) {
      if (_frameWaiter != waiter) return;
      _frameWaiter = null;
      final boundary = _now();
      _sliceStart = boundary;
      _lastCheckpointAt = boundary;
      _imageStarts = 0;
      waiter.complete();
    }, onError: (Object error, StackTrace stack) {
      if (_frameWaiter != waiter) return;
      _frameWaiter = null;
      waiter.completeError(error, stack);
    });
    return waiter.future;
  }

  /// Bounds both image concurrency and submissions within a frame. Priority
  /// and relevance are evaluated when a slot opens, so a camera change can
  /// promote the new centre and drop obsolete work without entering a codec.
  Future<T> image<T>(Future<T> Function() create,
      {int Function()? priority, bool Function()? isRelevant}) {
    if (_disposed) return Future<T>.error(const TileDecodeAborted());
    final now = _now();
    if (_images.isEmpty && _activeImages == 0 && _resumesAfterIdle(now)) {
      // Submitting to a fully idle lane after an idle gap: per-frame
      // submissions restart with this work instead of waiting a frame for
      // a boundary that already passed while nothing was scheduled.
      _imageStarts = 0;
      _sliceStart = now;
    }
    final work = _TypedImageWork<T>(create, priority, isRelevant);
    _images.add(work);
    scheduleMicrotask(_pumpImages);
    return work.result.future;
  }

  Future<void> _pumpImages() async {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (!_disposed && _activeImages < maxActiveImages) {
        _images.removeWhere((work) {
          if (work.isRelevant?.call() ?? true) return false;
          work.abort();
          return true;
        });
        if (_images.isEmpty) break;
        await checkpoint();
        if (_disposed) break;
        if (_imageStarts >= maxImageStartsPerFrame) {
          await _waitForFrame();
          continue; // Re-evaluate current demand after the frame.
        }
        var best = 0;
        for (var i = 1; i < _images.length; i++) {
          if (_images[i].priorityValue > _images[best].priorityValue) best = i;
        }
        final work = _images.removeAt(best);
        if (!(work.isRelevant?.call() ?? true)) {
          work.abort();
          continue;
        }
        _imageStarts++;
        _activeImages++;
        unawaited(work.run().whenComplete(() {
          _activeImages--;
          unawaited(_pumpImages());
        }));
      }
    } on TileDecodeAborted {
      // Disposal releases the frame waiter; pending images are aborted below.
    } finally {
      _pumping = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final work in _images) {
      work.abort();
    }
    _images.clear();
    final waiter = _frameWaiter;
    _frameWaiter = null;
    waiter?.complete();
  }
}

abstract class _ImageWork {
  _ImageWork(this.priority, this.isRelevant);
  final int Function()? priority;
  final bool Function()? isRelevant;
  int get priorityValue => priority?.call() ?? 0;
  Future<void> run();
  void abort();
}

class _TypedImageWork<T> extends _ImageWork {
  _TypedImageWork(this.create, super.priority, super.isRelevant);
  final Future<T> Function() create;
  final result = Completer<T>();

  @override
  Future<void> run() async {
    try {
      result.complete(await create());
    } catch (error, stack) {
      result.completeError(error, stack);
    }
  }

  @override
  void abort() => result.completeError(const TileDecodeAborted());
}
