import 'dart:convert';
import 'dart:ui' as ui;

import '../../api/tile_source.dart' show downloadTileBytes;
import '../../api/tile.dart' show Tile;

/// A loaded style sprite sheet: one PNG atlas plus the JSON metadata that
/// names each icon's rectangle.
class SpriteAtlas {
  final ui.Image image;
  final Map<String, ui.Rect> icons;

  SpriteAtlas(this.image, this.icons);

  /// Loads `{baseUrl}.json` + `{baseUrl}.png` (with `@2x` variants on
  /// high-density screens). Returns `null` on any failure — missing icons
  /// simply don't render.
  static Future<SpriteAtlas?> load(String baseUrl, {double pixelRatio = 1}) {
    final suffix = pixelRatio >= 2 ? '@2x' : '';
    return _load('$baseUrl$suffix', pixelRatio >= 2 ? 2.0 : 1.0)
        .catchError((_) => null);
  }

  static Future<SpriteAtlas?> _load(String base, double scale) async {
    final jsonBytes = await downloadTileBytes('$base.json');
    final metadata = jsonDecode(utf8.decode(jsonBytes));
    if (metadata is! Map) return null;

    final imageBytes = await downloadTileBytes('$base.png');
    final image = await Tile.decodeImage(imageBytes);

    final icons = <String, ui.Rect>{};
    for (final entry in metadata.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final x = (value['x'] as num?)?.toDouble();
      final y = (value['y'] as num?)?.toDouble();
      final w = (value['width'] as num?)?.toDouble();
      final h = (value['height'] as num?)?.toDouble();
      if (x == null || y == null || w == null || h == null) continue;
      icons[entry.key.toString()] = ui.Rect.fromLTWH(x, y, w, h);
    }
    return SpriteAtlas(image, icons);
  }

  /// Resolves an icon name, falling back to the classic `-11`/`-15` size
  /// suffixes used by Carto/Mapbox styles.
  ui.Rect? rectFor(String name) =>
      icons[name] ?? icons['$name-15'] ?? icons['$name-11'];

  /// Draws [name] centered at [center], scaled by [size].
  void draw(ui.Canvas canvas, String name, ui.Offset center, double size) {
    final rect = rectFor(name);
    if (rect == null) return;
    canvas.drawImageRect(
      image,
      rect,
      ui.Rect.fromCenter(
        center: center,
        width: rect.width * size,
        height: rect.height * size,
      ),
      _paint,
    );
  }

  void dispose() => image.dispose();

  static final ui.Paint _paint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium;
}
