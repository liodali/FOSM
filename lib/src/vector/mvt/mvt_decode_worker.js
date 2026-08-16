// FOSM MVT (Mapbox Vector Tile) protobuf decoder for Web Workers.
//
// Runs in a dedicated Web Worker to decode MVT .pbf bytes off the main
// thread, keeping the UI responsive on web where Dart isolates aren't
// available.
//
// Protocol:
//   Main → Worker:  Uint8Array (raw MVT .pbf bytes)
//   Worker → Main:  JSON string with decoded tile data
//
// The JSON structure mirrors DecodedVectorTile:
//   {
//     layers: [{
//       name: string,
//       extent: number,
//       features: [{
//         id: number,
//         geomType: number,          // 0=unknown 1=point 2=line 3=polygon
//         properties: { key: value },
//         geometry: [[x0,y0,x1,y1,…], …]   // flat coordinate pairs
//       }]
//     }]
//   }

'use strict';

// ── Protobuf reader ───────────────────────────────────────────────────────

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
      if (this.pos >= this.end) throw new Error('truncated varint');
      const byte = this.data[this.pos++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) === 0) return result >>> 0;
      shift += 7;
      if (shift >= 64) throw new Error('varint too long');
    }
  }

  readBytes() {
    const length = this.readVarint();
    if (this.pos + length > this.end) throw new Error('truncated bytes');
    const view = this.data.subarray(this.pos, this.pos + length);
    this.pos += length;
    return view;
  }

  readSubMessage() {
    const length = this.readVarint();
    if (this.pos + length > this.end) throw new Error('truncated sub-message');
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
      default: throw new Error('unsupported wire type ' + wireType);
    }
  }
}

// ── Zigzag decode ─────────────────────────────────────────────────────────

function zigzag(v) { return (v >>> 1) ^ -(v & 1); }

// ── Geometry decoder ──────────────────────────────────────────────────────

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
      case 1: // MoveTo
        for (let c = 0; c < count && i + 1 < commands.length; c++) {
          x += zigzag(commands[i++]);
          y += zigzag(commands[i++]);
          finishPart();
          current.push(x, y);
        }
        break;
      case 2: // LineTo
        for (let c = 0; c < count && i + 1 < commands.length; c++) {
          x += zigzag(commands[i++]);
          y += zigzag(commands[i++]);
          current.push(x, y);
        }
        break;
      case 7: // ClosePath
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

// ── Feature decoder ───────────────────────────────────────────────────────

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
  return { id, geomType, tags, geometry };
}

// ── Value decoder ─────────────────────────────────────────────────────────

function decodeValue(reader) {
  let value = null;
  while (reader.hasMore) {
    const tag = reader.readVarint();
    const fn = tag >> 3, wt = tag & 0x7;
    switch (fn) {
      case 1: if (wt === 2) value = new TextDecoder().decode(reader.readBytes()); break;
      case 2: /* float32 – skip */ reader.pos += 4; break;
      case 3: /* float64 – skip */ reader.pos += 8; break;
      case 4: value = reader.readVarint(); break;
      case 5: value = reader.readVarint(); break;
      case 6: value = zigzag(reader.readVarint()); break;
      case 7: value = reader.readVarint() !== 0; break;
      default: reader.skipField(wt);
    }
  }
  return value;
}

// ── Layer decoder ─────────────────────────────────────────────────────────

function decodeLayer(reader) {
  let name = '', extent = 4096;
  const rawFeatures = [], keys = [], values = [];

  while (reader.hasMore) {
    const tag = reader.readVarint();
    const fn = tag >> 3, wt = tag & 0x7;
    switch (fn) {
      case 15: reader.readVarint(); break; // version
      case 1: if (wt === 2) name = new TextDecoder().decode(reader.readBytes()); break;
      case 2: if (wt === 2) rawFeatures.push(decodeFeature(reader.readSubMessage())); break;
      case 3: if (wt === 2) keys.push(new TextDecoder().decode(reader.readBytes())); break;
      case 4: if (wt === 2) values.push(decodeValue(reader.readSubMessage())); break;
      case 5: extent = reader.readVarint(); break;
      default: reader.skipField(wt);
    }
  }

  const features = rawFeatures.map(raw => {
    const properties = {};
    for (let i = 0; i + 1 < raw.tags.length; i += 2) {
      const ki = raw.tags[i], vi = raw.tags[i + 1];
      if (ki < keys.length && vi < values.length) {
        properties[keys[ki]] = values[vi];
      }
    }
    return {
      id: raw.id,
      geomType: raw.geomType,
      properties,
      geometry: decodeGeometry(raw.geometry, raw.geomType),
    };
  });

  return { name, extent, features };
}

// ── Tile decoder ──────────────────────────────────────────────────────────

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
  return { layers };
}

// ── Worker message handler ────────────────────────────────────────────────

self.onmessage = function (event) {
  try {
    const bytes = new Uint8Array(event.data);
    const tile = decodeTile(bytes);
    // Send back as JSON string — Dart decodes with jsonDecode.
    self.postMessage(JSON.stringify(tile));
  } catch (e) {
    self.postMessage(JSON.stringify({ error: e.message || String(e) }));
  }
};
