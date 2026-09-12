import 'dart:convert';
import 'dart:typed_data';

import 'protobuf_reader.dart';

/// Geometry kinds defined by the Mapbox Vector Tile spec.
enum MvtGeomType { unknown, point, lineString, polygon }

/// A fully decoded Mapbox Vector Tile.
///
/// Pure Dart data (no `dart:ui` types) so it can be decoded inside a
/// `compute()` isolate and copied back cheaply — geometry is kept as flat
/// [Float32List] coordinate pairs, which transfer between isolates without
/// a deep copy of boxed doubles.
class DecodedVectorTile {
  final List<DecodedLayer> layers;
  final Map<String, DecodedLayer> _layersByName;

  DecodedVectorTile(this.layers)
      : _layersByName = {
          for (final layer in layers) layer.name: layer,
        };

  /// Finds a layer by its MVT `source-layer` name in constant time.
  DecodedLayer? layerByName(String name) => _layersByName[name];
}

/// One MVT layer: a named feature table (e.g. `water`, `transportation`).
class DecodedLayer {
  final String name;

  /// Tile-local coordinate space; geometry values range 0..[extent].
  /// Almost always 4096, but read per layer per spec.
  final int extent;

  final List<DecodedFeature> features;

  DecodedLayer({
    required this.name,
    required this.extent,
    required this.features,
  });
}

/// One MVT feature with its tag table resolved into a property map.
///
/// [geometry] holds one element per part (ring / line / point): each is a
/// flat `[x0, y0, x1, y1, …]` list in tile-local units (0..extent). Polygon
/// rings are closed (first point repeated at the end).
class DecodedFeature {
  final int id;
  final MvtGeomType geomType;
  final Map<String, Object?> properties;
  final List<Float32List> geometry;

  DecodedFeature({
    required this.id,
    required this.geomType,
    required this.properties,
    required this.geometry,
  });
}

/// A sendable request used by `compute()` and the persistent native worker.
class MvtDecodeRequest {
  final Uint8List bytes;
  final Set<String>? sourceLayers;

  const MvtDecodeRequest(this.bytes, this.sourceLayers);
}

/// Thrown by the cooperative vector pipeline when the caller's relevance
/// predicate reports that the work is no longer needed.
///
/// Kept as pure Dart (no `dart:ui` or networking imports) so it can be used
/// inside the MVT isolate. The vector runtime converts it to
/// `TileDecodeAborted` at the `TileManager` boundary.
class VectorTileCancelled implements Exception {
  const VectorTileCancelled();
}

/// Decodes a [MvtDecodeRequest]. Top-level so it can be passed to `compute()`.
DecodedVectorTile decodeMvtRequest(MvtDecodeRequest request) =>
    decodeVectorTile(request.bytes, sourceLayers: request.sourceLayers);

/// Decodes raw MVT (protobuf) bytes.
///
/// When [sourceLayers] is provided, layer messages not referenced by the
/// active style are skipped before their feature tables and geometry are
/// decoded. The layer name itself is read from a zero-copy view first.
DecodedVectorTile decodeVectorTile(
  Uint8List bytes, {
  Set<String>? sourceLayers,
}) {
  final reader = ProtobufReader(bytes);
  final layers = <DecodedLayer>[];

  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    if (fieldNumber == 3 && wireType == 2) {
      final layerBytes = reader.readBytes();
      if (_shouldDecodeLayer(layerBytes, sourceLayers)) {
        layers.add(_decodeLayer(ProtobufReader(layerBytes)));
      }
    } else {
      reader.skipField(wireType);
    }
  }
  return DecodedVectorTile(layers);
}

/// Web-friendly decoder that cooperatively yields between MVT layers.
///
/// This does not create a browser worker, but it prevents a tile containing
/// many layers from monopolising the browser event loop. Native callers use
/// [decodeVectorTile] in the persistent isolate instead.
Future<DecodedVectorTile> decodeVectorTileAsync(
  Uint8List bytes, {
  Set<String>? sourceLayers,
  Duration yieldBudget = const Duration(milliseconds: 4),
  Future<void> Function()? yieldControl,
  bool Function()? isRelevant,
}) async {
  final reader = ProtobufReader(bytes);
  final layers = <DecodedLayer>[];
  final budget = _DecodeBudget(
    yieldBudget,
    yieldControl ?? () => Future<void>.delayed(Duration.zero),
    isRelevant,
  );

  budget.check();
  while (reader.hasMore) {
    budget.check();
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    if (fieldNumber == 3 && wireType == 2) {
      final layerBytes = reader.readBytes();
      if (_shouldDecodeLayer(layerBytes, sourceLayers)) {
        layers.add(await _decodeLayerAsync(
          ProtobufReader(layerBytes),
          budget,
        ));
      }
      await budget.maybeYield();
    } else {
      reader.skipField(wireType);
    }
  }
  return DecodedVectorTile(layers);
}

class _DecodeBudget {
  final Duration interval;
  final Future<void> Function() yieldControl;
  final bool Function()? isRelevant;
  final Stopwatch _stopwatch = Stopwatch()..start();

  _DecodeBudget(this.interval, this.yieldControl, this.isRelevant);

  /// Aborts with [VectorTileCancelled] when the caller reports the work is
  /// no longer relevant.
  void check() {
    final check = isRelevant;
    if (check != null && !check()) throw const VectorTileCancelled();
  }

  /// Cooperative checkpoint: yields when [interval] elapsed, then re-checks
  /// relevance after resuming so work cancelled during the yield stops.
  Future<void> maybeYield() async {
    check();
    if (_stopwatch.elapsed < interval) return;
    await yieldControl();
    _stopwatch.reset();
    check();
  }
}

bool _shouldDecodeLayer(Uint8List bytes, Set<String>? sourceLayers) {
  if (sourceLayers == null) return true;
  final reader = ProtobufReader(bytes);
  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;
    if (fieldNumber == 1 && wireType == 2) {
      return sourceLayers.contains(utf8.decode(reader.readBytes()));
    }
    reader.skipField(wireType);
  }
  return false;
}

DecodedLayer _decodeLayer(ProtobufReader reader) {
  var name = '';
  var extent = 4096;
  final features = <_RawFeature>[];
  final keys = <String>[];
  final values = <Object?>[];

  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    switch (fieldNumber) {
      case 15: // version
        reader.readVarint();
      case 1: // name
        if (wireType == 2) name = utf8.decode(reader.readBytes());
      case 2: // features
        if (wireType == 2) {
          features.add(_decodeFeature(reader.readSubMessage()));
        }
      case 3: // keys
        if (wireType == 2) keys.add(utf8.decode(reader.readBytes()));
      case 4: // values
        if (wireType == 2) values.add(_decodeValue(reader.readSubMessage()));
      case 5: // extent
        extent = reader.readVarint();
      default:
        reader.skipField(wireType);
    }
  }

  final decoded = <DecodedFeature>[];
  for (final raw in features) {
    final properties = <String, Object?>{};
    for (var i = 0; i + 1 < raw.tags.length; i += 2) {
      final keyIndex = raw.tags[i];
      final valueIndex = raw.tags[i + 1];
      if (keyIndex < keys.length && valueIndex < values.length) {
        properties[keys[keyIndex]] = values[valueIndex];
      }
    }
    decoded.add(DecodedFeature(
      id: raw.id,
      geomType: raw.geomType,
      properties: properties,
      geometry: _decodeGeometry(raw.geometry, raw.geomType),
    ));
  }

  return DecodedLayer(name: name, extent: extent, features: decoded);
}

Future<DecodedLayer> _decodeLayerAsync(
  ProtobufReader reader,
  _DecodeBudget budget,
) async {
  var name = '';
  var extent = 4096;
  final features = <_RawFeature>[];
  final keys = <String>[];
  final values = <Object?>[];

  budget.check();
  while (reader.hasMore) {
    budget.check();
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    switch (fieldNumber) {
      case 15:
        reader.readVarint();
      case 1:
        if (wireType == 2) name = utf8.decode(reader.readBytes());
      case 2:
        if (wireType == 2) {
          features.add(
            await _decodeFeatureAsync(reader.readSubMessage(), budget),
          );
        }
      case 3:
        if (wireType == 2) keys.add(utf8.decode(reader.readBytes()));
      case 4:
        if (wireType == 2) values.add(_decodeValue(reader.readSubMessage()));
      case 5:
        extent = reader.readVarint();
      default:
        reader.skipField(wireType);
    }

    await budget.maybeYield();
  }

  final decoded = <DecodedFeature>[];
  for (final raw in features) {
    budget.check();
    final properties = <String, Object?>{};
    for (var i = 0; i + 1 < raw.tags.length; i += 2) {
      final keyIndex = raw.tags[i];
      final valueIndex = raw.tags[i + 1];
      if (keyIndex < keys.length && valueIndex < values.length) {
        properties[keys[keyIndex]] = values[valueIndex];
      }
      if ((i ~/ 2 + 1) % _cooperativeCheckInterval == 0) {
        await budget.maybeYield();
      }
    }
    decoded.add(DecodedFeature(
      id: raw.id,
      geomType: raw.geomType,
      properties: properties,
      geometry: await _decodeGeometryAsync(
        raw.geometry,
        raw.geomType,
        budget,
      ),
    ));

    await budget.maybeYield();
  }

  return DecodedLayer(name: name, extent: extent, features: decoded);
}

class _RawFeature {
  final int id;
  final MvtGeomType geomType;
  final List<int> tags;
  final List<int> geometry;

  _RawFeature(this.id, this.geomType, this.tags, this.geometry);
}

_RawFeature _decodeFeature(ProtobufReader reader, {void Function()? check}) {
  var id = 0;
  var geomType = MvtGeomType.unknown;
  var tags = const <int>[];
  var geometry = const <int>[];

  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    switch (fieldNumber) {
      case 1: // id
        id = reader.readVarint();
      case 2: // tags (packed varints)
        tags = _readPackedVarints(reader, wireType, check);
      case 3: // type
        geomType = switch (reader.readVarint()) {
          1 => MvtGeomType.point,
          2 => MvtGeomType.lineString,
          3 => MvtGeomType.polygon,
          _ => MvtGeomType.unknown,
        };
      case 4: // geometry (packed varints)
        geometry = _readPackedVarints(reader, wireType, check);
      default:
        reader.skipField(wireType);
    }
  }
  return _RawFeature(id, geomType, tags, geometry);
}

Future<_RawFeature> _decodeFeatureAsync(
  ProtobufReader reader,
  _DecodeBudget budget,
) async {
  var id = 0;
  var geomType = MvtGeomType.unknown;
  var tags = const <int>[];
  var geometry = const <int>[];

  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    switch (fieldNumber) {
      case 1:
        id = reader.readVarint();
      case 2:
        tags = await _readPackedVarintsAsync(reader, wireType, budget);
      case 3:
        geomType = switch (reader.readVarint()) {
          1 => MvtGeomType.point,
          2 => MvtGeomType.lineString,
          3 => MvtGeomType.polygon,
          _ => MvtGeomType.unknown,
        };
      case 4:
        geometry = await _readPackedVarintsAsync(reader, wireType, budget);
      default:
        reader.skipField(wireType);
    }
    await budget.maybeYield();
  }
  return _RawFeature(id, geomType, tags, geometry);
}

/// How many packed varints or coordinates to process between cooperative
/// budget checks. A dense single feature must yield like many small features.
const int _cooperativeCheckInterval = 1024;

/// Packed repeated varints arrive as a length-delimited blob of back-to-back
/// varints; non-packed encodings arrive as individual varint fields.
List<int> _readPackedVarints(
  ProtobufReader reader,
  int wireType,
  void Function()? check,
) {
  if (wireType == 2) {
    final sub = reader.readSubMessage();
    final values = <int>[];
    var sinceCheck = 0;
    while (sub.hasMore) {
      values.add(sub.readVarint());
      if (check != null && ++sinceCheck >= _cooperativeCheckInterval) {
        check();
        sinceCheck = 0;
      }
    }
    return values;
  }
  return [reader.readVarint()];
}

Future<List<int>> _readPackedVarintsAsync(
  ProtobufReader reader,
  int wireType,
  _DecodeBudget budget,
) async {
  if (wireType != 2) return [reader.readVarint()];

  final sub = reader.readSubMessage();
  final values = <int>[];
  var chunkSize = 0;
  while (sub.hasMore) {
    values.add(sub.readVarint());
    if (++chunkSize >= _cooperativeCheckInterval) {
      chunkSize = 0;
      await budget.maybeYield();
    }
  }
  await budget.maybeYield();
  return values;
}

Object? _decodeValue(ProtobufReader reader) {
  Object? value;
  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    switch (fieldNumber) {
      case 1:
        if (wireType == 2) value = utf8.decode(reader.readBytes());
      case 2:
        if (wireType == 5) value = reader.readFloat32();
      case 3:
        if (wireType == 1) value = reader.readFloat64();
      case 4:
        value = reader.readVarint(); // int64
      case 5:
        value = reader.readVarint().toUnsigned(64); // uint64
      case 6:
        value = _zigzag(reader.readVarint()); // sint64
      case 7:
        value = reader.readVarint() != 0; // bool
      default:
        reader.skipField(wireType);
    }
  }
  return value;
}

/// Decodes the MVT geometry command stream into flat coordinate parts.
///
/// Commands are `(id | count << 3)` varints followed by zigzag-encoded
/// deltas: id 1 = MoveTo, 2 = LineTo, 7 = ClosePath.
List<Float32List> _decodeGeometry(List<int> commands, MvtGeomType type,
    {void Function()? check}) {
  if (commands.isEmpty) return const [];

  final parts = <Float32List>[];
  final current = <double>[];
  var x = 0.0, y = 0.0;
  var i = 0;
  var sinceCheck = 0;

  void finishPart() {
    if (current.isNotEmpty) {
      parts.add(Float32List.fromList(current));
      current.clear();
    }
  }

  while (i < commands.length) {
    if (check != null && ++sinceCheck >= _cooperativeCheckInterval) {
      check();
      sinceCheck = 0;
    }
    final command = commands[i++];
    final id = command & 0x7;
    final count = command >> 3;

    switch (id) {
      case 1: // MoveTo — starts a new part per pair.
        for (var c = 0; c < count && i + 1 < commands.length; c++) {
          x += _zigzag(commands[i++]).toDouble();
          y += _zigzag(commands[i++]).toDouble();
          finishPart();
          current
            ..add(x)
            ..add(y);
        }
      case 2: // LineTo — extends the current part.
        for (var c = 0; c < count && i + 1 < commands.length; c++) {
          x += _zigzag(commands[i++]).toDouble();
          y += _zigzag(commands[i++]).toDouble();
          current
            ..add(x)
            ..add(y);
        }
      case 7: // ClosePath — repeats the ring's first point.
        if (current.isNotEmpty && type == MvtGeomType.polygon) {
          current
            ..add(current[0])
            ..add(current[1]);
        }
        finishPart();
      default:
        // Unknown command — stop rather than desync on the deltas.
        i = commands.length;
    }
  }
  finishPart();
  return parts;
}

Future<List<Float32List>> _decodeGeometryAsync(
  List<int> commands,
  MvtGeomType type,
  _DecodeBudget budget,
) async {
  if (commands.isEmpty) return const [];

  final parts = <Float32List>[];
  final current = <double>[];
  var x = 0.0, y = 0.0;
  var i = 0;
  var chunkSize = 0;

  void finishPart() {
    if (current.isNotEmpty) {
      parts.add(Float32List.fromList(current));
      current.clear();
    }
  }

  while (i < commands.length) {
    final command = commands[i++];
    final id = command & 0x7;
    final count = command >> 3;

    switch (id) {
      case 1:
        for (var c = 0; c < count && i + 1 < commands.length; c++) {
          x += _zigzag(commands[i++]).toDouble();
          y += _zigzag(commands[i++]).toDouble();
          finishPart();
          current
            ..add(x)
            ..add(y);
          if (++chunkSize >= _cooperativeCheckInterval) {
            chunkSize = 0;
            await budget.maybeYield();
          }
        }
      case 2:
        for (var c = 0; c < count && i + 1 < commands.length; c++) {
          x += _zigzag(commands[i++]).toDouble();
          y += _zigzag(commands[i++]).toDouble();
          current
            ..add(x)
            ..add(y);
          if (++chunkSize >= _cooperativeCheckInterval) {
            chunkSize = 0;
            await budget.maybeYield();
          }
        }
      case 7:
        if (current.isNotEmpty && type == MvtGeomType.polygon) {
          current
            ..add(current[0])
            ..add(current[1]);
        }
        finishPart();
        if (++chunkSize >= _cooperativeCheckInterval) {
          chunkSize = 0;
          await budget.maybeYield();
        }
      default:
        i = commands.length;
    }
  }
  finishPart();
  await budget.maybeYield();
  return parts;
}

int _zigzag(int value) => (value >> 1) ^ -(value & 1);
