import 'dart:convert';
import 'dart:typed_data';

import 'package:fosm/src/common/cache_tile_mixin.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

const tileWidth = 256;
const tileHeight = 256;

extension Uint8ListConvert on Uint8List {
  String convertToString() {
    return base64.encode(this);
  }
}

extension convert on String {
  Uint8List toUint8List() {
    return base64.decode(this);
  }
}

Future<void> initMap() async{
 await Hive.initFlutter();
 await CacheTiles.initCache();
}
