// Deterministic synthetic MVT payloads for the vector-render baseline
// (plan .plan/vector_render_improvement/01_baseline_and_attribution.md).
//
// Pure Dart (no Flutter imports) so the standalone payload server
// (tool/vector_payload_server.dart) can run it with `dart run`.
//
// Payload identity: every tile is a pure function of
// (z, x, y, profile, seed); the same inputs always produce byte-identical
// protobuf. `BenchPayloads.identity` pins the generator version so reports
// can name the exact payload family.

import 'dart:convert';
import 'dart:typed_data';

/// Payload family: feature mix tuned to resemble production city tiles.
enum BenchProfile { denseCity, suburb }

/// Builds the benchmark's fixed MVT payloads.
class BenchPayloads {
  /// Version of the generator; bump when geometry/feature counts change so
  /// old reports cannot be silently compared with new payloads.
  static const String identity = 'mvt-synth/1';

  /// Default seed; reports must record the seed actually used.
  static const int defaultSeed = 20261027;

  static const int extent = 4096;

  /// Byte-identical tile for the same inputs.
  static Uint8List tile(
    int z,
    int x,
    int y, {
    BenchProfile profile = BenchProfile.denseCity,
    int seed = defaultSeed,
  }) {
    final dense = profile == BenchProfile.denseCity;
    final tileSeed = _mix(seed, z, x, y);

    final water = MvtWriter.layer(
        name: 'water',
        keys: const ['class'],
        values: const ['river', 'lake'],
        features: _waterFeatures(_Rng(_mix(tileSeed, 1))));
    final landuse = MvtWriter.layer(
        name: 'landuse',
        keys: const ['class'],
        values: const ['park', 'residential', 'industrial'],
        features: _landuseFeatures(_Rng(_mix(tileSeed, 2)), dense ? 14 : 5));
    final buildings = MvtWriter.layer(
        name: 'building',
        keys: const [],
        values: const [],
        features:
            _buildingFeatures(_Rng(_mix(tileSeed, 3)), dense ? 1400 : 260));
    final roads = MvtWriter.layer(
        name: 'transportation',
        keys: const ['class', 'name', 'rank'],
        values: [
          'primary', 'secondary', 'trunk', 'minor', 'service', // 0..4
          'Hauptstrasse', 'Bahnhofstrasse', 'Seestrasse', 'Dorfstrasse', // 5..8
          'Quai', 'Parkweg', 'Bergweg', // 9..11
          1, 2, 3, 4, // 12..15
        ],
        features: [
          ..._majorRoadFeatures(_Rng(_mix(tileSeed, 4)), dense ? 46 : 14),
          ..._minorRoadFeatures(
              _Rng(_mix(tileSeed, 5)), dense ? 260 : 70, 'minor'),
          ..._serviceRoadFeatures(
              _Rng(_mix(tileSeed, 6)), dense ? 140 : 40, 'service'),
        ]);
    final pois = MvtWriter.layer(
        name: 'poi',
        keys: const ['name', 'rank'],
        values: const ['Apotheke', 'Bank', 'Cafe', 'Markt', 'Schule', 'Post', 1, 2],
        features: _poiFeatures(_Rng(_mix(tileSeed, 7)), dense ? 110 : 28));

    final writer = MvtTileWriter();
    writer
      ..addLayer(water)
      ..addLayer(landuse)
      ..addLayer(buildings)
      ..addLayer(roads)
      ..addLayer(pois);
    return writer.build();
  }

  // ── Layer generators (all deterministic per seeded rng) ─────────────

  /// A couple of large water polygons covering tile corners/edges.
  static List<MvtFeature> _waterFeatures(_Rng rng) {
    final features = <MvtFeature>[];
    for (var i = 0; i < 3; i++) {
      final cx = rng.range(0, extent);
      final cy = rng.range(0, extent);
      final radius = rng.range(700, 1900);
      features.add(MvtFeature(
        type: MvtGeomType.polygon,
        tags: [0, rng.nextBool() ? 0 : 1],
        geometryCommands: _ringCommands(rng, cx, cy, radius,
            rng.range(8, 14)),
      ));
    }
    return features;
  }

  static List<MvtFeature> _landuseFeatures(_Rng rng, int count) {
    return List.generate(count, (i) {
      final cx = rng.range(0, extent);
      final cy = rng.range(0, extent);
      return MvtFeature(
        type: MvtGeomType.polygon,
        tags: [0, rng.range(0, 2)],
        geometryCommands:
            _ringCommands(rng, cx, cy, rng.range(90, 360), rng.range(6, 11)),
      );
    });
  }

  /// Small rectangular building footprints filling street blocks.
  static List<MvtFeature> _buildingFeatures(_Rng rng, int count) {
    final features = <MvtFeature>[];
    for (var i = 0; i < count; i++) {
      final x = rng.range(0, extent - 60);
      final y = rng.range(0, extent - 60);
      final w = rng.range(14, 46);
      final h = rng.range(14, 46);
      features.add(MvtFeature(
        type: MvtGeomType.polygon,
        geometryCommands: polygonRingCommands([
          (x, y),
          (x + w, y),
          (x + w, y + h),
          (x, y + h),
        ]),
      ));
    }
    return features;
  }

  /// Longer major roads with names (primary/secondary/trunk classes).
  static List<MvtFeature> _majorRoadFeatures(_Rng rng, int count) {
    final features = <MvtFeature>[];
    for (var i = 0; i < count; i++) {
      final vertical = rng.nextBool();
      final start = rng.range(-200, extent + 200);
      final fixed = rng.range(0, extent);
      final points = <(int, int)>[];
      final length = rng.range(1600, 2 * extent);
      final steps = rng.range(8, 22);
      for (var s = 0; s <= steps; s++) {
        final along = start + (length * s ~/ steps);
        final wander = rng.range(-90, 90);
        points.add(vertical ? (fixed + wander, along) : (along, fixed + wander));
      }
      features.add(MvtFeature(
        type: MvtGeomType.lineString,
        tags: [
          0, rng.range(0, 2), // class: primary/secondary/trunk
          1, 5 + (i % 7), // name
          2, 12, // rank 1
        ],
        geometryCommands: lineCommands(points),
      ));
    }
    return features;
  }

  /// Gridded minor/service streets with gentle jitter.
  static List<MvtFeature> _gridRoadFeatures(
      _Rng rng, int count, int classValueIndex) {
    final features = <MvtFeature>[];
    final cols = count > 120 ? 16 : 8;
    final spacing = extent ~/ cols;
    for (var i = 0; i < count; i++) {
      final vertical = i.isEven;
      final lane = (i ~/ 2) % cols;
      final fixed = lane * spacing + rng.range(spacing ~/ 6, spacing ~/ 2);
      final start = rng.range(-spacing, extent);
      final points = <(int, int)>[];
      final steps = rng.range(6, 14);
      for (var s = 0; s <= steps; s++) {
        final along = start + ((extent + 2 * spacing) * s ~/ steps);
        final wander = rng.range(-40, 40);
        points
            .add(vertical ? (fixed + wander, along) : (along, fixed + wander));
      }
      features.add(MvtFeature(
        type: MvtGeomType.lineString,
        tags: [
          0, classValueIndex, // class: minor | service
          if (rng.nextBool()) ...[1, 5 + (i % 7)], // some names
          2, 13 + (i % 3), // rank 2..4
        ],
        geometryCommands: lineCommands(points),
      ));
    }
    return features;
  }

  static List<MvtFeature> _minorRoadFeatures(_Rng rng, int count, _) =>
      _gridRoadFeatures(rng, count, 3);

  static List<MvtFeature> _serviceRoadFeatures(_Rng rng, int count, _) =>
      _gridRoadFeatures(rng, count, 4);

  static List<MvtFeature> _poiFeatures(_Rng rng, int count) {
    return List.generate(count, (i) {
      return MvtFeature(
        type: MvtGeomType.point,
        tags: [0, i % 6, 1, 6 + (i % 2)],
        geometryCommands: pointCommands(
            rng.range(0, extent), rng.range(0, extent)),
      );
    });
  }

  /// Closed irregular ring around a centre.
  static List<int> _ringCommands(_Rng rng, int cx, int cy, int radius, int vertices) {
    final points = <(int, int)>[];
    for (var i = 0; i < vertices; i++) {
      final angle = 2 * 3.141592653589793 * i / vertices;
      final r = radius * (0.7 + 0.3 * (rng.range(0, 100) / 100));
      points.add((cx + (r * _cos(angle)).round(), cy + (r * _sin(angle)).round()));
    }
    return polygonRingCommands(points);
  }

  static double _cos(double a) {
    // A coarse table keeps this pure and deterministic without dart:math.
    const table = [
      1.0, 0.9952, 0.9808, 0.9569, 0.9239, 0.8819, 0.8315, 0.7730,
      0.7071, 0.6344, 0.5556, 0.4714, 0.3827, 0.2903, 0.1951, 0.0980,
      0.0, -0.0980, -0.1951, -0.2903, -0.3827, -0.4714, -0.5556, -0.6344,
      -0.7071, -0.7730, -0.8315, -0.8819, -0.9239, -0.9569, -0.9808, -0.9952,
    ];
    return table[(((a * table.length) / (2 * 3.141592653589793)).floor() %
        table.length)];
  }

  static double _sin(double a) => _cos(a - 3.141592653589793 / 2);

  /// Combines ints into one seed (FNV-style mixing); unused slots are 0.
  static int _mix(int a, [int b = 0, int c = 0, int d = 0]) {
    var hash = 0x811c9dc5;
    for (final value in [a, b, c, d]) {
      hash ^= value & 0xff;
      hash = (hash * 0x01000193) & 0x7fffffff;
      hash ^= (value >> 8) & 0xff;
      hash = (hash * 0x01000193) & 0x7fffffff;
      hash ^= (value >> 16) & 0xff;
      hash = (hash * 0x01000193) & 0x7fffffff;
      hash ^= (value >> 24) & 0xff;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash | 1;
  }
}

/// Small deterministic LCG (keeping the generator free of `dart:math`
/// removes any doubt about cross-platform math behaviour).
class _Rng {
  int _state;
  _Rng(this._state);

  int next() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state;
  }

  bool nextBool() => next() & 1 == 1;

  /// Inclusive integer range.
  int range(int min, int max) => min + (next() % (max - min + 1));
}

// ── Minimal MVT protobuf writer (example-side twin of the package test
//    builder; kept local so the benchmark never imports test code). ──────

enum MvtGeomType { point, lineString, polygon }

class MvtFeature {
  final MvtGeomType type;

  /// Tag indexes into the layer's keys/values tables: `[k0, v0, k1, v1…]`.
  final List<int> tags;
  final List<int> geometryCommands;

  const MvtFeature({
    required this.type,
    this.tags = const [],
    required this.geometryCommands,
  });
}

class MvtLayer {
  final String name;
  final List<String> keys;
  final List<Object> values;
  final List<MvtFeature> features;
  MvtLayer({
    required this.name,
    required this.keys,
    required this.values,
    required this.features,
  });
}

class MvtWriter {
  static MvtLayer layer({
    required String name,
    List<String> keys = const [],
    List<Object> values = const [],
    required List<MvtFeature> features,
  }) =>
      MvtLayer(name: name, keys: keys, values: values, features: features);
}

class MvtTileWriter {
  final BytesBuilder _tile = BytesBuilder();

  void addLayer(MvtLayer layer) {
    final b = BytesBuilder();

    _stringField(b, 1, layer.name); // name

    for (final feature in layer.features) {
      _lengthDelimited(b, 2, _buildFeature(feature));
    }
    for (final key in layer.keys) {
      _stringField(b, 3, key);
    }
    for (final value in layer.values) {
      _lengthDelimited(b, 4, _buildValue(value));
    }

    _varintField(b, 5, BenchPayloads.extent); // extent
    _varintField(b, 15, 2); // version

    _lengthDelimited(_tile, 3, b.takeBytes());
  }

  Uint8List build() => _tile.takeBytes();

  static Uint8List _buildFeature(MvtFeature feature) {
    final b = BytesBuilder();
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

  static Uint8List _buildValue(Object value) {
    final b = BytesBuilder();
    switch (value) {
      case String s:
        _stringField(b, 1, s);
      case int i:
        _varintField(b, 4, i); // int_value
      case double d:
        final payload =
            (ByteData(8)..setFloat64(0, d, Endian.little)).buffer.asUint8List();
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

extension on MvtGeomType {
  int get mvtId => switch (this) {
        MvtGeomType.point => 1,
        MvtGeomType.lineString => 2,
        MvtGeomType.polygon => 3,
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
