import 'dart:convert';
import 'dart:typed_data';

/// Minimal protobuf *writer* for tests — builds valid MVT bytes without a
/// dependency, mirroring the reader in `lib/src/vector/mvt/`.

enum TestGeomType { point, lineString, polygon }

class TestFeature {
  final int id;
  final TestGeomType type;

  /// Tag indexes into the layer's keys/values tables: `[k0, v0, k1, v1…]`.
  final List<int> tags;

  /// Raw geometry command stream (see [polygonRingCommands], …).
  final List<int> geometryCommands;

  const TestFeature({
    this.id = 0,
    required this.type,
    this.tags = const [],
    required this.geometryCommands,
  });
}

class MvtBuilder {
  final BytesBuilder _tile = BytesBuilder();

  void addLayer({
    required String name,
    int extent = 4096,
    List<String> keys = const [],
    List<Object?> values = const [],
    List<TestFeature> features = const [],
  }) {
    final layer = BytesBuilder();

    _stringField(layer, 1, name); // name

    for (final feature in features) {
      _lengthDelimited(layer, 2, _buildFeature(feature));
    }
    for (final key in keys) {
      _stringField(layer, 3, key);
    }
    for (final value in values) {
      _lengthDelimited(layer, 4, _buildValue(value));
    }

    _varintField(layer, 5, extent); // extent
    _varintField(layer, 15, 2); // version

    _lengthDelimited(_tile, 3, layer.takeBytes());
  }

  Uint8List build() => _tile.takeBytes();

  static Uint8List _buildFeature(TestFeature feature) {
    final b = BytesBuilder();
    if (feature.id != 0) _varintField(b, 1, feature.id);

    if (feature.tags.isNotEmpty) {
      final packed = BytesBuilder();
      for (final tag in feature.tags) {
        _varint(packed, tag);
      }
      _lengthDelimited(b, 2, packed.takeBytes());
    }

    _varintField(b, 3, feature.type.mvtId);

    if (feature.geometryCommands.isNotEmpty) {
      final packed = BytesBuilder();
      for (final cmd in feature.geometryCommands) {
        _varint(packed, cmd);
      }
      _lengthDelimited(b, 4, packed.takeBytes());
    }
    return b.takeBytes();
  }

  static Uint8List _buildValue(Object? value) {
    final b = BytesBuilder();
    switch (value) {
      case String s:
        _stringField(b, 1, s);
      case int i:
        _varintField(b, 4, i); // int_value
      case double d:
        final payload = (ByteData(8)..setFloat64(0, d, Endian.little))
            .buffer
            .asUint8List();
        _varint(b, (3 << 3) | 1); // double_value (field 3, 64-bit)
        b.add(payload);
      case bool v:
        _varintField(b, 7, v ? 1 : 0);
    }
    return b.takeBytes();
  }

  // ── Wire primitives ────────────────────────────────────────────────

  static void _varint(BytesBuilder b, int value) {
    var v = value;
    while (true) {
      final byte = v & 0x7F;
      v = v >>> 7;
      if (v == 0) {
        b.addByte(byte);
        return;
      }
      b.addByte(byte | 0x80);
    }
  }

  static void _varintField(BytesBuilder b, int field, int value) {
    _varint(b, (field << 3) | 0);
    _varint(b, value);
  }

  static void _lengthDelimited(BytesBuilder b, int field, List<int> payload) {
    _varint(b, (field << 3) | 2);
    _varint(b, payload.length);
    b.add(payload);
  }

  static void _stringField(BytesBuilder b, int field, String value) =>
      _lengthDelimited(b, field, utf8.encode(value));
}

extension on TestGeomType {
  int get mvtId => switch (this) {
        TestGeomType.point => 1,
        TestGeomType.lineString => 2,
        TestGeomType.polygon => 3,
      };
}

// ── Geometry command helpers ────────────────────────────────────────────────

/// Zigzag-encodes a delta for the geometry command stream.
int zz(int value) => (value << 1) ^ (value < 0 ? -1 : 0);

/// Command stream for a closed polygon ring through [points] (absolute
/// tile coordinates).
List<int> polygonRingCommands(List<(int, int)> points) {
  final commands = <int>[];
  var x = 0, y = 0;
  for (var i = 0; i < points.length; i++) {
    final (px, py) = points[i];
    if (i == 0) {
      commands
        ..add(1 | (1 << 3)) // MoveTo ×1
        ..add(zz(px - x))
        ..add(zz(py - y));
    } else {
      if (i == 1) commands.add(2 | ((points.length - 1) << 3)); // LineTo ×n
      commands
        ..add(zz(px - x))
        ..add(zz(py - y));
    }
    x = px;
    y = py;
  }
  commands.add(7 | (1 << 3)); // ClosePath
  return commands;
}

/// Command stream for a single point feature.
List<int> pointCommands(int x, int y) => [1 | (1 << 3), zz(x), zz(y)];

/// Command stream for one linestring through [points].
List<int> lineCommands(List<(int, int)> points) {
  final commands = <int>[];
  var x = 0, y = 0;
  for (var i = 0; i < points.length; i++) {
    final (px, py) = points[i];
    if (i == 0) {
      commands
        ..add(1 | (1 << 3))
        ..add(zz(px - x))
        ..add(zz(py - y));
    } else {
      if (i == 1) commands.add(2 | ((points.length - 1) << 3));
      commands
        ..add(zz(px - x))
        ..add(zz(py - y));
    }
    x = px;
    y = py;
  }
  return commands;
}

/// Assembles a one-layer tile with a full-coverage polygon, a point and a
/// line — the standard fixture for decoder/pipeline tests.
Uint8List buildTestTile({String layerName = 'water', int extent = 4096}) {
  final builder = MvtBuilder();
  builder.addLayer(
    name: layerName,
    extent: extent,
    keys: const ['class', 'rank'],
    values: const ['sea', 3],
    features: [
      TestFeature(
        id: 42,
        type: TestGeomType.polygon,
        tags: const [0, 0, 1, 1],
        geometryCommands: polygonRingCommands(
          const [(0, 0), (4096, 0), (4096, 4096), (0, 4096)],
        ),
      ),
      TestFeature(
        id: 7,
        type: TestGeomType.point,
        tags: const [0, 0],
        geometryCommands: pointCommands(100, 200),
      ),
      TestFeature(
        id: 8,
        type: TestGeomType.lineString,
        geometryCommands: lineCommands(
          const [(10, 10), (1000, 10), (1000, 2000)],
        ),
      ),
    ],
  );
  return builder.build();
}
