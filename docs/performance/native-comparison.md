# Matched MapCore and Flutter workload

Plan 12 now has two independently runnable vector camera drivers. They read
the same [workload](../../example/benchmark/native_comparison.json): style URL,
start camera, closed waypoint trajectories, ten-second warmup and twelve-second
sample windows. Latitude/longitude interpolate by wall time; integer zoom
holds until each waypoint. Both drivers disable engine camera animation.
The scenarios are `vector_pan` and `vector_zoom_steps`, without app markers,
routes, controls or simulated GPS.

This is comparison infrastructure. No native/Flutter speed ratio has been
measured. A standalone native app also excludes Flutter platform-view
composition and bridge costs.

## Validate and build

From the repository root:

```sh
python3 example/tool/verify_native_trajectory.py --dart dart
python3 example/tool/prepare_native_comparison.py \
  --package /Users/dalihamza/Desktop/SwiftApps/OSMFlutterFramework \
  --output /tmp/fosm-native-comparison
```

The first command compiles the actual Swift workload model, runs both actual
models and compares 22 poses, including waypoint edges and period wraparound.
The second generates an isolated Xcode app project and source-identity
resource. It reads the Swift wrapper; it never changes that package or the
FOSM iOS Runner. The resource records wrapper revision, dirty status, a hash
of framework sources, the expected MapCore pin and the workload SHA-256.

Use the generated project to build the companion:

```sh
xcodebuild -project /tmp/fosm-native-comparison/MapCoreComparison.xcodeproj \
  -scheme MapCoreComparison -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/fosm-native-comparison/Build \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
```

This validates an unsigned device build. To run on the physical phone, open
the generated project in Xcode, select its signing team and device, choose
Release in the Run scheme and launch. Use Instruments on that app for actual
render/presentation and memory measurements. Copy both the resolved package
lock from the generated workspace and `source_identity.json` alongside each
capture. Confirm the built lock matches `expectedMapCorePin`; abort a pair
when it differs. Regenerate the project after changing sources or workload.

Run the Flutter driver from `example` on the same physical phone:

```sh
flutter run --profile -d DEVICE_ID \
  -t lib/benchmark/native_comparison.dart \
  --dart-define=BENCHMARK_REVISION=RECORDED_SOURCE_REVISION
```

Preserve a source snapshot, including untracked benchmark files, for these
currently uncommitted changes. A HEAD revision alone cannot identify them.
Keep the existing Flutter and native builds sequential.

## Validation of this implementation

On 2026-10-25, both the standalone unsigned iOS Release app (Xcode 26.5)
and the Flutter unsigned iOS profile entrypoint built successfully. The native
project’s resolved MapCore revision matched its recorded `spm.2` pin. All 39
example tests passed, targeted Dart analysis was clean and 22 Swift/Dart poses
matched. No physical-device native/Flutter performance comparison was captured.

## Reading the output

Both drivers emit `FOSM_NATIVE_COMPARE_META`, `START`, `RESULT` and `DONE`.
Native also emits `VIEWPORT`. Every capture must reach `DONE` for both
scenarios; discard interrupted or backgrounded runs.

| Output | Interpretation |
| --- | --- |
| Flutter `uiP95Ms`/`uiP99Ms`, `rasterP95Ms`/`rasterP99Ms` | Flutter frame build and raster durations, including native tile preparation as attributed by the engine. They are not input-to-present latency. |
| Native `cameraCommandP95Ms`/`cameraCommandP99Ms` | Synchronous wrapper camera-call duration. Excludes deferred C++ preparation, GPU execution and presentation. |
| Native `driverIntervalP95Ms`/`driverIntervalP99Ms` | Main-thread display-link driver cadence. A tick does not establish that MapCore presented a frame. |
| `presentationMeasured: false` | These console summaries cannot establish delivered FPS or a cross-engine speed ratio. Use the same Instruments presentation measurements for both apps. |
| Flutter `sharpFractionEnd` | Diagnostic current-zoom image availability; native has no equivalent public coverage probe yet. It is not a style/label readiness check. |
| Flutter `retainedBytesEnd` | FOSM's partial retained-memory estimate, not process RSS or native GPU memory. Compare memory in the same OS instrument. |

Do not divide Flutter build/raster durations by native camera-call durations.
Use native Metal/System Trace and the corresponding Flutter trace to attribute
backpressure, graphics setup and input/presentation stalls separately.

## Pair acceptance gates

1. Match the physical viewport, DPR, actual display cadence, device orientation
   and OS. Record thermal state; interleave at least three repeats per engine.
2. Compare `BOUNDS` at each scenario's initial pose. Flutter emits expected
   Web Mercator bounds; native emits the wrapper's actual bounds. Equal zoom
   numbers do not prove equal geographic scale. The wrapper exposes integer
   zoom only: a scale mismatch blocks a matched result until calibrated. This
   pass does not claim fractional-pinch parity.
3. Use screenshots to verify visible roads, fills, labels, sprites and clipping.
   FOSM's text layout and the wrapper's SDF fonts differ. Unsupported style
   layers or missing glyphs make the workloads unequal and block a speed claim.
4. The default Liberty URL is a production smoke workload, not a frozen fixture.
   For acceptance, set the shared JSON to one pinned style/TileJSON/tile/sprite
   fixture served to both apps; preserve response bytes and request logs. Also
   document request concurrency and caching rather than claiming equal loading
   merely because URLs match.
5. These are warmed process scenarios with uncontrolled persistent caches.
   A fixed ten-second warmup does not prove readiness. Confirm both scenes
   finish loading before sampling. Controlled cold caches, matched coverage,
   injected network faults and style switching remain separate pending work.
6. Use common Instruments metrics for presented frames and peak/steady memory.
   Actual gesture-to-present latency needs gesture instrumentation. The shared
   programmatic camera path only tests camera/render work.

## Backend decision

Keep the current Flutter backend until repeated equivalent captures show a
material gap. A native-platform-view prototype then needs explicit parity for
arbitrary widget markers, clustering, routes/polygons and hit testing, labels,
accessibility, following, lifecycle, composition, event batching and the
Android/web/desktop fallback. The standalone app is not that prototype.
