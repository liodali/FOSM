import 'package:fosm/src/api/tile.dart';
import 'package:hive_ce/hive.dart';

mixin CacheTiles {
  static const String boxCache = "osmTiles";
  static late Box _boxTileCache;

  Future<void> storeTile(Tile tile, String imageEncoded) async {
    _boxTileCache.put(tile.index, tile.toTileJson(imageEncoded));
  }

  Future<Tile> storedTile(String indexTile) async {
    final tileJson = _boxTileCache.get(indexTile);
    final image = await Tile.str2image(tileJson['image']);
    return Tile.fromJson(
      indexTile,
      Map.from(tileJson),
      sourceTile: image,
    );
  }

  static Future<void> storeInLazyBox() async {}
  static Future<void> initCache() async {
    await Hive.openBox(boxCache);
    _boxTileCache = Hive.box(boxCache);
  }
}
Box get box => CacheTiles._boxTileCache;