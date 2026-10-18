# FOSM - Flutter OpenStreetMap

A high-performance Flutter map library with native raster and vector tile rendering, featuring OpenFreeMap integration, persistent background isolates, and advanced performance optimizations.

![Flutter Version](https://img.shields.io/badge/flutter-%3E%3D3.47.0-blue.svg)
![Dart Version](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## ✨ Features

- 🗺️ **Dual Rendering Modes**: Native raster (OSM) and vector (Mapbox Vector Tiles) rendering
- 📍 **Markers**: Any Flutter widget (or plain text) anchored to lat/lon via `MarkerManager` — with tap/long-press gestures (hand cursor on hover) and marker-following overlays
- 🛣️ **Polylines**: Render decoded route geometry (`List<LatLng>`) in any color/width, above tiles and below markers — works in raster and vector mode
- **Map interactions**: Geographic taps/long presses, polygon areas with holes, and route/area selection with gesture priority
- 🚀 **High Performance**: Persistent HTTP isolate with TCP connection reuse
- 🎯 **Smart Caching**: Memory + disk (Hive) with intelligent eviction
- 🌍 **OpenFreeMap Integration**: Free, no API key required vector tiles
- 📱 **Cross-Platform**: iOS, Android, Web, macOS, Linux, Windows
- 🏷️ **Labels & Icons**: Point labels, line labels (road names), and sprite icons
- 🔄 **Zoom Animations**: Google Maps-style two-phase transitions — blurred hold while tiles load, then scale reveal. Two intensity levels (`scale` / `crossfade`)
- **Camera Bounds**: Keep the camera inside a fixed `LatLngBounds` during gestures and programmatic movement
- **Fit Bounds**: Frame routes and other geographic boxes with optional padding through `MapController.fitBounds`
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

### Camera bounds and fit bounds

Use `cameraBounds` when the camera must remain inside a fixed geographic box.
The constraint applies to gestures, zoom focal-point changes, and programmatic
camera movement:

```dart
final controller = MapController();

final allowedArea = LatLngBounds(
  southwest: LatLng(latitude: 47.20, longitude: 8.20),
  northeast: LatLng(latitude: 47.70, longitude: 8.80),
);

MapView(
  controller: controller,
  latLng: allowedArea.center,
  zoom: 10,
  cameraBounds: allowedArea,
);
```

Use `fitBounds` to navigate to a box without creating a persistent constraint.
This is useful for framing routes after the map controller is attached:

```dart
final routeBounds = LatLngBounds.fromPoints(routePoints);
controller.fitBounds(
  routeBounds,
  padding: const EdgeInsets.all(48),
  animate: true,
);
```

`LatLngBounds` accepts finite coordinates in the Web Mercator latitude range
and longitudes from `-180` to `180`. Bounds crossing the antimeridian are not
supported. Remove a persistent constraint by rebuilding `MapView` with
`cameraBounds: null`.

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

### Cluster markers

For large marker sets, replace some or all `Marker`s with `ClusterMarker`s and
tell the map how to group them:

```dart
final markers = MarkerManager();

markers.addAll([
  ClusterMarker(
    point: LatLng(latitude: 47.3769, longitude: 8.5417),
    child: const Icon(Icons.circle, size: 16, color: Colors.green),
  ),
  ClusterMarker(
    point: LatLng(latitude: 47.3775, longitude: 8.5420),
    child: const Icon(Icons.circle, size: 16, color: Colors.green),
  ),
]);

MapView(
  latLng: const LatLng(latitude: 47.3769, longitude: 8.5417),
  zoom: 10,
  markers: markers,
  markerClusterOptions: const MarkerClusterOptions(
    radius: 64,      // group members within this many screen pixels
    maxZoom: 14,     // disable clustering above this zoom level
    minSize: 2,      // smallest group that forms a cluster
    zoomOnTap: true, // zoom in one level when a cluster is tapped
  ),
)
```

Use `clusterGroup` to cluster markers independently per category (e.g. stores
vs restaurants). Provide a `builder` to customize the cluster badge, or leave it
out to use the default circular count badge:

```dart
MarkerClusterOptions(
  radius: 64,
  builder: (context, cluster) => Container(
    width: 40,
    height: 40,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: Colors.deepPurple,
      shape: BoxShape.circle,
    ),
    child: Text('${cluster.count}', style: const TextStyle(color: Colors.white)),
  ),
  onTap: (cluster) => print('Tapped cluster of ${cluster.count}'),
)
```

Plain `Marker`s and `ClusterMarker`s can coexist in the same manager. Only
`ClusterMarker`s are grouped; plain markers are always rendered individually
and render above generated clusters. Tapping a cluster dispatches
`MapMarkerClusterTapNotification` and fires `MarkerClusterOptions.onTap`, so
`MapEventListenerMixin.onMapMarkerClusterTapped` works too.

### Polylines (routes)

FOSM renders decoded route geometry only — calling a routing provider
(OSRM, OpenRouteService, …) and decoding its encoded-polyline response is
your application's responsibility. Pass the decoded `LatLng` points as
`MapPolyline`s:

```dart
final routePoints = <LatLng>[
  const LatLng(latitude: 47.3769, longitude: 8.5417),
  const LatLng(latitude: 47.3788, longitude: 8.5470),
  const LatLng(latitude: 47.3811, longitude: 8.5524),
];

MapView(
  latLng: routePoints.first,
  zoom: 14,
  polylines: [
    MapPolyline(
      points: routePoints,
      color: Colors.blue,
      strokeWidth: 5, // logical pixels; does not scale with zoom
    ),
  ],
);
```

Replacing or clearing a route is ordinary widget configuration — rebuild
the parent with a new list (empty lists and one-point lists paint nothing):

```dart
polylines: routePoints.isEmpty
    ? const []
    : [MapPolyline(points: routePoints)],
```

Multiple independently styled routes are supported; list order is paint
order (later polylines draw above earlier ones):

```dart
polylines: [
  MapPolyline(points: fastestRoute, color: Colors.blue),
  MapPolyline(points: alternativeRoute, color: Colors.grey),
],
```

Routes support solid, dashed, and dotted patterns, optional outer
borders/casing, and configurable caps, joins, and miter limits:

```dart
// Solid route with a white border.
MapPolyline(
  points: routePoints,
  color: const Color(0xFF3F51B5),
  strokeWidth: 6,
  borderColor: Colors.white,
  borderWidth: 2,
)

// Dashed alternative route.
MapPolyline(
  points: alternativeRoute,
  color: Colors.orange,
  strokeWidth: 5,
  pattern: const MapPolylinePattern.dashed(
    dashLength: 14,
    gapLength: 8,
  ),
  strokeCap: StrokeCap.round,
  strokeJoin: StrokeJoin.round,
)

// Dotted walking route.
MapPolyline(
  points: walkingRoute,
  color: Colors.deepPurple,
  strokeWidth: 6, // dot diameter
  borderColor: Colors.white,
  borderWidth: 1,
  pattern: const MapPolylinePattern.dotted(spacing: 12),
)
```

Pattern dimensions, stroke widths, and border widths are in logical pixels
and do not scale with map zoom. Dash-and-gap cycles and dot spacing must be
at least one logical pixel. Routes render above the tile grid (and the
zoom-transition overlay) and below markers and vector labels, and stay
geographically aligned through pan, pinch zoom, zoom controls, and
`MapController` movements. Route painting never consumes gestures.

**Known limitation:** a segment crossing the international date line
(longitude `179` → `-179`) is drawn as a long straight line across the map
rather than wrapping around the world.

### Map taps and long presses

Map callbacks receive a `LatLng` in the current camera projection:

```dart
MapView(
  latLng: const LatLng(latitude: 47.4358, longitude: 8.4737),
  zoom: 10,
  onTap: (point) => print('Tapped ${point.latitude}, ${point.longitude}'),
  onLongPress: (point) => markers.add(Marker(
    point: point,
    alignment: Alignment.bottomCenter,
    child: const Icon(Icons.location_on),
  )),
  markers: markers,
)
```

`MapTapNotification` and `MapLongPressNotification` also report `point` and
`localPosition` (logical pixels relative to the map). The listener mixin exposes
`onMapTapped` and `onMapLongPressed`. Longitude wraps to `[-180, 180)` and
latitude clamps to the Web Mercator range at world edges. Dragging, pinching,
and double-tapping continue to control the camera.

### Polygons and area selection

```dart
MapView(
  latLng: areaPoints.first,
  zoom: 12,
  polygons: [
    MapPolygon(
      points: areaPoints,
      holes: [courtyardPoints],
      color: const Color(0x403F51B5),
      borderColor: Colors.indigo,
      borderWidth: 2,
      onTap: (hit) => print('Selected area at ${hit.point.latitude}'),
      onLongPress: (hit) => print('Area long press'),
    ),
  ],
)
```

Rings close automatically; winding direction does not matter. Holes should be
disjoint and contained within the outer ring. Their interiors remain empty and
pass presses through to underlying features or the map; painted hole borders
can still be selected. Empty rings and rings with fewer than three vertices are
valid transient states and paint nothing. Replace the geometry lists and rebuild
to update or remove areas. Coordinates must be finite, within the Web Mercator
latitude range and `[-180, 180]` longitude. Date-line wrapping is not supported.

Polygons paint above tiles/zoom snapshots and below routes, markers, and vector
labels. List order is paint order. Borders and `hitTolerance` use logical pixels.

### Route selection and gesture priority

```dart
MapPolyline(
  points: routePoints,
  strokeWidth: 6,
  hitTolerance: 10,
  onTap: (hit) {
    print('Selected segment ${hit.segmentIndex}');
    print('Nearest route coordinate: ${hit.nearestPoint.latitude}, '
        '${hit.nearestPoint.longitude}');
    print('Distance from route: ${hit.distancePixels} pixels');
  },
)
```

`MapPolylineHit` reports the selected polyline, actual press coordinate (`point`),
nearest projected route coordinate, segment index, and pixel distance. Hit testing
uses the stroke width, optional border, and extra `hitTolerance` (default: 10).
Dashed and dotted routes are selected as continuous lines, including their gaps.

Shapes are decorative by default. A shape callback enables its gesture;
`interactive: true` enables selection through notifications without callbacks.
Global `MapView.onPolylineTap`, `onPolylineLongPress`, `onPolygonTap`, and
`onPolygonLongPress` enable selection for all shapes of that type for that
gesture. The matching notifications carry the hit result; the listener mixin
exposes `onMapPolylineTapped`, `onMapPolylineLongPressed`, `onMapPolygonTapped`,
and `onMapPolygonLongPressed`.

Interactive markers and their overlays retain priority. Routes are considered
above polygons, and overlapping eligible shapes are selected in reverse paint
order. Only the selected feature receives the gesture; bare-map callbacks run
when no feature is hit. Feature taps follow the existing `closeOnMapTap` marker
overlay setting. Loaded tiles and camera gestures are unaffected by selection.

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

Rendered tiles use a 50 MiB budget based on estimated RGBA pixel memory
(`width × height × 4`), rather than a fixed tile count. Recently viewed tiles
remain available for up to 20 seconds after leaving the grid, so returning to
an area or zoom level can reuse the same image without decoding it again.
Unused images are evicted in least-recently-used order when the budget is full,
and a timer releases expired images even when the camera stays still.

Configure the budget and retention on the map; rebuilding with new values
updates the existing cache:

```dart
MapView(
  latLng: const LatLng(latitude: 47.4358, longitude: 8.4737),
  zoom: 10,
  maxRenderedCacheBytes: 32 * 1024 * 1024,
  renderedCacheRetention: const Duration(seconds: 20),
)
```

Images used by the current grid (including its padding) or an active zoom
snapshot are protected from eviction. These images can exceed the budget when
the viewport or snapshot requires more memory; unused images are released
first. Snapshot protection ends when the animation completes, is interrupted,
or the map is disposed or changes style. Set either option to zero to disable
retention of unused images. The estimate excludes engine/GPU overhead and
does not include compressed bytes, parsed vector data, or labels.

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

All maps share a persistent cache with a default **256 MiB compressed-payload
budget** and **seven-day lifetime**. Expiry is measured from storage; reading a
tile updates its LRU priority without extending its lifetime. Expired records
are ignored immediately and removed during initialization, writes, or explicit
maintenance. Excess records are evicted in least-recently-used order.

```dart
await initMap(
  diskCacheOptions: const MapDiskCacheOptions(
    maxBytes: 256 * 1024 * 1024,
    maxAge: Duration(days: 7),
  ),
);

final stats = await MapDiskCache.stats();
print('${stats.entryCount} tiles, ${stats.sizeBytes} bytes');
print('${stats.hits} hits, ${stats.misses} misses');

// Update the policy and prune immediately.
await MapDiskCache.configure(const MapDiskCacheOptions(
  maxBytes: 128 * 1024 * 1024,
  maxAge: Duration(days: 7),
));

await MapDiskCache.prune(); // Also compacts Hive storage where supported.
await MapDiskCache.clear(); // All FOSM tile namespaces; resets counters.
```

The budget counts compressed tile payloads, excluding Hive metadata and storage
overhead. It is shared across raster and vector namespaces. Tiles larger than
the budget are rendered without being stored. Set `maxBytes: 0` to disable
persistent storage or `maxAge: null` to disable expiry. Select a lifetime that
meets your tile provider's caching requirements; the standard OSM service
requires at least seven days when HTTP caching headers are unavailable.
[OSM tile policy](https://operations.osmfoundation.org/policies/tiles/)

Legacy raw-byte and base64 records remain readable. Records without timestamps
receive an age baseline when indexed, while retaining their payloads, keys, and
coordinates. The added metadata is compatible with older readers. LRU access
metadata is flushed on writes and maintenance (`stats`, `prune`, `configure`).

Clearing affects only the persistent tile box. In-memory tiles and currently
displayed maps remain usable, and subsequent map activity may populate the disk
cache again. Before `initMap`, statistics report `isInitialized: false`, clearing
and pruning are safe no-ops, and configuration is saved for initialization.

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

### 4. Frame-paced Tile Work

Each `MapView` shares one cooperative 2 ms UI-work allowance between vector
path recording and label preparation. Once spent, work waits until Flutter
finishes a frame, then rechecks whether the tile is still needed. Independent
jobs no longer each consume their full rendering allowance before yielding.

Raster image decoding and vector `Picture.toImage()` submissions use the same
map-owned image lane: at most two active operations and two starts between frame
waits. Queued work is re-ranked by the latest camera demand before it starts;
stale tiles are discarded before entering a codec or image snapshot.

HTTP fetches remain separate from presentation so new visible requests can
start while older images finish. Background padding/adjacent-zoom preloads wait
for foreground downloads **and** foreground presentation work to drain. Base
tiles publish progressively; label preparation stays separate.

These are cooperative limits: one Canvas, text-layout, or codec operation can
exceed the allowance. They constrain bursts without guaranteeing a frame rate;
use profile-mode device measurements to assess smoothness and coverage latency.

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
    │   ├── map_polyline.dart          # MapPolyline model (route styling)
    │   ├── marker_manager.dart        # Marker collection (ChangeNotifier)
    │
    ├── view/
    │   ├── map_view.dart              # Main map widget
    │   ├── render.dart                # CustomPainters (tiles, labels)
    │   ├── polyline_layer.dart        # Route/polyline rendering layer
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

### Loading and request failures

`requestTimeout` sets a positive total deadline for each HTTP request, including
response headers and the complete body (default: 30 seconds). It applies to
tiles, style documents, TileJSON, raster sources, and sprite downloads. Native
HTTP and Dio requests are cancelled on timeout/disposal. Custom tile fetchers
are bounded at the map boundary; their late results are ignored, but the library
cannot cancel work inside an application-supplied callback. Updating the timeout
affects subsequent requests.

```dart
MapView(
  latLng: const LatLng(latitude: 47.4358, longitude: 8.4737),
  zoom: 10,
  requestTimeout: const Duration(seconds: 15),
  loadingBuilder: (context, state) => Align(
    alignment: Alignment.topCenter,
    child: Text('${state.loadedTiles}/${state.totalTiles} tiles loaded'),
  ),
  errorBuilder: (context, state, retry) => Align(
    alignment: Alignment.topLeft,
    child: TextButton(onPressed: retry, child: const Text('Retry map loading')),
  ),
  onTileError: (failure) {
    print('${failure.zoom}/${failure.x}/${failure.y}: ${failure.error.kind}');
  },
)
```

`MapLoadState` reports the current stage (`style` or `tiles`), loaded/loading
viewport counts, and typed failures. Padding/preload failures and tiles that
have left the viewport do not appear in the error overlay. Successfully loaded
tiles stay visible during partial failures. Loading overlays ignore pointers so
map gestures and markers continue to work. Style placeholders use the same
builders before a tile grid is available.

`TileLoadException` exposes `kind`, `statusCode`, and `isRetryable`. Built-in
messages omit request URLs and credentials. Network, timeout, decode,
HTTP 408/429, and HTTP 5xx failures retry after the existing five-second backoff.
Other HTTP failures wait for explicit retry. The default error UI includes a
Retry button; retry preserves loaded tiles and prioritizes missing viewport
tiles. Optional missing sprites continue to be omitted without blocking tiles.

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

### Distance scale bar

Enable a distance ruler that updates with zoom and the camera center's latitude:

```dart
MapView(
  latLng: center,
  zoom: 7,
  showScaleBar: true,
  scaleBarUnit: ScaleBarUnit.metric, // or ScaleBarUnit.imperial
  scaleBarAlignment: Alignment.bottomLeft,
  scaleBarMaxWidth: 120, // maximum ruler length in logical pixels
)
```

The scale bar is hidden by default. It selects readable 1/2/5 distances in
meters/kilometers or feet/miles, using approximate ground resolution at the
camera center. Its line length is independent of display density and tile image
resolution. It updates with pans, zooms, controller moves, and bounds changes.
It stays fixed on screen. It follows the live camera in fractional mode and the
target camera during legacy integer zoom transitions.

The ruler ignores pointers, provides an accessibility label, and adapts to narrow
viewports. It hides when the viewport is too small to display it. Its default
bottom gap leaves space for provider attribution; choose a different alignment
if your app places other controls in that corner. For custom padding, use the
exported `MapScaleBar` widget in a bounded overlay and supply its `latitude`,
`zoom`, `unit`, `maxWidth`, `alignment`, and `padding`.

### Camera gestures

Single-pointer drags coast after release and slow with friction. Momentum obeys
`cameraBounds` and world limits; a new touch, wheel input, or camera command
stops it immediately. Pinches and cancelled gestures never start a fling.
Camera callbacks continue during motion, with a camera notification when it
settles. Parents can echo the current camera into `latLng`/`zoom` without
interrupting motion.

Vertical mouse-wheel input zooms around the cursor. Small deltas accumulate
within a burst (100 scroll pixels per level); direction changes and a 200 ms
pause reset the remainder. Wheel input uses Flutter's pointer-signal resolver,
so nested scrollable content can consume it first. At a zoom limit, outward
scrolling can pass to the parent. With fractional zoom disabled (the default),
small deltas accumulate into integer steps. Integer pinches use the original
gesture scale (2× means one level), with a small reversal tolerance to prevent
boundary flicker. Multi-level transitions scale through the complete zoom delta.

Both options default to true and can be changed at runtime:

```dart
MapView(
  latLng: center,
  zoom: 7,
  enableFling: true,
  enableScrollZoom: true,
)
```

### Fractional zoom

Enable a camera that can stop between integer tile levels:

```dart
MapView(
  latLng: center,
  zoom: 7,
  enableFractionalZoom: true,
  // Optional controlled value; also enables fractional gestures when supplied.
  fractionalZoom: 7.35,
  onFractionalZoomChanged: (zoom) => print('Display zoom: $zoom'),
  controller: mapController,
)

mapController.setFractionalZoom(8.5); // animates the displayed camera
print(mapController.fractionalZoom);
```

Pinches follow the complete gesture scale continuously (2× is one level),
including focal-point movement. Every 100 vertical wheel pixels changes zoom by
one level, including small deltas. Buttons, double taps, controller commands and
`fitBounds` animate through intermediate camera values. `animateZoom: false`
makes discrete commands instant while pinches still follow the fingers.
New touches and camera commands cancel an active animation.

The backing tile zoom is the nearest integer. HTTP/cache/decode keys remain
integer, while tile extents, projections, hit testing, camera bounds and the
scale bar use the precise display zoom. Marker widgets, route stroke widths,
label text and controls keep their screen size. A pinned old grid fills missing
cells across tile-level changes until replacement tiles arrive, with a bounded
settle timeout. Vector styles and cluster membership still evaluate at the
backing integer zoom; their anchors follow the continuous camera.

For compatibility, `MapController.zoom`, `onZoomChanged`, `onCameraChanged`
and `MapCameraChangeNotification.zoom` retain integer tile zoom values. Use
`MapController.fractionalZoom`, `onFractionalZoomChanged`, or
`MapCameraChangeNotification.fractionalZoom` for exact values. The listener mixin
also exposes `onMapFractionalZoomChanged`. Parents can echo precise values into
`fractionalZoom` without restarting animations. Calling `setFractionalZoom`
explicitly enables continuous camera behavior for that map instance. Removing
the controlled value and disabling the flag restores integer display zoom.
Fractional display zoom supports levels 0–30 within configured min/max limits.

### Disable Animations

```dart
MapView(
  animateZoom: false,
  enableFling: false,
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

## Location following

Supply fixes from your app's location provider using a host-owned controller:

```dart
final locations = MapLocationController(follow: true);

MapView(
  latLng: const LatLng(latitude: 47.4, longitude: 8.5),
  zoom: 16,
  locationController: locations,
);

// Call from your provider's position listener, or pass a Stream<MapLocation>
// to the controller's `locations:` constructor argument.
locations.updateLocation(MapLocation(
  point: const LatLng(latitude: 47.4001, longitude: 8.5002),
  accuracyMeters: 12,
  bearing: 90, // Optional degrees clockwise from north, in [0, 360).
  timestamp: DateTime.now(),
));

locations.pause(); // Keep updating the dot while browsing the map.
locations.follow(); // Recenter on the latest fix and resume following.
locations.stop(); // Turn follow intent off.
// Dispose in the owning State's dispose(): locations.dispose();
```

The map draws a fixed-size position dot, optional bearing indicator, and an
accuracy radius that scales with fractional zoom. New fixes smoothly retarget
the camera from its current position while preserving zoom and respecting camera
bounds. Fixes arriving within one frame are coalesced. Accuracy/bearing-only
updates repaint without restarting the camera animation.

Dragging, pinching, focal wheel/double-tap zoom, `MapController.moveTo`, and
`fitBounds` pause following. The recenter button resumes it. Plain taps and
centered zoom buttons preserve follow intent; fixes arriving during a zoom
animation are applied after it completes. Set
`locationFollowAnimationDuration: Duration.zero` for instant updates. The map
also respects the platform's reduced-animation preference.

`MapLocationController.state` reports `off`, `waiting`, `following`, or `paused`.
Observe `MapView.onLocationFollowChanged`, `MapLocationFollowChangeNotification`,
or `MapEventListenerMixin.onMapLocationFollowChanged`. `MapController` also
exposes `followLocation()`, `pauseLocationFollowing()`, `stopLocationFollowing()`,
and `locationFollowState` when the map has a location controller.

Use `showUserLocation`, `showLocationControl`, and `locationControlAlignment` to
configure the overlays. For custom positioning, disable the built-in control and
place `MapLocationControl(controller: locations, padding: ...)` in your stack.

Your app handles GPS permissions, service availability, and provider lifecycle;
FOSM adds no location plugin or native permission requirements. The controller
owns subscriptions passed to its constructor or `setStream`, cancels replaced
streams, and ignores their late events. Timestamped fixes older than the last
accepted timestamp are ignored. Stream errors retain a gray last-known dot and
stop camera updates; a valid fix clears the error and resumes existing follow
intent. Use `clearLocation()` when a fix must no longer appear, such as after
permission is revoked. MapView detaches its listener on disposal and leaves the
host's controller alive.

The example's settings include **Simulate location (Zurich)** for trying follow,
pause, and recenter without a GPS provider.

## Performance validation

The offline profile benchmark covers 10,000 markers, 1,000 densely visible
markers, a 50,000-point route, 10,000 clustered markers and mixed camera motion.
See [benchmark instructions and measured reports](docs/performance/README.md).
Widget workload tests guard viewport culling and long-route selection; profile
runs on physical hardware provide UI/raster timing and RSS observations.

## 🧪 Testing

```bash
# Run all tests
flutter test

# Run with coverage
flutter test --coverage

# Run specific test file
flutter test test/vector/vector_tile_test.dart
```

**Regression coverage:**
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
