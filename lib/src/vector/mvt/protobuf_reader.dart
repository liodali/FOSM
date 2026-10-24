import 'dart:typed_data';

/// Minimal protobuf wire-format reader — just enough to decode Mapbox
/// Vector Tiles without a generated parser or an extra dependency.
///
/// Supports the four wire types the MVT schema uses (varint, 64-bit,
/// length-delimited, 32-bit); unknown fields can be skipped so future
/// schema revisions still decode.
class ProtobufReader {
  final Uint8List _data;
  final ByteData _bytes;
  final int _end;
  int _pos;

  ProtobufReader(Uint8List data, [int offset = 0, int? length])
      : _data = data,
        _bytes = ByteData.sublistView(data),
        _pos = offset,
        _end = offset + (length ?? data.length - offset);

  /// Whether more bytes remain in the current range.
  bool get hasMore => _pos < _end;

  /// Reads a base-128 varint (up to 64 bits).
  ///
  /// Bytes below bit 28 use shifts/OR like before; higher bytes are folded
  /// in with exact power-of-two multiplication because dart2js truncates
  /// `<<` to 32 bits and returns *unsigned* results for `|`, which would
  /// silently corrupt every varint larger than four bytes on the web.
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      _requireBytes(1);
      final byte = _data[_pos++];
      final bits = byte & 0x7F;
      if (shift < 28) {
        result |= bits << shift;
      } else {
        result += bits * _highByteScale(shift);
      }
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift >= 64) throw const FormatException('varint too long');
    }
  }

  /// Exact powers of two for the high varint bytes (shifts ≥ 28). All are
  /// exactly representable as doubles, so web and native agree up to 2^53;
  /// the final byte wraps like a 64-bit two's-complement overflow on the VM.
  static int _highByteScale(int shift) => switch (shift) {
        28 => 268435456, // 2^28
        35 => 34359738368, // 2^35
        42 => 4398046511104, // 2^42
        49 => 562949953421312, // 2^49
        56 => 72057594037927936, // 2^56
        // 2^63 via exact factors: wraps to min int64 on the VM (protobuf
        // two's-complement wrap) and is exact as a double on the web.
        _ => 8 * 268435456 * 268435456 * 268435456,
      };

  /// Reads a 4-byte little-endian float (wire type 5).
  double readFloat32() {
    _requireBytes(4);
    final value = _bytes.getFloat32(_pos, Endian.little);
    _pos += 4;
    return value;
  }

  /// Reads an 8-byte little-endian double (wire type 1).
  double readFloat64() {
    _requireBytes(8);
    final value = _bytes.getFloat64(_pos, Endian.little);
    _pos += 8;
    return value;
  }

  /// Reads a length-prefixed byte range (wire type 2) as a zero-copy view.
  Uint8List readBytes() {
    final length = readVarint();
    _requireBytes(length);
    final view = Uint8List.sublistView(_data, _pos, _pos + length);
    _pos += length;
    return view;
  }

  /// Returns a sub-reader over the next length-delimited field without
  /// copying, and advances past it.
  ProtobufReader readSubMessage() {
    final length = readVarint();
    _requireBytes(length);
    final sub = ProtobufReader(_data, _pos, length);
    _pos += length;
    return sub;
  }

  /// Skips a field value of the given [wireType].
  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _requireBytes(8);
        _pos += 8;
      case 2:
        final length = readVarint();
        _requireBytes(length);
        _pos += length;
      case 5:
        _requireBytes(4);
        _pos += 4;
      default:
        throw FormatException('unsupported wire type $wireType');
    }
  }

  void _requireBytes(int count) {
    if (_pos + count > _end) {
      throw const FormatException('truncated protobuf message');
    }
  }
}
