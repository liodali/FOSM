// Web implementation: decodes MVT bytes in a dedicated Web Worker so the
// main thread stays responsive.
//
// The JS worker code is embedded as a string constant and loaded via a
// Blob URL at first use. This avoids external file dependencies — the
// package works as a drop-in dependency.
//
// Protocol:
//   Dart → Worker:  Uint8Array (raw MVT .pbf bytes)
//   Worker → Dart:  JSON string → jsonDecode → DecodedVectorTile

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../vector/mvt/vector_tile.dart';

// ── Worker state ──────────────────────────────────────────────────────────

JSObject? _worker;
bool _workerInitAttempted = false;

/// Decodes MVT bytes in a Web Worker. Falls back to synchronous decoding
/// on the main thread if the worker fails to initialize.
Future<DecodedVectorTile> decodeMvtAsync(Uint8List bytes) async {
  _ensureWorker();
  if (_worker == null) {
    // Worker failed to initialize — fall back to main thread.
    return decodeVectorTile(bytes);
  }

  final jsonStr = await _postAndReceive(bytes);
  final map = jsonDecode(jsonStr) as Map<String, dynamic>;

  if (map.containsKey('error')) {
    throw FormatException('MVT worker error: ${map['error']}');
  }

  return _tileFromJson(map);
}

/// Web Workers run on a separate thread.
bool get isMvtDecodeThreaded => _worker != null;

// ── Worker lifecycle ──────────────────────────────────────────────────────

void _ensureWorker() {
  if (_worker != null || _workerInitAttempted) return;
  _workerInitAttempted = true;

  try {
    final global = globalContext;

    // Create a Blob from the JS worker source.
    final blobParts = [_workerJs.toJS].toJS;
    final options = {'type': 'application/javascript'}.jsify();
    final blobCtor = global.getProperty('Blob'.toJS) as JSFunction;
    final blob = blobCtor.callAsConstructor(blobParts, options) as JSObject;

    // Create an object URL for the blob.
    final urlObj = global.getProperty('URL'.toJS) as JSObject;
    final url = (urlObj.callMethod('createObjectURL'.toJS, blob) as JSString).toDart;

    // Create the Worker.
    final workerCtor = global.getProperty('Worker'.toJS) as JSFunction;
    final w = workerCtor.callAsConstructor(url.toJS) as JSObject;
    _worker = w;
  } catch (_) {
    _worker = null;
  }
}

/// Sends [bytes] to the worker and waits for the JSON response.
Future<String> _postAndReceive(Uint8List bytes) {
  final completer = Completer<String>();
  final worker = _worker!;

  // We need to hold references to remove listeners after use.
  JSFunction? messageListener;
  JSFunction? errorListener;

  messageListener = (JSAny? event) {
    // event.data is the JSON string from the worker.
    final eventObj = event as JSObject;
    final data = eventObj.getProperty('data'.toJS);
    final str = data.dartify() as String? ?? data.toString();
    if (!completer.isCompleted) completer.complete(str);
    worker.callMethod('removeEventListener'.toJS, 'message'.toJS, messageListener!);
    worker.callMethod('removeEventListener'.toJS, 'error'.toJS, errorListener!);
  }.toJS;

  errorListener = (JSAny? event) {
    if (!completer.isCompleted) {
      completer.completeError(Exception('MVT worker error'));
    }
    worker.callMethod('removeEventListener'.toJS, 'message'.toJS, messageListener!);
    worker.callMethod('removeEventListener'.toJS, 'error'.toJS, errorListener!);
  }.toJS;

  worker.callMethod('addEventListener'.toJS, 'message'.toJS, messageListener);
  worker.callMethod('addEventListener'.toJS, 'error'.toJS, errorListener);

  // Convert bytes to a JS Uint8Array (copies the data, safe to transfer).
  final jsBytes = Uint8List.fromList(bytes).toJS;
  worker.callMethod('postMessage'.toJS, jsBytes);

  return completer.future;
}

// ── JSON → DecodedVectorTile ─────────────────────────────────────────────

DecodedVectorTile _tileFromJson(Map<String, dynamic> json) {
  final layersJson = json['layers'] as List? ?? const [];
  return DecodedVectorTile([
    for (final l in layersJson) _layerFromJson(l as Map<String, dynamic>),
  ]);
}

DecodedLayer _layerFromJson(Map<String, dynamic> json) {
  final featuresJson = json['features'] as List? ?? const [];
  return DecodedLayer(
    name: json['name'] as String? ?? '',
    extent: json['extent'] as int? ?? 4096,
    features: [
      for (final f in featuresJson)
        _featureFromJson(f as Map<String, dynamic>),
    ],
  );
}

DecodedFeature _featureFromJson(Map<String, dynamic> json) {
  final geomType = switch (json['geomType'] as int? ?? 0) {
    1 => MvtGeomType.point,
    2 => MvtGeomType.lineString,
    3 => MvtGeomType.polygon,
    _ => MvtGeomType.unknown,
  };

  final geomJson = json['geometry'] as List? ?? const [];
  final geometry = <Float32List>[
    for (final part in geomJson)
      Float32List.fromList(
        (part as List).map((v) => (v as num).toDouble()).toList(),
      ),
  ];

  final propsJson = json['properties'] as Map<String, dynamic>? ?? const {};

  return DecodedFeature(
    id: json['id'] as int? ?? 0,
    geomType: geomType,
    properties: propsJson,
    geometry: geometry,
  );
}

// ── Embedded JS worker source ────────────────────────────────────────────
//
// Same code as mvt_decode_worker.js, embedded as a string constant so
// the package works without external file dependencies. The standalone
// .js file is provided alongside for reference and for users who want
// to host it separately.

const String _workerJs = r'''
"use strict";

class ProtobufReader {
  constructor(data, offset, length) {
    this.data = data;
    this.pos = offset || 0;
    this.end = offset != null && length != null ? offset + length : data.length;
  }
  get hasMore() { return this.pos < this.end; }
  readVarint() {
    let result = 0, shift = 0;
    while (true) {
      if (this.pos >= this.end) throw new Error("truncated varint");
      const byte = this.data[this.pos++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) === 0) return result >>> 0;
      shift += 7;
      if (shift >= 64) throw new Error("varint too long");
    }
  }
  readBytes() {
    const length = this.readVarint();
    if (this.pos + length > this.end) throw new Error("truncated bytes");
    const view = this.data.subarray(this.pos, this.pos + length);
    this.pos += length;
    return view;
  }
  readSubMessage() {
    const length = this.readVarint();
    if (this.pos + length > this.end) throw new Error("truncated sub-message");
    const sub = new ProtobufReader(this.data, this.pos, length);
    this.pos += length;
    return sub;
  }
  skipField(wireType) {
    switch (wireType) {
      case 0: this.readVarint(); break;
      case 1: this.pos += 8; break;
      case 2: { const l = this.readVarint(); this.pos += l; break; }
      case 5: this.pos += 4; break;
      default: throw new Error("unsupported wire type " + wireType);
    }
  }
}

function zigzag(v) { return (v >>> 1) ^ -(v & 1); }

function decodeGeometry(commands, geomType) {
  if (!commands || commands.length === 0) return [];
  const parts = [];
  let current = [];
  let x = 0, y = 0;
  let i = 0;
  function finishPart() {
    if (current.length > 0) { parts.push(current); current = []; }
  }
  while (i < commands.length) {
    const cmd = commands[i++];
    const id = cmd & 0x7;
    const count = cmd >> 3;
    switch (id) {
      case 1:
        for (let c = 0; c < count && i + 1 < commands.length; c++) {
          x += zigzag(commands[i++]);
          y += zigzag(commands[i++]);
          finishPart();
          current.push(x, y);
        }
        break;
      case 2:
        for (let c = 0; c < count && i + 1 < commands.length; c++) {
          x += zigzag(commands[i++]);
          y += zigzag(commands[i++]);
          current.push(x, y);
        }
        break;
      case 7:
        if (current.length > 0 && geomType === 3) {
          current.push(current[0], current[1]);
        }
        finishPart();
        break;
      default:
        i = commands.length;
    }
  }
  finishPart();
  return parts;
}

function readPackedVarints(reader, wireType) {
  if (wireType === 2) {
    const sub = reader.readSubMessage();
    const values = [];
    while (sub.hasMore) values.push(sub.readVarint());
    return values;
  }
  return [reader.readVarint()];
}

function decodeFeature(reader) {
  let id = 0, geomType = 0, tags = [], geometry = [];
  while (reader.hasMore) {
    const tag = reader.readVarint();
    const fn = tag >> 3, wt = tag & 0x7;
    switch (fn) {
      case 1: id = reader.readVarint(); break;
      case 2: tags = readPackedVarints(reader, wt); break;
      case 3: geomType = reader.readVarint(); break;
      case 4: geometry = readPackedVarints(reader, wt); break;
      default: reader.skipField(wt);
    }
  }
  return { id: id, geomType: geomType, tags: tags, geometry: geometry };
}

function decodeValue(reader) {
  let value = null;
  while (reader.hasMore) {
    const tag = reader.readVarint();
    const fn = tag >> 3, wt = tag & 0x7;
    switch (fn) {
      case 1: if (wt === 2) value = new TextDecoder().decode(reader.readBytes()); break;
      case 2: reader.pos += 4; break;
      case 3: reader.pos += 8; break;
      case 4: value = reader.readVarint(); break;
      case 5: value = reader.readVarint(); break;
      case 6: value = zigzag(reader.readVarint()); break;
      case 7: value = reader.readVarint() !== 0; break;
      default: reader.skipField(wt);
    }
  }
  return value;
}

function decodeLayer(reader) {
  let name = "", extent = 4096;
  const rawFeatures = [], keys = [], values = [];
  while (reader.hasMore) {
    const tag = reader.readVarint();
    const fn = tag >> 3, wt = tag & 0x7;
    switch (fn) {
      case 15: reader.readVarint(); break;
      case 1: if (wt === 2) name = new TextDecoder().decode(reader.readBytes()); break;
      case 2: if (wt === 2) rawFeatures.push(decodeFeature(reader.readSubMessage())); break;
      case 3: if (wt === 2) keys.push(new TextDecoder().decode(reader.readBytes())); break;
      case 4: if (wt === 2) values.push(decodeValue(reader.readSubMessage())); break;
      case 5: extent = reader.readVarint(); break;
      default: reader.skipField(wt);
    }
  }
  const features = rawFeatures.map(function(raw) {
    const properties = {};
    for (let i = 0; i + 1 < raw.tags.length; i += 2) {
      const ki = raw.tags[i], vi = raw.tags[i + 1];
      if (ki < keys.length && vi < values.length) properties[keys[ki]] = values[vi];
    }
    return {
      id: raw.id,
      geomType: raw.geomType,
      properties: properties,
      geometry: decodeGeometry(raw.geometry, raw.geomType),
    };
  });
  return { name: name, extent: extent, features: features };
}

function decodeTile(data) {
  const reader = new ProtobufReader(data);
  const layers = [];
  while (reader.hasMore) {
    const tag = reader.readVarint();
    const fn = tag >> 3, wt = tag & 0x7;
    if (fn === 3 && wt === 2) {
      layers.push(decodeLayer(reader.readSubMessage()));
    } else {
      reader.skipField(wt);
    }
  }
  return { layers: layers };
}

self.onmessage = function (event) {
  try {
    const bytes = new Uint8Array(event.data);
    const tile = decodeTile(bytes);
    self.postMessage(JSON.stringify(tile));
  } catch (e) {
    self.postMessage(JSON.stringify({ error: e.message || String(e) }));
  }
};
''';
