import 'dart:typed_data';
import 'dart:ui' as ui;

/// A single map tile: either a decoded [sourceTile] image or a placeholder
/// (`null` image) while loading.
///
/// The [index] is a unique string key in the format `"z/x/y"` used for
/// cache lookups and deduplication. [lngIndex] and [latIndex] are the
/// integer tile coordinates (x = longitude, y = latitude) at the current
/// zoom level.
class Tile {
  final ui.Image? sourceTile;
  final String index;
  final int latIndex;
  final int lngIndex;

  Tile(this.sourceTile, this.index, this.latIndex, this.lngIndex);

  Tile.fromJson(
    String indexTile,
    Map<String, dynamic> tileJson, {
    required this.sourceTile,
  })  : index = indexTile,
        latIndex = tileJson['latIndex'] as int,
        lngIndex = tileJson['lngIndex'] as int;

  /// Returns a copy with [sourceTile] replaced.
  Tile copyWithImage(ui.Image image) =>
      Tile(image, index, latIndex, lngIndex);

  /// Serializes to a Hive-friendly map. [imageBytes] is the raw PNG data.
  Map<String, dynamic> toTileJson(Uint8List imageBytes) => {
        'latIndex': latIndex,
        'lngIndex': lngIndex,
        'image': imageBytes,
      };

  /// Decodes raw image bytes into a [ui.Image]. Disposes the codec after
  /// extraction (the returned image remains valid).
  static Future<ui.Image> decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }
}
