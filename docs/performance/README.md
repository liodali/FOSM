# Map performance validation

Measured comparison: [physical iPhone profile results](results-ios.md).

The frame-pacing change introduces a shared 2 ms cooperative allowance for
vector recording and label preparation, plus bounded raster/vector image
submissions. Scheduler and pipeline tests verify pacing, priority, cancellation,
coverage progress, and unchanged pixels. The saved iPhone reports predate this
change and are not measurements of its impact. A follow-up comparison should
include cold production vector loads while pinching/panning, time to visible and
sharp coverage, frame p95/p99, and memory; the warm offline benchmark below is
useful for camera regression checks but cannot establish cold-vector gains.

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
