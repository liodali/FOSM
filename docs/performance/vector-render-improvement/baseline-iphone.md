# Plan 01 — vector-render baseline, iPhone

> Historical capture: the 2026-10-30 review corrections change native fetch
> tracing, timeline event deduplication and the strict warm-parsed workload.
> `vector_warm_parsed_return` below is a retained-image return pan, not a
> warm-parsed/cold-images baseline. New captures are required for the corrected
> `vector_warm_parsed_static` scenario and exact first/95%-sharp timings.
> Do not use this report to mark those corrected acceptance checks complete.

First measured baseline for the vector pipeline under the harness in this
directory. Captured 2026-10-30 from `example/tool/capture_vector_baseline.sh`
(device `00008101-000518663C78001E`, wireless). Raw logs and parsed reports
live in [raw/](raw/); methodology and metric definitions in
[README.md](README.md).

## Setup

| | |
|---|---|
| Device | Physical iPhone, iOS 27.2, 60 Hz, 1125×2436 @ DPR 3 |
| Code | `41833b8` + span-log define fix and `--start-paused` isolate resume (`3792d0a`, `b55ca15`) — the fixes the smoke run found |
| Renderer | Impeller (Metal), profile mode |
| Payload | `mvt-synth/1` denseCity, seed 20261027, deterministic; served over LAN HTTP (`192.168.178.48:8787`), style source maxzoom 14 (z15+ over-zooms) |
| Arms | clean ×3 (no defines), spans ×2 (`fosm.vectorSpans`), trace ×1 (spans + `fosm.traceVector`, drained VM timeline) |
| Windows | 10 s sample, settle ≤ 25 s, per-frame coverage/labels/failure sampling |

Metric definitions (measurement start, empty-grid exclusion, cell-count vs
pixel-area coverage, newly-exposed cells, labels-ready) follow the README;
all numbers below are medians of 3 reps unless stated.

## Headline table (clean arm)

`allSharp`/`allCovered`/`labels` = time in ms to full sharp coverage, full
covered coverage, and viewport label readiness (null = not reached inside
the window). `>bud` = frames over the 60 Hz display budget (median).

| Scenario | allSharp | allCovered | labels | uiP50 | uiP95 | uiP99 | rP99 | >bud |
|---|---|---|---|---|---|---|---|---|
| raster_control_static | 1253 | 1253 | – | 2.0 | 3.3 | 3.6 | 5.8 | 0 |
| raster_control_fling | 1215 | 1215 | – | 1.3 | 2.5 | 2.9 | 4.0 | 0 |
| vector_cold_static | 398 | 398 | 398 | 0.8 | 1.7 | 10.1 | 9.2 | 0 |
| vector_cold_fling | 966 | 966 | 966 | 4.3 | 5.4 | 6.0 | 3.3 | 0 |
| vector_cold_return | 331 | 331 | 331 | 4.4 | 5.5 | 6.1 | 1.6 | 0 |
| vector_cold_pinch | 3888 | 3888 | 3888 | 1.0 | 5.2 | 5.7 | 7.5 | 0 |
| vector_cold_overzoom | — (sharpEnd 0.5) | — | — | 0.3 | 0.4 | 3.3 | 5.6 | 0 |
| vector_warm_static | 10 | 10 | 10 | 8.8 | 8.8 | 8.8 | 1.0 | 0 |
| vector_warm_fling | 23 | 23 | 23 | 4.8 | 5.6 | 6.3 | 0.9 | 0 |
| vector_warm_bytes_static | 4290 | 4290 | 4290 | 0.6 | 0.8 | 1.6 | 3.5 | 0 |
| vector_warm_parsed_return | 15 | 15 | 15 | 4.8 | 5.5 | 5.7 | 0.7 | 0 |
| vector_style_switch | 9 * | 9 * | 9 * | 0.7 | 1.6 | 8.1 | 5.7 | 0 |

\* `vector_style_switch` starts warm, so "first all-sharp" is pre-switch.
The switch fires at window half; the coverage dip recovers to full sharp in
**178–641 ms** across reps (series-derived), with a full coverage blank at
the swap. That recovery time is the style-reload metric.

`vector_warm_parsed_return` is a **return pan to recently visited area**:
the measured 14–16 ms to full sharp is served by retained imagery and
zoom-fallback pins, not by re-rendering — during the window the pipeline
recorded zero fetches/decodes/records while 8 newly exposed cells turned
sharp. Investigating why exposed this retention behavior: `flushUnused`
cancels the retention expiry timer, and entries whose grid protection
lifts afterwards stay served until some other `trim()` runs (see Found
issues).

Rep spreads: `vector_cold_static` [232, 563, n/r], `vector_cold_fling`
[573, 966, 9216], `vector_cold_pinch` [n/r, 4658, 3119],
`raster_control_*` [98…3538] — the raster control and motion scenarios are
the noisiest; static vector loads are tight.

## Attribution (spans arms, per-attempt stage sums)

Per-scenario sums of per-attempt stage totals (async elapsed — never CPU
except the sync slices noted). Two reps; r1/r2 shown where they differ.

| Scenario | fetch | queueWait | parseWait | record | toImage | imageWait | labels.build | labels.layout |
|---|---|---|---|---|---|---|---|---|
| vector_cold_static | 311 / 484 | 274 / 127 | 64 / 52 | 156 / 98 | 17 / 19 | 137 / 122 | 0.1 | 0.0 |
| vector_warm_bytes_static | 0 (disk) | 609 / 376 | 297 / 120 | 263 / 163 | 17 / 16 | 118 | 0.2 | 0.1 |
| vector_cold_overzoom | 185 / 76 | 16589 / 14555 | 13622* / 59 | 19305 / 18891 | 53 / 61 | 142 / 130 | 1332 / 1427 | 4008 / 3994 |
| vector_cold_pinch (r2) | 41435† | 461 | 332 | 3985 | 48 | 345 | 0.2 | 0.1 |

\* one rep's `parseWait` total is two orders larger than the other's —
shared-parse waits behind the decode gate are the suspected term; treat
as variance until the presentation-queue instrumentation (below) closes
the gap. † elapsed sums of overlapping fetches across 126 touched tiles.

Sync CPU slices inside recording (`recordChunk.*`) total only **6–9 ms**
per z10 scenario and 447–610 ms for overzoom; `style` 2–29 ms, `geometry`
0.3–17 ms, `dash` 0–480 ms (overzoom), `labels.build/layout` ≈ 0.2 ms at
z10 but **1.3 s + 4.0 s at overzoom**.

## What the numbers say (plan-01 question)

- **Normal zoom (z10) cold loads are not CPU-bound.** The critical path is
  network fetch → decode-gate queueing → cooperative recording/scheduler
  waits → image lane; sync recording CPU is single-digit milliseconds and
  parse is ~6–8 ms/tile. Nothing here justifies geometry/style rewrites
  (plans 02–04) for normal zoom.
- **Overzoom (z16 over z14) is the heavy outlier**: recording elapsed of
  multiple seconds per tile, a ~15 s decode-gate backlog inside a 10 s
  window (only 50 % of cells sharp at window end; pixel-area 73 %, stably
  identical across reps), `dash` walking 345–480 ms, and 5.4 s of label
  work. The only scenarios with real CPU cost and the largest RSS delta
  (+38 MB). This is the first measured candidate target — but per the
  payload caveat, any optimization must be re-validated against a frozen
  production sample before generalizing.
- **Style reload is cheap**: 178–641 ms dip-to-full-sharp with warm disk
  bytes.
- **Return pans to recently visited areas are nearly free**: 14–18 ms to
  full sharp, served by retained imagery + fallback pins (zero decodes
  recorded — see Found issues). A strict re-render-from-warm-parsed
  measurement needs a retention-bypass hook and is deferred.
- **Warm-disk loads (fresh runtime) are unexpectedly slow**: 2.8–4.4 s to
  sharp while the traced stages sum to ≈0.8–1.3 s. The unaccounted 2–3 s
  sits between traced stages and visible publication — the presentation
  queue and adjacent-zoom disk preloads are not instrumented yet. Next
  instrumentation step: opt-in presentation/publication queue spans so the
  gap closes; until then no claim about what the 2–3 s is.
- **No dropped frames anywhere**: median 0 frames over the display budget
  in every scenario; motion uiP95 ≤ 5.6 ms. Slow coverage is slow
  *coverage*, not missed frames — the two are separated as the plan
  requires.
- **Labels**: viewport label readiness coincides with all-sharp at z10
  (label payload is modest); only overzoom shows label cost worth
  attacking.
- **Zero unreachable coverage**: `maxFailedTiles` = 0 in all 36 scenarios.

## Found issues (reported back from the harness)

1. **Retention laziness after a cache flush**: `RenderedTileCache.
   flushUnused` cancels the expiry timer; entries whose grid protection
   lifts later (camera moves away) stay served until an unrelated
   `trim()` runs. Harmless for correctness (imagery is rebuildable) but
   it holds RSS for recently visited areas and it makes a strict
   warm-parsed/cold-images measurement impossible without a
   retention-bypass hook. Fix is one re-arm of the timer in
   `flushUnused`; verify against plan 06 (idle preparation / cache
   reuse) before changing.
2. **Overzoom parseWait variance**: one overzoom rep recorded 13.6 s of
   `parseWait` totals against 59 ms in the other — shared-parse waits
   behind the decode gate are the suspected term. Worth re-checking when
   presentation-queue spans exist.
3. The VM timeline ring is far smaller than a 12-scenario run; the trace
   arm now disables chunk-level spans (`fosm.vectorTraceChunks=false`,
   ~34× volume reduction) and polls without clearing — fine-grained CPU
   attribution comes from profiler samples in the DevTools capture.

## Raster control

Raster cold loads reached sharp in 98–3538 ms (high variance, wireless
LAN + PNG decode) versus 232–563 ms for vector static. Both pipelines are
transport-bound on the local server; no production raster-vs-vector
conclusion is possible from this round — the control exists to keep
provider cost from being attributed to rendering.

## Frame pacing and memory

Rendered-image peaks 2–18 MB, parsed-tile peaks ≤ 29 tiles, prepared
labels ≤ 2628 (overzoom only), RSS delta −20 MB to +38 MB across
scenarios (overzoom and cold static the growers). No memory regression
signal; overzoom RSS is the one to watch when attacking its record cost.

## Timeline (trace arm)

`vector-trace-r1` exposed a harness limitation: the VM timeline is a small
ring and evicted early scenarios (global span 14 % of the window), which
the gate correctly rejected. Two capture-tool iterations later, the trace
arm polls `getVMTimeline` every 5 s **without clearing** and merges
deduplicated snapshots (the live Timeline stream delivers nothing under
DDS; clearing between polls loses single-instant markers to a snapshot
race), and the trace arm disables chunk-level spans
(`fosm.vectorTraceChunks=false`, ~34× volume reduction — fine-grained CPU
comes from profiler samples in the DevTools capture).

Final trace capture (`vector-trace-r5`): 100 % window coverage, **250
worker `parse` events**, and per-scenario gate validation **12/12 valid**
with in-window critical-path counts per scenario — cold_static 16 parses,
cold_fling 40, cold_return 40, cold_pinch 60 (160 records, 46 toImage),
cold_overzoom 6 parses (over-zoom source sharing visible in the saved
worker timeline), style_switch 16 (the reload), warm_bytes 16;
warm/raster scenarios zero as expected. The parse-vs-drawing conclusion
above rests on this saved worker timeline plus the spans arms.

## Known gaps / follow-ups

1. **Presentation/publication instrumentation** — the warm-disk 2–3 s
   unaccounted gap needs opt-in presentation-queue spans (plan 01
   explicitly allows adding them). Highest-priority harness follow-up.
2. **Retention laziness** (Found issues #1): decide whether to re-arm the
   expiry timer in `flushUnused` and re-measure; only then can a strict
   re-render-from-parsed cost be captured.
3. **Browser capture** (plan requirement) still pending — run the spans
   arm on Chrome separately; native conclusions do not transfer.
4. **Production-sample validation** before generalizing any optimization
   chosen from this baseline (payload caveat in README).
5. Thermal state was not recorded beyond "device not visibly throttled";
   future captures should note battery/thermal.
6. Stage files under `raw/stages/` embed scenario names from the extractor
   (fixed mid-round); the four oldest files map by scenario order.
7. `vector_cold_overzoom` never completes inside a 10 s window — decide
   whether overzoom gets a longer window or is reported as partial-by-
   design (both defensible; currently reported as partial with stable
   end state).

## Reproduction

```sh
cd example
zsh tool/capture_vector_baseline.sh DEVICE_ID \
  ../docs/performance/vector-render-improvement/raw 192.168.178.48 3 2 1
dart run tool/parse_benchmark_log.dart \
  ../docs/performance/vector-render-improvement/raw/vector-clean-*.log \
  > ../docs/performance/vector-render-improvement/raw/vector-clean-reps.json
dart run tool/extract_vector_stages.dart \
  ../docs/performance/vector-render-improvement/raw \
  ../docs/performance/vector-render-improvement/raw/stages
```

Multi-MB timeline JSONs are kept out of git (see `raw/.gitignore`); the
gate block inside them records the acceptance numbers. Parsed
per-attempt stage reports (`raw/stages/`) are also local — regenerate
them from the raw logs with `tool/extract_vector_stages.dart` (the
command in this document).
