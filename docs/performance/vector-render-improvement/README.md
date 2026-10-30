# Vector render baseline & attribution (plan 01)

Harness for
[plan 01 — baseline and stage attribution](../../../.plan/vector_render_improvement/01_baseline_and_attribution.md).
Status: **harness implemented; device captures and the baseline report are
pending** (step 2). Nothing in here is a measurement yet.

## What this harness controls

- **Fixed payloads**: deterministic synthetic MVT (identity
  `mvt-synth/1`, `example/lib/benchmark/vector_payloads.dart`) served over
  HTTP by `example/tool/vector_payload_server.dart`. Same inputs always
  produce byte-identical tiles; the style caps its source at maxzoom 14 so
  z15/z16 logical tiles over-zoom from z14 sources. Payload identity =
  generator version + profile (`denseCity`|`suburb`) + seed, recorded in
  every result line and in `FOSM_BENCHMARK_META`.
- **Fixed style/viewport/device**: two style variants over one source
  (`style-a.json`, `style-b.json`); every scenario uses the same center,
  viewport and camera-path math (fling/pinch parameters are identical to
  `map_benchmark.dart` so camera paths compare across harnesses).
- **Raster control**: `raster_control_static`/`raster_control_fling` run
  the same camera path through the raster pipeline against the same
  server, so provider/transport differences are not attributed to vector
  rendering.

### Payload complexity (what "dense city" means here)

Per `denseCity` tile (extent 4096): 3 large water polygons (8–14
vertices), 14 landuse polygons (6–11 vertices, classed), 1400 building
footprints (4-vertex rectangles), 446 roads — 46 major (9–23 vertices,
classed/named/ranked), 260 minor and 140 service (gridded, jittered,
6–14 vertices, ~50% named) — and 110 named POI points. `suburb` shrinks
to 260 buildings, 124 roads, 28 POIs. The style evaluates 9 layers with
match/step/interpolate expressions, data-driven colors, two dash arrays
and two symbol layers (point + line placement).

**Caveat**: these payloads *control* the workload; they do not prove
production representativeness. Real OpenMapTiles city tiles have more
irregular geometry, wider property tables and heavier label density. Any
optimization selected from this baseline must be re-validated against a
frozen production tile sample (recorded real tiles, same scenarios and
cache states) before the result is generalized.

## Cache states

Each scenario names its cache state (`cacheState` in the result line) and
the app establishes it exactly as follows — no active map can race the
clear because cold states unmount the map (disposed state) first:

| State | Establishment |
|---|---|
| `coldBytes` | unmount map → clear persistent disk cache → **arm recording** → mount fresh map (generation-keyed). The replacement's first load frame is the first measured frame. |
| `warmBytesColdParsed` | unmount → **arm** → remount (no disk clear): fresh runtime (empty parsed/rendered/memory-byte caches); tiles re-read from disk bytes. |
| `warmParsedColdImages` | mounted, settled at the exact target viewport → **arm** → `MapController.dropRebuildableCaches(includeVisibleImages: true)` releases snapshot/fallback pins and evicts all rendered images, then immediately reloads the same viewport. Parsed tiles, memory/disk bytes and labels survive. The gate requires `record` + `toImage` and rejects fresh `parse` events. |
| `warmRendered` | mounted, settled (allSharp, no loads, labels stable ×5 frames) → **arm**. |

`settled:false` in a result line means the settle phase timed out — treat
that run's warm claims accordingly; never silently read it as warm.

## Scenarios

`raster_control_static`, `raster_control_fling`, `vector_cold_static`,
`vector_cold_fling`, `vector_cold_return`, `vector_cold_pinch`,
`vector_cold_overzoom` (z16 over z14 sources), `vector_warm_static`,
`vector_warm_fling`, `vector_warm_bytes_static`,
`vector_warm_parsed_static`, `vector_style_switch` (a→b at window half).

Every result line carries UI/raster p50/p95/p99/max, frames over 16.67 ms
and over the display's actual budget, per-frame coverage series
(covered/sharp), labels-ready metrics (`firstLabelsMs`, `labelsStableMs`,
`labelsDrainedMs`, end counts), `maxFailedTiles` (unreachable coverage is
declared, never silent), and memory peaks (rendered bytes, parsed tiles,
prepared labels, RSS before/after).

### Metric definitions

- **Measurement start (t=0)** is the arming of the recording window — for
  cold scenarios the frame *before* the replacement map mounts, so its
  first load frame is the first measured frame.
- **Empty grids are excluded, not read as covered**: frames with
  `visibleCells == 0` (grid not laid out yet) are skipped and counted in
  `coverage.emptyGridFrames`.
- **Coverage granularity** is reported twice: cell-count fractions
  (`coveredFraction`/`sharpFraction`, every visible grid cell weighted
  equally) and pixel-area fractions (`coveredAreaFraction`/
  `sharpAreaFraction`, cells weighted by their viewport intersection).
  Partial viewport-edge cells make the two diverge; quote the right one
  for the question being asked.
- **Newly exposed regions**: `newlyExposedCells`,
  `newlyExposedSharpByEnd`, `meanNewToSharpMs` and `maxNewToSharpMs`
  cover only cells first visible after the window's first sample, so
  motion scenarios report time-to-sharp for cells revealed during the
  pan rather than for cells visible all along. (Cell ids are namespaced
  per style, so a style switch correctly reads as full re-exposure.)
- **Labels-ready** is `labelsViewportReadyMs`: the first frame where
  imagery is complete (all sharp), the preparation queue is drained
  (`memoryAttribution.labelJobsOutstanding`), *and* every sharp cell's
  tile completed preparation (`MapController.labelPreparedTileKeys`,
  with successfully-prepared-but-zero-label tiles counting as prepared).
  A temporarily empty queue while other visible tiles are still
  downloading does not make the viewport ready; `labelsDrainedMs` is
  only the drained-queue component.

## Attribution arms

Run with `example/tool/capture_vector_baseline.sh DEVICE_ID OUT_DIR`:

| Arm | Defines | Purpose |
|---|---|---|
| clean ×3 | — | user-visible numbers (no instrumentation bias) |
| spans ×2 | `fosm.vectorSpans=true` | per-stage distributions + per-tile critical paths (`FOSM_BENCHMARK_VECTOR_STAGES` lines) |
| trace ×1 | `fosm.vectorSpans=true` `fosm.traceVector=true` | DevTools timeline; the capture script also saves the VM timeline (`<label>-timeline.json`) and **fails the run if it contains no `fosm.vector.*` events** |

**Worker-timeline acceptance gate**: the in-process span log stays on the
main isolate and cannot see worker parsing. The parse-vs-drawing
conclusion may only be drawn once the saved worker-isolate timeline
exists — the trace arm produces it. Its capture gate validates the
timeline **per scenario**: the app emits `fosm.benchmark.sampleStart/
sampleEnd.<scenario>` boundary markers on the timeline clock, every
scenario must show both boundaries, and each scenario's cache state must
show its required pipeline events — cold-like and style-switch scenarios
require worker `parse` events; `warmParsedColdImages` requires
`record`+`toImage` and rejects fresh worker `parse` events (parsed data must stay warm);
fully-warm and raster scenarios require only the boundaries. A coarse
global window-span check (≥80%) guards against late arming. Failures
exit with code 3; the saved file records the per-scenario gate numbers.

### Span identity and semantics

Stage semantics ([trace guide](../vector-processing.md)): **sync** spans
(`recordChunk.*`, `style`, `geometry`, `dash`, `parseDispatch`,
`parseReply`, `labels.paint`) wrap synchronous closures and are
CPU-attributable per slice; **async** spans (`fetch`, `queueWait`,
`parseWait`, `record`, `imageWait`, `toImage`, `labels.build`,
`labels.layout`) measure elapsed time including waits, may overlap, and
must never be summed as CPU.

Identity: tile coordinates alone cannot identify a rendering attempt —
return pans, retries and style switches reuse them, and shared parses
serve multiple logical tiles. Every stage span therefore carries:

- `tile` — the logical `z/x/y` being produced;
- `attempt` — `<runtimeId>.<n>` (runtime instance + decode sequence,
  assigned at the concurrency-gate entry, so `queueWait` through
  `toImage` and the label lane share one id; fetches run per
  tile-manager job before any attempt starts and aggregate per tile
  with their source tiles listed);
- `source` — the resolved source tile `z/x/y` after over-zoom, so
  over-zoom siblings sharing one parse/download correlate through it.

Zero-duration markers: `staleAbort` (aborted while queued or during
render), `payloadInvalid` (undecodable bytes), `publish` (the tile
manager placed the image into the visible grid, carrying the completed
decode attempt it claims). Timeline events carry the same identity as
`arguments` (`tile`/`attempt`/`source`) so DevTools captures correlate
identically, including the worker's `parse`/`parseReply` (a shared parse
carries the triggering first-requester attempt).

**The stage report keeps stage detail per attempt**
(`tiles.<coord>.attempts.<id>`): each attempt carries its wall-clock
window (`startUs`/`endUs`), its resolved source tiles, and a `stages` map
with every stage's `startUs`/`endUs`/`totalUs`/`n` (plus `sources` where
the span resolved one) — so queue gaps (for example
`queueWait.endUs → parseWait.startUs`) and shared parses (several
attempts naming the same source tile) can be reconstructed, and retries
and style switches stay distinguishable. Per-attempt sums are
critical-path lengths for that attempt, not global CPU totals.

Parsing logs:

```sh
cd example
dart run tool/parse_benchmark_log.dart OUT/*.log > OUT/report.json
dart run tool/extract_vector_stages.dart OUT OUT/stages
```

## Manual reproduction

```sh
# Terminal 1 — payload server (LAN IP for device runs; the server also
# hosts the browser marker sink at POST /log with --marker-log-dir):
cd example && dart run tool/vector_payload_server.dart --host 0.0.0.0 --port 8787 \
  --marker-log-dir ../docs/performance/vector-render-improvement/raw/browser

# Terminal 2 — app (profile mode only):
cd example && flutter run --profile --start-paused -d DEVICE_ID \
  -t lib/benchmark/map_vector_benchmark.dart \
  --dart-define=BENCHMARK_VECTOR_BASE=http://LAN_IP:8787 \
  --dart-define=fosm.vectorSpans=true
```

The example app permits cleartext to local network hosts for this server
(`NSAllowsLocalNetworking` on iOS, `usesCleartextTraffic` on Android).

Capture scripts (full rounds, parse steps included):

```sh
# device: clean×3, spans×2, trace×1 (trace saves the worker timeline)
cd example && zsh tool/capture_vector_baseline.sh DEVICE_ID \
  ../docs/performance/vector-render-improvement/raw LAN_IP 3 2 1

# browser (Chrome, separate report): builds two profile web apps, serves
# them statically, drives Chrome directly and captures via the marker
# sink; native debug extension/~the flutter run chrome path is unusable
# (flutter_tools starts Chrome with --disable-extensions, so app prints
# cannot be relayed):
cd example && zsh tool/capture_vector_baseline_web.sh \
  ../docs/performance/vector-render-improvement/raw/browser \
  http://LAN_IP:8787 2 2 8787
```

## Deliverable checklist (plan-01 acceptance)

The baseline report (pending, `baseline-*.md` + `raw/` here) must include,
per scenario and arm: per-stage distributions, first/95%/complete sharp
coverage, coverage-over-time, labels-ready latency, UI/raster p95/p99,
missed frames at the actual refresh rate, stale work, peak/settled memory,
and explicit unreachable-coverage declarations. Plan-01 task checkboxes
are ticked only from these captures — unit tests verify the harness, not
the measurements.

## Review corrections — 2026-10-30

The strict warm-parsed capture now uses a stationary image reload after the
recording window opens. Older `vector_warm_parsed_return` results measured
retained-image return pans and do not satisfy this cache state. Repeat the
changed scenario before comparing parse-free rendering cost. The workload
hook requires settled presentations; active jobs cause StateError.

Fetch tracing now lives around the common TileManager resource request,
including native HTTP-isolate downloads, with one span per shared download.
Timeline snapshot merging preserves phase, async identity, process, scope and
correlation arguments using canonical full-event JSON. First-sharp and
95%-covered/sharp crossings use the complete sample series before reduction.
These corrections require new captures; existing raw files are historical.

Round-2 captures (2026-10-30, same day) satisfy these requirements —
device numbers in `baseline-iphone.md` supersede the round-1 artifacts
under `raw/round1/`, and the browser capture (`baseline-browser.md`)
runs on the marker-sink transport because flutter_tools' Chrome cannot
host a debug connection (`--disable-extensions`). Kilobyte payload lines
ride out chunked (`FOSM_BENCHMARK_CHUNK`/`_END`) and parsers reassemble
them (`lib/benchmark/log_lines.dart`); the app also posts whole lines to
the `/log` sink when `BENCHMARK_MARKER_URL` is defined (web runs).
