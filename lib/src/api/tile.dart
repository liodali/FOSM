import 'dart:ui' as ui;

import 'package:fosm/src/common/utils.dart';

class Tile {
  final ui.Image? sourceTile;
  final String index;
  final int latIndex;
  final int lngIndex;

  Tile(
    this.sourceTile,
    this.index,
    this.latIndex,
    this.lngIndex,
  );
  Tile.fromJson(
    String indexTile,
    Map<String, dynamic> tileJson, {
    required this.sourceTile,
  })  : index = indexTile,
        latIndex = tileJson['latIndex'],
        lngIndex = tileJson['lngIndex'];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is Tile &&
        sourceTile.toString() == other.sourceTile.toString();
  }

  @override
  int get hashCode =>
      sourceTile.hashCode ^
      index.hashCode ^
      latIndex.hashCode ^
      lngIndex.hashCode;

  Map toTileJson(String? imageEncoded) => {
        'latIndex': latIndex,
        'lngIndex': lngIndex,
        'image': imageEncoded,
      };

  Future<String?> image2string(image) async {
    final bytes = await sourceTile?.toByteData();
    return bytes?.buffer.asUint8List().convertToString();
  }

  static Future<ui.Image> str2image(String imageString) async {
    ui.Codec codec = await ui.instantiateImageCodec(imageString.toUint8List());
    ui.FrameInfo frameInfo = await codec.getNextFrame();
    return frameInfo.image;
  }
}
