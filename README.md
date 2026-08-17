# FOSM - Flutter OpenStreetMap

A high-performance Flutter map library with native raster and vector tile rendering, featuring OpenFreeMap integration, persistent background isolates, and advanced performance optimizations.

![Flutter Version](https://img.shields.io/badge/flutter-%3E%3D3.47.0-blue.svg)
![Dart Version](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## ✨ Features

- 🗺️ **Dual Rendering Modes**: Native raster (OSM) and vector (Mapbox Vector Tiles) rendering
- 📍 **Markers**: Any Flutter widget (or plain text) anchored to lat/lon via `MarkerManager` — with tap/long-press gestures (hand cursor on hover) and marker-following overlays
- 🚀 **High Performance**: Persistent HTTP isolate with TCP connection reuse
- 🎯 **Smart Caching**: Memory + disk (Hive) with intelligent eviction
- 🌍 **OpenFreeMap Integration**: Free, no API key required vector tiles
- 📱 **Cross-Platform**: iOS, Android, Web, macOS, Linux, Windows
- 🏷️ **Labels & Icons**: Point labels, line labels (road names), and sprite icons
- 🔄 **Zoom Animations**: Google Maps-style scale transitions on double-tap, ± buttons and pinch steps
- 🧵 **Background Processing**: Compute-based protobuf parsing on separate threads
- 📊 **Pre-loading**: Intelligent adjacent zoom level pre-loading

## 📦 Installation

```yaml
dependencies:
  fosm:
    git:
      url: https://github.com/yourusername/fosm.git
```

## 🚀 Quick Start

### Initialize Map Cache

```dart
import 'package:fosm/fosm.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initMap(); // Initialize Hive cache
  runApp(const MyApp());
}
```

### Raster Map (OpenStreetMap)

```dart
MapView(
  latLng: LatLng(latitude: 47.4358, longitude: 8.4737),
  zoom: 10,
  minZoom: 1,
  maxZoom: 19,
  showZoomControls: true,
  animateZoom: true,
)
```

### Vector Map (OpenFreeMap Liberty)

```dart
MapView(
  latLng: LatLng(latitude: 47.4358, longitude: 8.4737),
  zoom: 10,
  minZoom: 1,
  maxZoom: 19,
  vectorStyle: openFreeMapLiberty, // Built-in preset
  showZoomControls: true,
  animateZoom: true,
  onZoomChanged: (zoom) {
    print('Zoom level: $zoom');
  },
)
```

### Custom Vector Style

```dart
const customStyle = VectorMapStyle(
  id: 'my-custom-style',
  styleUrl: 'https://tiles.openfreemap.org/styles/bright',
);

MapView(
  latLng: LatLng(latitude: 47.4358, longitude: 8.4737),
  zoom: 10,
  vectorStyle: customStyle,
)
```

### Markers

Own a `MarkerManager`, pass it to the map, and mutate it at runtime — the
map re-renders on every change:

```dart
final markers = MarkerManager();

MapView(
  latLng: const LatLng(latitude: 47.4358, longitude: 8.4737),
  zoom: 10,
  markers: markers,
);

// Any widget, anchored so its bottom-center tip sits on the coordinate:
markers.add(
  const Marker(
    point: LatLng(latitude: 47.4358, longitude: 8.4737),
    alignment: Alignment.bottomCenter,
    child: Icon(Icons.location_on, size: 40, color: Colors.red),
  ),
);

// Or plain text:
markers.add(Marker.text('Zurich', const LatLng(latitude: 47.3769, longitude: 8.5417)));

// Remove individually (by identity), filter, or clear:
markers.remove(firstMarker);
markers.removeWhere((m) => /* … */);
markers.clear();
```

Markers render above the tile grid (below vector labels) and track the
camera on every pan and zoom. Markers whose anchor leaves the viewport
are culled — they are not built, laid out, or painted until visible
again. `alignment` picks which point of the widget sits on the
coordinate (default: center; use `Alignment.bottomCenter` for pins).
Marker children are ordinary widgets, so buttons and gesture handlers
work inside them.

### Marker gestures & overlays

Markers accept `onTap` / `onLongPress` callbacks, and any marker with an
`overlayBuilder` gets a tap-to-toggle overlay ("info window") — any
Flutter widget, anchored to the marker and following it across pans and
zooms:

```dart
markers.add(
  Marker(
    point: const LatLng(latitude: 47.4358, longitude: 8.4737),
    alignment: Alignment.bottomCenter,
    onTap: () => print('tapped'),           // fires alongside the toggle
    onLongPress: () => print('long press'),
    overlayBuilder: (context) => const Card(
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Text('Hello from Zurich'),
      ),
    ),
    child: const Icon(Icons.location_on, size: 40, color: Colors.red),
  ),
);
```

Behavior is shaped per-marker with `MarkerOverlayConfig`:

| Option | Default | Behavior |
| --- | --- | --- |
| `removeOnMove` | `false` | `true` dismisses the overlay as soon as the camera changes (pan, zoom, or programmatic); `false` keeps it anchored while it follows the marker |
| `closeOnMapTap` | `true` | dismisses the overlay when the user taps the bare map or a marker without its own overlay; taps inside the overlay never dismiss it |
| `anchor` | `above` | side of the marker the overlay sits on: `above`, `below` or `center` |
| `offset` | `Offset(0, 8)` | extra gap between marker and overlay |
| `animationDuration` | `200 ms` | fade + scale entrance; `Duration.zero` shows instantly |

One overlay is visible at a time. The manager exposes programmatic
control and listeners (which also fire for automatic dismissals like
`removeOnMove` and map taps):

```dart
markers.showOverlay(myMarker);   // returns false if marker has no overlayBuilder
markers.hideOverlay();
markers.overlayMarker;           // whose overlay is open, or null

markers.onOverlayShown = (marker) { /* … */ };
markers.onOverlayHidden = (marker) { /* … */ };
```

Removing a marker (or clearing the manager) while its overlay is open
hides the overlay automatically.

## 🏗️ Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                         User Interface                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    MapView Widget                     │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────────┐ │  │
│  │  │   Gesture  │  │   Zoom     │  │    Label       │ │  │
│  │  │   Handler  │  │   Controls │  │    Overlay     │ │  │
│  │  └────────────┘  └────────────┘  └────────────────┘ │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      Tile Manager                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Grid Calc    │  │ Memory Cache │  │  Pre-loading     │  │
│  │ (viewport)   │  │ (LRU, 200)   │  │  Manager         │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Rendering Pipeline                        │
│  ┌────────────────┐         ┌────────────────────────┐     │
│  │  Raster Mode   │         │    Vector Mode          │     │
│  │                │         │                          │     │
│  │ Image Decode   │         │ MVT Parse → Style Eval   │     │
│  │ (PNG/JPEG)     │         │ → Canvas Render          │     │
│  └────────────────┘         └────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Isolate Architecture                      │
│  ┌──────────────────┐      ┌────────────────────────┐      │
│  │ HTTP Isolate     │      │  Compute Isolates      │      │
│  │ (Persistent)     │      │  (Per-Call)            │      │
│  │                  │      │                          │      │
│  │ • TCP Reuse      │      │ • MVT Parsing          │      │
│  │ • Connection     │      │ • CPU-intensive work   │      │
│  │   Pooling        │      │                          │      │
│  └──────────────────┘      └────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

## 🧵 Isolate Architecture

FOSM uses a sophisticated isolate strategy to keep the UI responsive while performing heavy operations.

### HTTP Isolate (Persistent)

A long-lived background isolate that handles ALL network I/O:

```
┌─────────────────────────────────────────────────────────────┐
│                       Main Thread                            │
│                                                              │
│  TileManager                                                 │
│  ├─ Visible tile request ─────────────┐                     │
│  └─ Preload request ─────────────────┐│                     │
│                                       ││                     │
└───────────────────────────────────────┼┼─────────────────────┘
                                        ││
                    ┌───────────────────┘│
                    │    SendPort(url)    │
                    ▼                     │
┌─────────────────────────────────────────────────────────────┐
│                  HTTP Isolate (Background)                   │
│                                                              │
│  Persistent HttpClient                                       │
│  ├─ Connection timeout: 10s                                  │
│  ├─ Idle timeout: 30s                                        │
│  └─ TCP Connection Pool ─────────────────────────────┐      │
│                                                       │      │
│  ┌──────────────────────────────────────────────────┐│      │
│  │ • Reuses TCP connections across hundreds of     ││      │
│  │   tile requests                                  ││      │
│  │ • Avoids TLS handshake overhead                  ││      │
│  │ • Reduces latency by ~50-100ms per request      ││      │
│  └──────────────────────────────────────────────────┘│      │
│                                                       │      │
│  Response: Uint8List ────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
                    │
                    │ SendPort(bytes)
                    ▼
┌─────────────────────────────────────────────────────────────┐
│                       Main Thread                            │
│                                                              │
│  Decode & Render                                             │
└─────────────────────────────────────────────────────────────┘
```

**Benefits:**
- ✅ TCP connection reuse (no repeated TLS handshakes)
- ✅ Reduced latency (~50-100ms saved per request)
- ✅ Network I/O completely off main thread
- ✅ Single isolate for all tile types (raster + vector)

### Compute Isolates (Per-Call)

Short-lived isolates for CPU-intensive work:

```
┌─────────────────────────────────────────────────────────────┐
│                       Main Thread                            │
│                                                              │
│  VectorTileRuntime                                           │
│  └─ decodeMvtAsync(bytes) ─────────────────────────────┐    │
│                                                          │    │
└──────────────────────────────────────────────────────────┼────┘
                                                            │
                                        compute() spawns    │
                                                            ▼
┌─────────────────────────────────────────────────────────────┐
│                  Compute Isolate (Temporary)                 │
│                                                              │
│  decodeVectorTile(bytes)                                     │
│  ├─ ProtobufReader (parse MVT)                               │
│  ├─ Extract layers, features, properties                     │
│  ├─ Decode geometry (coordinates)                            │
│  └─ Build DecodedVectorTile ────────────────────────┐       │
│                                                      │       │
│  Duration: ~2-5ms                                    │       │
└──────────────────────────────────────────────────────┼───────┘
                                                        │
                                        Return value    │
                                                        ▼
┌─────────────────────────────────────────────────────────────┐
│                       Main Thread                            │
│                                                              │
│  DecodedVectorTile                                           │
│  └─ Render on Canvas (fills, lines, labels, icons)           │
│      Duration: ~15-25ms                                      │
└─────────────────────────────────────────────────────────────┘
```

**Why not persistent parse isolate?**
- Compute isolates use `Isolate.exit()` which returns values efficiently
- Spawn overhead (~1-3ms) is negligible vs parsing time (2-5ms)
- Persistent isolates have complex serialization issues with Dart objects
- Tests work reliably with compute()

### Web Platform

On web, isolates work differently:

```dart
// HTTP Isolate: Disabled (browsers handle connection pooling)
if (kIsWeb) {
  // Use Dio on main thread
  bytes = await downloadTileBytes(url);
} else {
  // Use persistent isolate on native
  bytes = await _httpIsolate.fetchUrl(url);
}

// MVT Parsing: compute() runs on main thread (no isolates on web)
// But we yield between operations to keep UI responsive
```

## 🎨 Vector Tile Rendering

### Rendering Pipeline

```
MVT Bytes (.pbf)
    │
    ▼
┌─────────────────┐
│ Protobuf Parse  │  compute() isolate (native)
│                 │  or main thread (web)
└─────────────────┘
    │
    ▼
DecodedVectorTile
    │
    ├─ Layers (water, roads, buildings, etc.)
    ├─ Features with properties
    └─ Geometry (coordinates)
    │
    ▼
┌─────────────────┐
│ Style Eval      │  Apply Mapbox Style Spec
│                 │  - Expressions (interpolate, match, etc.)
│                 │  - Filters
│                 │  - Paint properties
└─────────────────┘
    │
    ▼
┌─────────────────┐
│ Canvas Render   │  Chunked rendering (8 layers/batch)
│                 │  - Fills (polygons)
│                 │  - Lines (roads, rivers)
│                 │  - Circles (POIs)
│                 │  - Yield every batch (web)
└─────────────────┘
    │
    ▼
ui.Picture
    │
    ▼
┌─────────────────┐
│ toImage(256x256)│  GPU → CPU readback
└─────────────────┘
    │
    ▼
ui.Image (cached)
```

### Chunked Rendering

To prevent UI freezes on web, rendering is split into batches:

```dart
Future<ui.Picture> renderAsync({
  required DecodedVectorTile decoded,
  required int z, int x, int y,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  
  var layerCount = 0;
  for (final layer in visibleLayers) {
    _paintLayer(canvas, layer, decoded);
    
    layerCount++;
    // Yield every 8 layers on web
    if (kIsWeb && layerCount % 8 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  
  return recorder.endRecording();
}
```

**Performance Impact:**
```
BEFORE:  [███████████████████████████████████████] 25ms freeze

AFTER:   [███][yield][███][yield][███][yield][███] ~3ms chunks
```

### Labels & Icons

Labels are rendered as an overlay (not baked into tiles):

```
┌─────────────────────────────────────────────────────────────┐
│                     Viewport Canvas                          │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │  Tile Image │  │  Tile Image │  │  Tile Image │        │
│  │  (256x256)  │  │  (256x256)  │  │  (256x256)  │        │
│  └─────────────┘  └─────────────┘  └─────────────┘        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Label Overlay                            │  │
│  │                                                        │  │
│  │  • Point Labels (cities, POIs)                        │  │
│  │  • Line Labels (road names, rivers)                   │  │
│  │  • Icons (airports, stations, etc.)                   │  │
│  │                                                        │  │
│  │  Collision Detection:                                  │  │
│  │  ┌────────┐                                            │  │
│  │  │ Label  │◄── Checks overlap with placed labels      │  │
│  │  └────────┘                                            │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Line Labels:**
- Sampled every 250px along paths
- Rotated to follow road/river direction
- Flipped if upside-down (keeps text readable)

**Collision Detection:**
- Uniform grid (72px cells)
- First-come-first-served placement
- Prevents label overlap

## 🔄 Caching Strategy

### Memory Cache (LRU)

```dart
final LinkedHashMap<String, ui.Image> _memoryCache = LinkedHashMap();
static const int maxMemoryCachedTiles = 200;

void _trimMemoryCache() {
  while (_memoryCache.length > maxMemoryCachedTiles) {
    final oldestKey = _memoryCache.keys.first;
    final image = _memoryCache.remove(oldestKey);
    if (!isVisible(oldestKey)) {
      image.dispose(); // Free GPU memory
    }
  }
}
```

**Benefits:**
- O(1) access time
- Automatic eviction of least-recently-used tiles
- GPU memory management (dispose off-screen tiles)

### Byte Cache (Pre-loaded Tiles)

```dart
final Map<String, Uint8List> _byteCache = {};
static const int maxByteCacheBytes = 50 * 1024 * 1024; // 50MB

void _storeInByteCache(String key, Uint8List bytes) {
  _byteCache[key] = bytes;
  _trimByteCache();
}
```

**Purpose:**
- Store pre-loaded adjacent zoom tiles (±1 levels)
- Instant decode when zooming (no network wait)
- Compressed bytes (PNG/MVT) use less memory than decoded images

### Disk Cache (Hive)

```dart
await storeTile(key, tile, bytes);           // Write
final bytes = await storedTileBytes(key);    // Read
```

**Features:**
- Persistent across app restarts
- Separate namespace per vector style
- Automatic corruption detection (delete + re-download)

## 📊 Performance Optimizations

### 1. Center-First Tile Loading

```dart
// Sort tiles by distance from viewport center
final tiles = visibleTiles
  ..sort((a, b) => a.distanceToCenter.compareTo(b.distanceToCenter));

for (final tile in tiles) {
  _scheduleLoad(tile);
}
```

**Result:** Center tiles render first, edges fill in progressively.

### 2. Raster Layer Skip

```dart
// Only fetch raster tiles if visible at current zoom
final hasVisibleRaster = layers.any((l) =>
    l.type == LayerType.raster &&
    l.isVisible &&
    zoom >= l.minZoom &&
    zoom <= l.maxZoom);

if (hasVisibleRaster) {
  // Fetch raster tiles
}
```

**Impact:** OpenFreeMap Liberty's relief layer only visible at zoom < 5. Skipped at zoom 5+, saving network requests.

### 3. Dash Line Optimization

```dart
// Skip dash computation for hairline widths
if (hasDash && width >= 0.5) {
  _drawDashed(canvas, path, paint);
} else {
  canvas.drawPath(path, paint);
}
```

**Why:** Dash patterns imperceptible below 0.5px width.

### 4. Concurrent Decode Limiting

```dart
static const int maxConcurrentDecodes = 3;

Future<ui.Image> decoder(bytes, z, x, y) async {
  await _waitForDecodeSlot();
  try {
    return await _decodeAndRender(bytes, z, x, y);
  } finally {
    _releaseDecodeSlot();
  }
}
```

**Purpose:** Prevent overwhelming the GPU with simultaneous `toImage()` calls.

### 5. Pre-loading Strategy

```dart
// Pre-load ±1 zoom levels after 500ms idle
if (idleTime > 500ms) {
  _preloadAdjacentZoom();
}

// Max 20 concurrent preloads
static const int maxConcurrentPreloads = 20;
```

**Result:** Smooth zoom transitions with instant tile availability.

## 📁 Project Structure

```
lib/
├── fosm.dart                          # Public API exports
└── src/
    ├── api/
    │   ├── tile.dart                  # Tile data class
    │   ├── tile_manager.dart          # Grid calculation & loading
    │   ├── tile_source.dart           # TileFetcher typedef
    │   ├── geo_point.dart             # LatLng class
    │   ├── marker.dart                # Marker model
    │   └── marker_manager.dart        # Marker collection (ChangeNotifier)
    │
    ├── view/
    │   ├── map_view.dart              # Main map widget
    │   ├── render.dart                # CustomPainters (tiles, labels)
    │   ├── marker_layer.dart          # Widget markers + viewport culling
    │   └── zoom_controls.dart         # +/- buttons
    │
    ├── vector/
    │   ├── mvt/
    │   │   ├── protobuf_reader.dart   # Protobuf decoder
    │   │   └── vector_tile.dart       # MVT parser
    │   │
    │   ├── render/
    │   │   ├── vector_tile_runtime.dart   # Tile lifecycle
    │   │   ├── vector_tile_renderer.dart  # Canvas rendering
    │   │   ├── label_overlay.dart         # Labels & icons
    │   │   └── sprite_atlas.dart          # Icon sprites
    │   │
    │   └── style/
    │       ├── style_loader.dart      # Load Mapbox style JSON
    │       ├── expression.dart        # Style expressions
    │       └── css_color.dart         # Color parsing
    │
    ├── isolate/
    │   ├── http_isolate.dart          # HTTP isolate (stub)
    │   ├── http_isolate_native.dart   # HTTP isolate (native)
    │   └── mvt_worker.dart            # MVT parsing (compute)
    │
    └── common/
        ├── utils.dart                 # Helpers
        ├── osm_transformation_utilities.dart  # Math
        └── cache_tile_mixin.dart      # Hive cache

test/
├── vector/
│   ├── vector_tile_test.dart
│   ├── style_parser_test.dart
│   └── expression_test.dart
├── marker_manager_test.dart
├── marker_layer_test.dart
└── tile_manager_test.dart
```

## 🎯 Supported Mapbox Style Features

### Layer Types

- ✅ `background` - Solid color background
- ✅ `fill` - Polygon fills
- ✅ `line` - Lines (roads, rivers, borders)
- ✅ `circle` - Circles (POIs)
- ✅ `symbol` - Text labels and icons
- ✅ `raster` - Raster imagery
- ⏳ `fill-extrusion` - 3D buildings (planned)
- ❌ `heatmap` - Not supported
- ❌ `hillshade` - Not supported

### Expressions

- ✅ Arithmetic: `+`, `-`, `*`, `/`
- ✅ Comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`
- ✅ Logical: `all`, `any`, `none`
- ✅ Interpolation: `interpolate` (linear, exponential)
- ✅ Matching: `match`, `step`, `case`, `coalesce`
- ✅ Property access: `get`, `has`
- ✅ Type conversion: `to-number`, `to-string`, `to-color`
- ✅ String: `concat`

### Paint Properties

**Fill:**
- `fill-color`, `fill-opacity`, `fill-outline-color`

**Line:**
- `line-color`, `line-opacity`, `line-width`
- `line-dasharray`, `line-cap`, `line-join`

**Circle:**
- `circle-color`, `circle-opacity`, `circle-radius`
- `circle-stroke-color`, `circle-stroke-width`

**Symbol:**
- `text-color`, `text-halo-color`, `text-halo-width`
- `text-size`, `text-font`, `text-letter-spacing`
- `icon-image`, `icon-size`

## 🌐 OpenFreeMap

FOSM includes built-in support for [OpenFreeMap](https://openfreemap.org):

```dart
// Built-in preset
MapView(
  vectorStyle: openFreeMapLiberty,
  // ...
)
```

**Features:**
- ✅ Free, no API key required
- ✅ Vector tiles (Mapbox Vector Tiles format)
- ✅ Multiple styles: Liberty, Bright, Dark, Positron
- ✅ Global coverage
- ✅ High-performance CDN

**Attribution Required:**
```dart
// Automatically displayed when using vectorStyle
```

## 🔧 Advanced Usage

### Custom Tile Source

```dart
MapView(
  latLng: LatLng(latitude: 0, longitude: 0),
  zoom: 2,
  tileFetcher: (z, x, y) async {
    final url = 'https://my-tile-server.com/$z/$x/$y.png';
    return await downloadTileBytes(url);
  },
)
```

### Custom Vector Style

```dart
const myStyle = VectorMapStyle(
  id: 'my-style',
  styleUrl: 'https://example.com/style.json',
);

MapView(
  vectorStyle: myStyle,
  // ...
)
```

### Disable Animations

```dart
MapView(
  animateZoom: false,
  zoomAnimationDuration: Duration(milliseconds: 200),
  // ...
)
```

### Zoom Callback

```dart
MapView(
  onZoomChanged: (zoom) {
    print('Current zoom: $zoom');
    setState(() => _currentZoom = zoom);
  },
)
```

## 🧪 Testing

```bash
# Run all tests
flutter test

# Run with coverage
flutter test --coverage

# Run specific test file
flutter test test/vector/vector_tile_test.dart
```

**Test Coverage:** 86 tests passing
- Vector tile parsing
- Style expression evaluation
- Tile manager logic
- Grid calculations
- Cache behavior

## 📈 Performance Benchmarks

### Tile Loading (Native - macOS)

| Operation | Time |
|-----------|------|
| HTTP fetch (cached connection) | ~50ms |
| MVT protobuf parse | ~2-5ms |
| Style evaluation + render | ~15-25ms |
| `toImage(256x256)` | ~5-15ms |
| **Total per tile** | **~70-95ms** |

### Tile Loading (Web - Chrome)

| Operation | Time |
|-----------|------|
| HTTP fetch (browser) | ~100ms |
| MVT protobuf parse | ~2-5ms |
| Style evaluation + render | ~15-25ms |
| `toImage(256x256)` | ~5-15ms |
| **Total per tile** | **~120-145ms** |

### Impact of Optimizations

| Optimization | Latency Saved |
|--------------|---------------|
| Persistent HTTP isolate (TCP reuse) | 50-100ms |
| Chunked rendering (web) | Prevents 25ms freezes |
| Center-first loading | Perceived +500ms |
| Pre-loading ±1 zoom | Instant zoom transitions |

## 🤝 Contributing

Contributions welcome! Areas of focus:

- [ ] 3D building extrusion (flutter_gpu)
- [ ] Line label collision detection
- [ ] Terrain/3D globe projection
- [ ] Offline map packages
- [ ] Custom layer rendering
- [ ] Performance profiling tools

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- [OpenFreeMap](https://openfreemap.org) - Free vector tiles
- [OpenStreetMap](https://www.openstreetmap.org) - Map data
- [Mapbox](https://www.mapbox.com) - Vector tile specification
- [Hive](https://hivedb.dev) - Fast key-value database

## 📚 Related Projects

- [flutter_map](https://pub.dev/packages/flutter_map) - Alternative Flutter map library
- [maplibre_gl](https://pub.dev/packages/maplibre_gl) - MapLibre GL bindings

---

**Made with ❤️ by the FOSM Team**

*High-performance maps for Flutter, without the complexity.*
