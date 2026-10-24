## Unreleased

* Verify both production web renderers in the test rotation and fix a scheduler ordering bug the skwasm run exposed: an image-lane work's result completed before its slot was released, so a submission arriving right after a finished image could see a fully drained lane as busy and wait an extra frame (VM/dart2js ordered the race benignly; skwasm did not). Finished work now releases its slot synchronously before completing its result, with delivery timing otherwise unchanged. The selected Chrome suite (67 checks) passes on CanvasKit and skwasm.

* Add a browser/desktop measurement guide (renderer-variant commands, the dart2js bitwise-packing audit checklist, production vector-mode profiling with the example app's style switcher, desktop resize/high-DPI/large-viewport procedures) and a `--dart-define=BENCHMARK_RESIZE=true` benchmark mode with `resize_idle`/`resize_motion` scenarios driven by an external window resizer.

* Attribute retained memory per bucket and expose it for measurement: `MapController.memoryAttribution` reports rendered-image bytes (protected vs evictable), the compressed byte cache, parsed vector tiles (coarse heap estimate), raster-source images, prepared labels, geometry rings and outstanding load counts; `--dart-define=fosm.traceMemory=true` logs one `FOSM memory:` line per attached map per second for long-session device captures. The estimated total includes cached geometry coordinate storage, and buckets without an honest byte estimate (label painters, sprite atlas, marker index, disk cache) are documented as uncounted. The attribution types are exported from `package:fosm/fosm.dart`.

* Handle system memory pressure deliberately: on `didHaveMemoryPressure` (iOS/Android memory warnings) the map releases every rebuildable cache — compressed bytes, unused rendered imagery, parsed vector tiles, raster-source images (deferred until the decode lane is idle so no in-flight render references a disposed image), prepared label painters and geometry rings — while the visible grid, pinned zoom-fallback imagery and camera state survive; labels re-prepare as tiles decode again.

* Make `VectorTileRuntime.dispose` idempotent (a second dispose previously threw from the label notifier) and stress-test disposal while network fetches, decodes and presentations are still outstanding: late decode results are disposed at the boundary, late fetches repopulate nothing, queued decode waiters unwind as aborted work instead of hanging, and label preparation pending across dispose is dropped without notifying disposed listeners.

* Settle all outstanding work when the persistent MVT worker is disposed: pending decodes complete as cancelled with their reply ports closed (a killed worker's replies never arrive, so waiting would hang the caller and the parse bookkeeping forever), and a spawn aborted mid-handshake fails instead of hanging while still allowing a later retry. A dispose that lands while `Isolate.spawn` is still resolving kills nothing itself, so the late-created worker handle is tracked by spawn generation and killed by the aborted spawn instead of surviving until a second dispose. The runtime treats a failed worker as unavailable and falls back to one-shot decoding. Verified with native parsing enabled, including a runtime-level dispose-while-parsing unwind and a dispose-before-spawn-completes regression.

* Keep cached cluster badge coordinates aligned with the clamped public centroid, including polar latitudes and off-world longitudes, so rendering and tap/focal-zoom positions agree.

* Fix indexed-marker review findings: preserve widget state with stable per-insertion keys (including duplicate cluster occurrences above max zoom), remove bulk selections in O(n), keep non-projectable markers outside spatial buckets without corrupting collection state, and preserve identity-based cluster deduplication.

* Index the marker collection geographically: `MarkerManager` maintains a uniform-grid index (`MarkerIndex`) incrementally on every mutation with insertion-order, identity and duplicate semantics matching its list API. `MarkerLayer` queries the cull-padded viewport instead of scanning the whole collection each frame, and `MarkerManager.revision` now bumps on removals and clears too.
* Project markers from cached normalized Web-Mercator coordinates: the trigonography runs once per marker instance and per-frame screen positions (including cluster badges and single cluster items) become exact power-of-two scalings — bit-identical positions without per-marker trig. Clustering consumes the same cached coordinates, so grouping rules and results are unchanged while zoom-step recomputations stop re-projecting every marker.
* Lazily check overlay-into-cluster dismissal only while an overlay is open (early-exit), and skip per-notification O(n) collection copies when pruning measured overlay markers (`MarkerManager.containsMarker`).
* Add `fosm.markers.query`/`project`/`cluster`/`build` timeline spans for independent marker-pipeline stage profiling (`--dart-define=fosm.traceMarkers=true`).
* Add marker regressions: index-vs-brute-force viewport parity across randomized cameras and off-world markers, duplicate/remove semantics, manager/index consistency and revision bumps on every mutation kind; clustering parity against a direct-trig reference engine; moving-marker fleets rebuilt only within the visible band; high-frequency location fixes; cluster results reused across pans and fractional zoom within an integer step (recomputing only on zoom-step crossings and mutations).

* Fix label cache-insertion timing: prepared labels become cache-visible only after every text/halo painter is laid out, so a frame painting while preparation is in flight can never trigger feature scanning or text layout. Build and layout share one cleanup guard — any cancellation or failure disposes the whole uncached batch, including painters already laid out before the abort.
* Cache zoom-only style expressions across tiles: symbol layers get one per-(layer, zoom) style entry with precomputed property-dependency analysis, memoised static values (text-size steps, colors, halos, spacing, anchors) and `symbol-placement`, shared by every tile at that zoom. Property-driven expressions still evaluate per feature.
* Compile layer filters once into closures (`compileFilter`) for label preparation instead of re-walking the raw filter tree per feature, with `matchesFilter` semantics preserved exactly (legacy bare-key forms, `in`/`has` variants, empty-argument edges).
* Add `fosm.vector.labels.paint`/`labels.build`/`labels.layout` timeline spans so collision placement during motion profiles separately from feature scanning and text layout (`--dart-define=fosm.traceVector=true`).
* Add label regressions: prepared-tile LRU bound, dense line-label cancellation mid-layout, static vs data-driven text sizing across tiles, zero paint-time layouts after notification, and a no-starvation drain harness behind continuously entering tiles.

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
