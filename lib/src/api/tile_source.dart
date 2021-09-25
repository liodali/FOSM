import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../common/utils.dart';

Future<String> getTile(int z, int x, int y) async {
  String url = "https://tile.openstreetmap.org/$z/$x/$y.png";
  print(url);
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
