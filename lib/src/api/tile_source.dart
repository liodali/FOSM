import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fosm/src/common/utils.dart';

Future<String> downloadTile(String url) async {
  Response<Uint8List> response = await Dio().get(
    url,
    options: Options(
      responseType: ResponseType.bytes,
      validateStatus: (status) {
        if (status != null) return status < 500;
        return false;
      },
    ),
  );
  return response.data!.convertToString();
}

Future<String> getTile(int z, int x, int y) async {
  String url = "https://tile.openstreetmap.org/$z/$x/$y.png";
  print(url);
  return compute(downloadTile, url);
}
