import 'dart:typed_data';

import 'dart:ui';

class Tile {
  final Image? sourceTile;
  final String index;
  final int latIndex;
  final int lngIndex;

  Tile(
    this.sourceTile,
    this.index,
    this.latIndex,
    this.lngIndex,
  );

  @override
  bool operator ==(Object other) {
    return sourceTile == (other as Tile).sourceTile;
  }
}
