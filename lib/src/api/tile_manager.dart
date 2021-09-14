import 'tile.dart';

class TileManager {
  int maxSizeTileCached = 8125 * 2;

  List<Tile> renderTiles = [];
  List<Tile> cachedTiles = [];
}
