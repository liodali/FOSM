## Unreleased

* Add friction-based fling panning with `MapView.enableFling`, bounds enforcement, immediate touch/command interruption, and cancellation-safe pan animation cleanup.
* Add cursor-anchored mouse-wheel zoom with `MapView.enableScrollZoom`, accumulated small deltas, zoom limits, and nested scroll handling.
* Preserve cumulative pinch scale with reversal damping; correct multi-level zoom animation scaling and preserve momentum when parents echo camera callbacks into widget properties.

* Add geographic map tap/long-press callbacks and notifications, with feature selection that preserves marker and camera gesture priority.
* Add `MapPolygon` fills, borders, holes, and selection below routes and markers.
* Add polyline tap/long-press hit results with the nearest route point, segment index, pixel distance, and configurable hit tolerance.
* Extend `MapEventListenerMixin` with map, polygon, and polyline interaction hooks and demonstrate area/route selection and long-press pins in the example.

* Add configurable total HTTP request deadlines, cancellation on disposal, and typed `TileLoadException` failures across native and Dio transports.
* Add `MapLoadState`, `MapView.loadingBuilder`, `errorBuilder`, and `onTileError`, with viewport progress and explicit retry while loaded tiles remain visible.
* Retry transient failures automatically and require explicit retry for permanent HTTP errors; settle outstanding native worker requests during disposal.

* Add a configurable persistent cache with a 256 MiB compressed-payload budget, seven-day absolute expiry, and LRU eviction.
* Add `initMap(diskCacheOptions: ...)`, `MapDiskCache.configure`, `stats`, `prune`, and `clear`.
* Preserve legacy raw-byte/base64 payloads with additive cache metadata and keep disk-cache clearing compatible with active tile managers.

* Retain recently rendered tiles for return pans and zooms using a 50 MiB estimated pixel-memory budget and a 20-second idle grace period.
* Protect current grid and zoom snapshot images from eviction, and release snapshots when animations finish, are interrupted, or the map changes style.
* Add `MapView.maxRenderedCacheBytes` and `MapView.renderedCacheRetention`, including runtime configuration updates.

## 0.0.2

* Added `cameraBounds` to `MapView` — a hard bounding box the camera can never pan, pinch, or programmatic-move outside of.
* Added `MapController.fitBounds` to navigate the camera so a box (e.g. a route) fits the viewport, with optional padding and animation.
* Added `LatLngBounds` with `fromPoints`, `contains`, and `center`.

## 0.0.1

* Added polyline styling: solid, dashed, and dotted patterns.
* Added optional `borderColor` / `borderWidth` casing to `MapPolyline`.
* Added `strokeCap`, `strokeJoin`, and `strokeMiterLimit` to `MapPolyline`.
* Introduced `MapPolylinePattern` with `solid`, `dashed`, and `dotted` variants.
