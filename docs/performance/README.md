# Map performance validation

Measured comparison: [physical iPhone profile results](results-ios.md).
Scheduler A/B (single binary, `fosm.unpaced` arm): [results](results-scheduler-ios.md).
Matched Flutter/MapCore vector workload tooling: [native comparison](native-comparison.md) (device comparison pending).

The frame-pacing change introduces a shared 2 ms cooperative allowance for
vector recording and label preparation, plus bounded raster/vector image
submissions. Scheduler and pipeline tests verify pacing, priority, cancellation,
coverage progress, and unchanged pixels. The saved iPhone reports predate this
change and are not measurements of its impact. A follow-up comparison should
include cold production vector loads while pinching/panning, time to visible and
sharp coverage, frame p95/p99, and memory; the warm offline benchmark below is
useful for camera regression checks but cannot establish cold-vector gains.

## Scheduler A/B runs (one binary, one changed variable)

The scheduler is the feature under test for plans 01–02. Build the profile
binary once and run it twice, changing only the scheduler:

```sh
flutter run --profile --start-paused -d DEVICE_ID -t lib/benchmark/map_benchmark.dart \
  --dart-define=BENCHMARK_LABEL=scheduler > /tmp/fosm-paced.log 2>&1
# …repeat with: --dart-define=fosm.unpaced=true --dart-define=BENCHMARK_LABEL=unpaced
```

`--dart-define=fosm.unpaced=true` makes every `MapView` leave its tile work
unpaced (the pre-scheduler behaviour: no cooperative allowance, unbounded
image submission) with every other byte of the binary identical, so device,
viewport, trajectory and build are equal by construction. Both arms record
`schedulerPaced` in `FOSM_BENCHMARK_META`. Never ship a build with this
define enabled.

The full four-run comparison (paced/unpaced × warm/coldnet) is scripted:

```sh
cd example
zsh tool/capture_scheduler_ab.sh DEVICE_ID /tmp/fosm-ab-captures
dart run tool/parse_benchmark_log.dart /tmp/fosm-ab-captures/paced.log \
  > ../docs/performance/scheduler-paced-ios.json
```

The parser wraps META plus every result line into the structured raw-report
format used by the saved iPhone runs, recording the exact commit and arm.

## Load and motion acceptance scenarios

`--dart-define=BENCHMARK_LOAD=true` replaces the five warm camera-loop
scenarios with six acceptance scenarios (same reporting lines):

| Scenario | What it measures |
|---|---|
| `cold_static` | Cold load of a still camera: time to covered/sharp coverage and blank fraction while tiles stream in (per-frame coverage series in the result line) |
| `cold_fling` | Alternating decaying flings from a cold map: frame tails and coverage while tiles arrive during motion |
| `cold_pinch` | Continuous zoom-direction reversals from a cold map: fallback/retirement churn while tiles arrive |
| `warm_fling` | The same flings on a warm map: motion-frame tails without loading cost |
| `warm_pinch` | The same reversals on a warm map |
| `follow` | Simulated GPS fixes (4 Hz, walking pace) with camera retargeting |

Cold scenarios unmount the map entirely first — the disposed state can
neither load from nor write to storage while it is cleared — then arm
recording (timings, coverage clock, series) *before* mounting a fresh
map on a new generation key. The replacement's first load frame (grid
build, fetch issuance, early arrivals) is therefore the first frame of
the measured window: no cold work escapes it. There is no warmup
window. Coverage is sampled once per rendered frame through
`MapController.tileCoverage`: strict-viewport cells showing imagery —
their own published image **or** zoom-fallback imagery (per-region
fallback presence, so visible fallback crops never count as blank) —
versus cells with their own current-zoom image (sharp); off-world rows
and padding never count. Results report `coverage.firstCoveredMs`,
`allCoveredMs`, `allSharpMs`, `minSharpFraction`, window-integrated
`meanCoveredFraction`/`meanSharpFraction` (each sample holds until the
next, with boundary extension to the recording-window ends, so arms
publishing at different frame frequencies — or a still map whose frames
stop early — compare coverage over the *whole* window),
`sharpFractionEnd` and ≤72-point downsampled `seriesMs`/`seriesCovered`/
`seriesSharp` arrays. `motion`, `cold`, `net`
and per-scenario `network` traffic counters (`requests`, `failures`,
`bytesServed`) are recorded with every result line. The log parser
(`tool/parse_benchmark_log.dart`) skips `valid:false` results and flags
logs without a `FOSM_BENCHMARK_DONE` marker (exit code 2) so truncated
runs cannot pass as measurements.

Related defines (composable with `BENCHMARK_LOAD` or the standard set):

- `--dart-define=BENCHMARK_COLD=true` — start *every* scenario cold,
  including the five standard ones.
- `--dart-define=BENCHMARK_NET_DELAY_MS=150` — fixed RTT per tile fetch.
- `--dart-define=BENCHMARK_NET_KBPS=1000` — bandwidth cap; transfer time is
  shaped by payload size. `0` disables.
- `--dart-define=BENCHMARK_NET_DROP_EVERY=8` — fail every Nth fetch once
  (exercises the error/retry path). `0` disables.
- `--dart-define=BENCHMARK_SAMPLE_SECONDS=12` — sampling window (default 6);
  slow networks need longer windows for coverage to complete.

A full cold-load comparison run:

```sh
flutter run --profile --start-paused -d DEVICE_ID -t lib/benchmark/map_benchmark.dart \
  --dart-define=BENCHMARK_LABEL=paced-coldnet \
  --dart-define=BENCHMARK_LOAD=true \
  --dart-define=BENCHMARK_NET_DELAY_MS=150 --dart-define=BENCHMARK_NET_KBPS=1000 \
  --dart-define=BENCHMARK_SAMPLE_SECONDS=12
```

Still not covered by these scenarios (open): production vector loads and
mode/style switches (need the vector style path), real network variability,
input-to-present latency of pointer events, background/resume sessions and
120 Hz hardware. The `network` counters report request volume; obsolete
decode/parse counts need package-level counters and remain open.

The native profile benchmark is `example/lib/benchmark/map_benchmark.dart`.
It runs five deterministic offline workloads: 10,000 distributed markers,
1,000 densely visible markers, a 50,000-point route, 10,000 clustered markers,
and a mixed camera workload with 1,000 markers and 10,000 route points.

From `example/`, run on a connected physical device:

```sh
flutter run --profile --start-paused -d DEVICE_ID -t lib/benchmark/map_benchmark.dart --dart-define=BENCHMARK_LABEL=baseline > /tmp/fosm-profile.log 2>&1
```

Wait for the VM service URL in `/tmp/fosm-profile.log`. From a second terminal
in `example/`, subscribe to stdout and resume the paused entrypoint:

```sh
dart run tool/capture_benchmark.dart /tmp/fosm-profile.log > /tmp/fosm-profile-results.log
```

The capture helper uses only Dart's standard library, talks to the local
forwarded VM service, and exits at the benchmark's completion marker. Starting
paused prevents a slow wireless/Xcode attach from losing early results.
To benchmark continuous zoom, append
`--dart-define=BENCHMARK_FRACTIONAL=true --dart-define=BENCHMARK_LABEL=fractional`
to the Flutter command (replace the baseline label). The mixed camera workload
then uses continuous zoom; its trajectory differs from the baseline's rounded
integer zoom. The other four camera workloads are identical.

Keep the app visible and the device unlocked. Each scene warms for two seconds,
drains batched warmup timings, samples six seconds of scripted camera movement,
then drains the remaining profile frame reports. Copy the JSON lines prefixed
`FOSM_BENCHMARK_META` and `FOSM_BENCHMARK_RESULT` into a report. Stop the app after
`FOSM_BENCHMARK_DONE` using `q` in its terminal or Ctrl-C.

Reports include UI/build and raster p50/p95/p99/max timings, frame counts above
16.67 ms and the display's refresh budget, and process RSS before/after each
scene. RSS includes native engine/GPU allocations; these short samples alone
cannot establish a memory leak. Compare repeated runs on the same device,
orientation, viewport, thermal conditions and refresh rate.

Generated raster tiles avoid network variability and preserve the 256-pixel
tile rendering/decode pipeline. These runs do **not** validate production vector
styles, network latency, low-end hardware, real GPS following, or long-session
memory stability. A synthetic benchmark is evidence for its recorded workload,
not a universal FPS guarantee.

`test/performance/map_stress_test.dart` separately guards culling of 10,000
markers and rendering/selection of a 50,000-point route, replacement-heavy
moving-marker fleets, high-frequency location fixes, cluster-result reuse
across pans and fractional-zoom intervals within one integer zoom step,
per-frame live-route updates staying culled/selectable/bounded, and correct
selection across several simultaneously visible polygons and routes.
Widget-test clocks and debug builds are not used to claim release FPS.
Flutter recommends profile-mode runs on physical hardware:
https://docs.flutter.dev/perf/ui-performance

For production vector stage attribution, see
[vector processing measurements](vector-processing.md).
Enable `--dart-define=fosm.traceVector=true` for timeline captures; disable it
for final frame-rate comparisons. For marker-pipeline stage attribution, run
the benchmark with `--dart-define=fosm.traceMarkers=true`: the spans
`fosm.markers.query` (viewport index query), `fosm.markers.project`
(cached world → screen projection), `fosm.markers.cluster` (clustering
engine) and `fosm.markers.build` (whole marker layer) separate collection
scanning and projection from widget build; layout and hit testing remain in
Flutter's surrounding frame spans. Disable it for final frame-rate
comparisons. For route/area geometry, run with
`--dart-define=fosm.traceGeometry=true`: the spans `fosm.geometry.project`
(vertex projection from cached world coordinates), `fosm.geometry.path`
(path construction incl. solid-path culling and dash/dot extraction),
`fosm.geometry.paint` (canvas draw calls) and `fosm.geometry.hit`
(selection) attribute the geometry pipeline per stage. Disable it for
final frame-rate comparisons.

For long-session retained-memory attribution, run with
`--dart-define=fosm.traceMemory=true`: each attached `MapView` logs one
`FOSM memory:` line per second attributing rendered-image bytes (protected
vs evictable), the compressed byte cache, parsed vector tiles, raster
source images, prepared labels, geometry rings and outstanding loads.
Pair these lines with OS memory reporting (iOS footprint, Android
`dumpsys meminfo`) during repeated pan/zoom/style-switch workloads and
across background/resume: the attribution lines explain *which* retained
bucket grows, the OS numbers include the Dart heap, GPU surfaces and
allocator peaks. Attribution is also available programmatically via
`MapController.memoryAttribution`, and strict-viewport coverage (covered vs
sharp cells) via `MapController.tileCoverage` — the benchmark's load
scenarios sample it every frame. System memory warnings are handled
deliberately: rebuildable caches (compressed bytes, unused rendered
imagery, parsed tiles, raster source images, prepared labels, geometry
rings) are released while the visible grid, pinned fallback imagery and
camera state survive.

For browser renderer variants (CanvasKit vs skwasm), the bitwise-packing
audit checklist, production vector-mode browser profiling and the
desktop resize/high-DPI/large-viewport workloads, see
[web and desktop measurements](web-desktop.md).
