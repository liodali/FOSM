# Web and desktop measurements

Procedures for the remaining browser and desktop work in
[plan 10](../../../.plan/performce/10_web_and_desktop.md). These are
measurement guides, not results; every capture should record device,
OS/browser version, renderer, viewport, DPI and refresh rate.

## Browser renderer variants

Flutter 3.47 ships two production web renderers; the legacy `html`
renderer has been removed, so the deployed axis is CanvasKit (JS) vs
skwasm (Wasm GC). Both must stay green because the decoders and the
scheduler run in both:

```sh
# CanvasKit / dart2js (default)
flutter test --no-pub --platform chrome --reporter expanded \
  test/common/tile_work_scheduler_test.dart \
  test/vector/frame_scheduling_test.dart \
  test/vector/vector_pipeline_test.dart \
  test/vector/vector_tile_test.dart \
  test/view/fractional_zoom_test.dart \
  test/view/map_frame_coalescing_test.dart

# skwasm / Wasm GC — add --wasm
flutter test --no-pub --platform chrome --wasm --reporter expanded <same files>
```

skwasm exercises different microtask/event ordering than dart2js: a
scheduler fix that only holds on the VM/dart2js ordering (the image-lane
slot release) was caught by the `--wasm` run. Keep both in the rotation
when touching `TileWorkScheduler`, the image lane or anything that
awaits engine futures.

## Bitwise-packing audit

dart2js compiles `&`, `|`, `^` to 32-bit unsigned results and truncates
`<<` to 32 bits. Before changing any decoder or key builder, check the
value domain:

- Varints/zigzag: `ProtobufReader.readVarint` folds shifts ≥ 28 with
  exact power-of-two multiplication; `_zigzag` uses `~/ 2` and `& 1`
  only. Do not reintroduce `(v >> 1) ^ -(v & 1)` or `byte << shift`
  for shifts ≥ 28.
- Batch/group keys: records or strings — never `argb << 8`-style
  packing.
- `1 << z` tile-math is safe for z ≤ 30 (MapView validates max zoom
  ≤ 30; `1 << 31` is negative on dart2js, so keep zoom bounds intact).
- `hashCode ^` combining and `Color((a << 24) | rgb)` from parsed hex
  stay within their domains (hash quality / Flutter byte-normalizing
  Color).

Regressions covering the decoder fixes live in
`test/vector/vector_tile_test.dart` (negative deltas both axes, ids and
int values above 2^31); the pixel pipeline tests cover the rendered
result on both renderers.

## Production vector mode in the browser

The example app ships a raster⇄vector mode switch (Liberty and custom
style URLs), which is the workload for browser vector profiling:

```sh
cd example
flutter run --profile -d chrome \
  --dart-define=fosm.traceVector=true \
  --dart-define=fosm.traceMemory=true
```

Record with Chrome DevTools (Performance tab; enable the Flutter
extension frames if available):

1. Idle baseline (10 s), then switch raster → vector and capture the
   full style-load window: style fetch, first tile batch, first
   `Picture.toImage` burst (`fosm.vector.*` spans).
2. Sustained pan/zoom on the loaded vector map (30 s) — long tasks on
   the main thread should stay segmented by the cooperative yields.
3. Switch vector → raster → vector again and watch the
   `FOSM memory:` lines for retained growth across switches (style
   namespaces are expected to grow the disk cache; parsed/label buckets
   must not survive the runtime swap).
4. Repeat with `--wasm` (add `--wasm` to the run command) and compare
   the same spans; skwasm changes parse/rasterize costs.

What to record: p95/p99 of the trace spans (`parse`, `record`,
`toImage`, `labels.*`), main-thread long tasks, heap snapshots before
and after each mode switch, and the `FOSM memory:` attribution lines
alongside `performance.memory` (Chrome-only).

## Desktop (macOS/Windows/Linux)

Frame/input tails, resize, high-DPI and large viewports are separate
workloads; the benchmark harness supports all four:

```sh
cd example
flutter run --profile --start-paused -d macos \
  -t lib/benchmark/map_benchmark.dart \
  --dart-define=BENCHMARK_LABEL=desktop-base
```

- **Input/frame tails**: the five standard scenarios already report
  UI/raster p95/p99/max and frames over budget — use the regular
  capture flow from the [main README](README.md).
- **Resize**: add `--dart-define=BENCHMARK_RESIZE=true`. The harness
  runs `resize_idle` (static camera — frames come only from window
  resizing) and `resize_motion` (camera motion while resizing). Drive
  the resize from outside the app so the harness measures real window
  pipeline cost, and synchronize on the printed markers:
  `FOSM_BENCHMARK_SCENARIO <name>` announces a scenario (with its
  warmup/sample seconds), `FOSM_BENCHMARK_SAMPLE_START/END <name>`
  brackets the recording window — the driver should resize only inside
  that window:

  ```sh
  flutter run --profile -d macos -t lib/benchmark/map_benchmark.dart \
    --dart-define=BENCHMARK_RESIZE=true \
    --dart-define=BENCHMARK_LABEL=desktop-resize > /tmp/fosm-desktop.log 2>&1 &

  # Driver: for each scenario, wait for its sampling window, then
  # alternate between two window sizes for its duration (6 s).
  ( for scenario in resize_idle resize_motion; do
      while ! grep -q "FOSM_BENCHMARK_SAMPLE_START $scenario" /tmp/fosm-desktop.log; do
        sleep 0.1
      done
      for i in $(seq 12); do
        osascript -e 'tell application id "your.bundle.id" to set bounds of window 1 to {0, 0, 1280, 800}'
        sleep 0.25
        osascript -e 'tell application id "your.bundle.id" to set bounds of window 1 to {0, 0, 1920, 1200}'
        sleep 0.25
      done
    done ) &
  ```

  The harness captures the initial viewport (physical size and DPR) before
  `SAMPLE_START`, then tracks `didChangeMetrics` events independently of
  batched frame-timing reports. It reports `viewportChanges`, `viewportSizes`
  (including the initial size) and a `valid` flag per scenario. A sample
  without a viewport change or recorded frames yields `valid: false` and a
  `FOSM_BENCHMARK_INVALID` line:
  `resize_idle` then has no frames at all (percentiles report 0) and
  `resize_motion` measures camera motion only. Discard invalid lines
  instead of treating them as results.

- **High-DPI / large viewports**: run the standard scenarios on each
  display (Retina vs external 1×) and with the window maximized; the
  `FOSM_BENCHMARK_META` line records `devicePixelRatio` and physical
  size so runs stay attributable. Compare per-scenario raster tails
  across DPI — rasterization cost scales with pixels, UI/build cost
  should not.

Keep native-asset builds sequential when desktop and browser shares
Flutter build outputs (`flutter test -p chrome` and a macOS build can
race on the same cache directory).
