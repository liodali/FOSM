import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/common/rendered_tile_cache.dart';

ui.Image _image(int width, int height) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xFF336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

void main() {
  group('Rendered tile cache', () {
    testWidgets('evicts by pixel bytes in least-recently-used order',
        (tester) async {
      final cache = RenderedTileCache(maxBytes: 36);
      addTearDown(cache.dispose);
      final first = _image(2, 2);
      final second = _image(2, 2);
      final small = _image(1, 1);
      cache.put('first', first);
      cache.put('second', second);
      cache.put('small', small);
      expect(cache.bytes, 36);
      expect(cache.get('first'), same(first));

      final large = _image(2, 2);
      cache.put('large', large);
      expect(second.debugDisposed, isTrue);
      expect(first.debugDisposed, isFalse);
      expect(small.debugDisposed, isFalse);
      expect(cache.bytes, 36);
      expect(cache.length, 3);
      cache.dispose();
    });

    testWidgets(
        'protects active grids and overlapping snapshots at zero budget',
        (tester) async {
      final cache = RenderedTileCache(maxBytes: 0);
      addTearDown(cache.dispose);
      cache.setActiveKeys({'old'});
      final old = _image(2, 2);
      cache.put('old', old);
      final releaseFirst = cache.pin(['old', 'old']);
      final releaseSecond = cache.pin(['old']);

      cache.setActiveKeys({'new'});
      final current = _image(2, 2);
      cache.put('new', current);
      expect(cache.bytes, 32);
      expect(old.debugDisposed, isFalse);
      expect(current.debugDisposed, isFalse);
      releaseFirst();
      releaseFirst();
      expect(old.debugDisposed, isFalse);
      releaseSecond();
      expect(old.debugDisposed, isTrue);
      expect(current.debugDisposed, isFalse);
      expect(cache.bytes, 16);

      cache.setActiveKeys({});
      expect(current.debugDisposed, isTrue);
      expect(cache.bytes, 0);
    });

    testWidgets('expires idle tiles without another camera update',
        (tester) async {
      var now = DateTime(2026);
      final cache = RenderedTileCache(now: () => now);
      addTearDown(cache.dispose);
      cache.setActiveKeys({'tile'});
      final image = _image(1, 1);
      cache.put('tile', image);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(image.debugDisposed, isFalse);

      cache.setActiveKeys({});
      now = now.add(const Duration(seconds: 19));
      await tester.pump(const Duration(seconds: 19));
      expect(image.debugDisposed, isFalse);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(image.debugDisposed, isTrue);
      expect(cache.bytes, 0);
    });

    testWidgets('returning to a tile renews its idle retention',
        (tester) async {
      var now = DateTime(2026);
      final cache = RenderedTileCache(now: () => now);
      addTearDown(cache.dispose);
      cache.setActiveKeys({'tile'});
      final image = _image(1, 1);
      cache.put('tile', image);
      cache.setActiveKeys({});
      now = now.add(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      cache.setActiveKeys({'tile'});
      expect(cache.get('tile'), same(image));
      now = now.add(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      cache.setActiveKeys({});
      now = now.add(const Duration(seconds: 19));
      await tester.pump(const Duration(seconds: 19));
      expect(image.debugDisposed, isFalse);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(image.debugDisposed, isTrue);
    });

    testWidgets('policy changes trim unused images and disposal releases pins',
        (tester) async {
      final cache = RenderedTileCache();
      addTearDown(cache.dispose);
      cache.setActiveKeys({'pinned'});
      final pinned = _image(1, 1);
      cache.put('pinned', pinned);
      final release = cache.pin(['pinned']);
      cache.setActiveKeys({});
      final unused = _image(1, 1);
      cache.put('unused', unused);
      cache.updatePolicy(maxBytes: 0, retention: Duration.zero);
      expect(unused.debugDisposed, isTrue);
      expect(pinned.debugDisposed, isFalse);
      cache.dispose();
      expect(pinned.debugDisposed, isTrue);
      expect(cache.bytes, 0);
      release();
      cache.dispose();
    });

    testWidgets('duplicate completion disposes only the redundant image',
        (tester) async {
      final cache = RenderedTileCache();
      addTearDown(cache.dispose);
      final original = _image(1, 1);
      final redundant = _image(1, 1);
      cache.put('tile', original);
      final release = cache.pin(['tile']);
      expect(cache.put('tile', redundant), same(original));
      expect(redundant.debugDisposed, isTrue);
      expect(original.debugDisposed, isFalse);
      expect(cache.bytes, 4);
      release();
      cache.dispose();
    });

    test('rejects negative policies', () {
      expect(() => RenderedTileCache(maxBytes: -1), throwsArgumentError);
      expect(
        () => RenderedTileCache(retention: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });
}
