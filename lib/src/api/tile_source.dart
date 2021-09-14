import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../common/utils.dart';

Future<String> getTile(int z, int x, int y) async {
  Response<Uint8List> response = await Dio().get(
    "https://tile.openstreetmap.org/$z/$x/$y.png",
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
