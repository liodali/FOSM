import 'dart:convert';
import 'dart:typed_data';

const tileWidth = 256;
const tileHeight = 256;


extension Uint8ListConvert on Uint8List {
  String convertToString() {
    return base64.encode(this);
  }
}
extension convert on String {
  Uint8List toUint8List(){
    return base64.decode(this);
  }
}