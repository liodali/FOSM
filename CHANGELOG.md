## Unreleased

* Yield during long vector bounds scans and dashed-line extraction, stop bounds scanning once overlap is established, and add optional `fosm.traceVector` timeline spans for parsing, style/geometry recording and image creation.

* Separate camera motion from grid reconciliation: paint anchors recompute on every pan frame while tile slots, jobs, cache keys and demand generations are rebuilt only when the covering membership (source zoom, window, viewport, padding) actually changes. Sub-tile panning no longer reallocates the grid or reprioritises in-flight work.
* Coalesce pinch/pan updates to one application per display frame — first event immediate, bursts keep the latest focal point and cumulative scale — while discrete zoom steps keep their own event timing, snapshot capture and focal anchoring. Camera commands cancel queued gesture updates and rebase an active gesture onto the commanded camera with a floating zoom baseline (cancelling any animation the command started when manipulation resumes), and the per-frame slot re-arms at real frame boundaries so sparse input applies immediately.

* Fix a potential image-lane stall: `TileManager` no longer infers decoder scheduling ownership from `byteOnlyPadding`. Pass `decoderOwnsImageScheduling` when a decoder (e.g. `VectorTileRuntime`) already submits its own image work through the shared `TileWorkScheduler`; nesting both would occupy every slot with decodes waiting for a slot.
* Stop charging idle time (network waits, frames without tile work) against the shared work budget: `TileWorkScheduler` restarts the allowance after an idle gap and an idle image lane accepts new submissions without waiting another frame.

* Fix web (dart2js) vector rendering: bitwise operators truncate to unsigned 32-bit values in JavaScript, which corrupted every negative geometry delta (`2^32 + delta`), silently misplaced or culled geometry, and broke browser pixel output. Decode zigzag and multi-byte varints with exact arithmetic and key fill batches without `<<` packing.
* Add web-regression decoder tests for negative deltas on both axes and for feature ids/int values above 2^31.

* Share a frame-paced UI-work allowance across vector rendering and label preparation; yield through Flutter paint before continuing heavy tile work.
* Bound raster decode/vector image submissions, re-evaluate queued image priority and relevance, and release pending work on disposal.
* Hold background preloads until foreground presentation drains, preserving independent visible download capacity.

* Add host-supplied location streams, validated/timestamp-ordered fixes, smooth camera following, gesture pause and recenter, and follow-state callbacks/notifications.
* Add position, bearing, and geographic accuracy overlays plus a configurable location control; retain last-known fixes on recoverable stream errors.
* Add a simulated-location example and coverage for stream lifecycle, fractional zoom, camera bounds, gestures, and follow animation retargeting.

* Add opt-in continuous display zoom via `enableFractionalZoom`, controlled `fractionalZoom`, `onFractionalZoomChanged`, and `MapController.setFractionalZoom`/`fractionalZoom`, preserving integer APIs and tile keys.
* Scale tile geometry, marker/shape/label projection, bounds and the distance ruler consistently; keep widget/stroke/text sizes fixed and retain bounded fallback images while new grids load.
* Animate fractional wheel/button/controller/fit-bounds zoom, preserve focal points during pinches, and expose precise values on camera notifications and listener hooks.
* Add a repeatable native profile benchmark, recorded physical-iPhone results, and 10,000-marker/50,000-route-point workload regressions. Enable fractional zoom in the example with a runtime switch.

* Add optional metric/imperial distance rulers via `MapView.showScaleBar`, `scaleBarUnit`, `scaleBarAlignment`, and `scaleBarMaxWidth`.
* Export `MapScaleBar` with latitude-aware ground resolution, readable 1/2/5 distances, accessibility labels, responsive layout, and pointer-transparent painting.
* Enable the scale bar in the example and add a visibility switch.

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
