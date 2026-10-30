# Plan 01 — vector-render baseline, iPhone

Revised measured baseline for the vector pipeline under the harness in
this directory. Captured 2026-10-30 (round 2, after the chunked-payload
protocol landed) from `example/tool/capture_vector_baseline.sh` (device
`00008101-000518663C78001E`, wireless). Raw logs and parsed reports live
in [raw/](raw/) (gitignored; local only); methodology and metric
definitions in [README.md](README.md); the separate browser capture is
[baseline-browser.md](baseline-browser.md).

## Setup

| | |
|---|---|
| Device | Physical iPhone, iOS 27.2, 60 Hz, 1125×2436 @ DPR 3 |
| Code | round-2 harness (chunked payloads; `vector_warm_parsed_static` strict scenario; first-sharp/95%-crossing fields) |
| Renderer | Impeller (Metal), profile mode |
| Payload | `mvt-synth/1` denseCity, seed 20261027, deterministic; served over LAN HTTP (`192.168.178.48:8787`), style source maxzoom 14 (z15+ over-zooms) |
| Arms | clean ×3, spans ×2, trace ×1 (chunk-level spans disabled for the trace arm) — the trace arm's saved worker timeline passed its gate **12/12 scenarios valid**, 100 % window coverage, 236 worker `parse` events (`raw/vector-trace-r1-timeline.json`, transient file — the gate numbers are quoted here and in the progress log) |
| Windows | 10 s sample, settle ≤ 25 s, per-frame coverage/labels/failure sampling |

All numbers below are medians of 3 reps unless noted. The metric
definitions (measurement start at the armed window's first frame,
empty-grid exclusion, cell-count vs pixel-area coverage, newly-exposed
cells, labels-ready) follow the plan and are reproduced in
[README.md](README.md).

## Headline table (clean arm)

`allSharp`/`95%sharp`/`labels` = time in ms to full sharp coverage,
the 95 %-sharp crossing, and viewport label readiness.

| Scenario | allSharp | 95% sharp | labels | uiP50 | uiP95 | uiP99 | rP99 | >budget |
|---|---|---|---|---|---|---|---|---|
| raster_control_static | 98 | 98 | – | 1.1 | 1.8 | 1.9 | 2.8 | 0 |
| raster_control_fling | 282 | 282 | – | 1.2 | 2.0 | 2.7 | 1.2 | 0 |
| vector_cold_static | 279 | 279 | 279 | 0.9 | 1.7 | 13.1 | 9.5 | 0 |
| vector_cold_fling | 245 | 245 | 245–260 | 4.4 | 5.5 | 6.0 | 1.5 | 0 |
| vector_cold_return | 347 | 347 | 347 | 4.4 | 5.5 | 6.1 | 1.8 | 0 |
| vector_cold_pinch | 730 | 730 | 730 | 3.5 | 5.5 | 6.3 | 9.8 | 0 |
| vector_cold_overzoom | — (sharpEnd 0.50) | — | – | 0.3 | 0.4 | 3.3 | 5.6 | 0 |
| vector_warm_static | 9 | 9 | 9 | 8.5 | 8.5 | 8.5 | 1.0 | 0 |
| vector_warm_fling | 10 | 10 | 10 | 4.6 | 5.4 | 6.1 | 0.9 | 0 |
| vector_warm_bytes_static | 198 | 198 | 199 | 0.9 | 1.3 | 2.9 | 3.3 | 0 |
| vector_warm_parsed_static | 319 | 319 | 335 | 2.8 | 4.6 | 8.7 | 8.0 | 0 |
| vector_style_switch | 9 * | 9 * | 9 * | 0.9 | 6.6 | 8.5 | 5.0 | 0 |

\* `vector_style_switch` starts warm; "first all-sharp" is pre-switch.
The switch fires at window half; the coverage dip recovers to full sharp
in **175–227 ms** across reps (dip-and-recover from the coverage
series). That recovery time is the style-reload metric.

Rep spreads (allSharp, ms): `cold_static` [244, 279, 294];
`cold_fling` [244, 245, 284]; `cold_return` [346, 347, 347];
`cold_pinch` [699, 730, 730]; `warm_bytes` [185, 198, 199];
`warm_parsed` [303, 319, 320]; raster control [98–465]. The round-2
dataset is dramatically tighter than round 1 because the old scenario
arming let a finished-but-not-settled state re-render for the whole
window; that artifact is what made the previous round's warm-disk loads
(2.8–4.4 s) look slow — **the round-1 "unaccounted 2–3 s presentation
gap" finding is retired** (the timeline/gate evidence in this round
matches the traced stages; see [Found issues](#found-issues)).

## Attribution (spans arms, per-attempt stage sums)

Stage window sums per attempt overlap by design (they are critical paths,
not CPU). Two reps quoted where they differ.

| Scenario | fetch | queueWait | parseWait | record | recordChunk (sync) | toImage | imageWait | labels.build | labels.layout |
|---|---|---|---|---|---|---|---|---|---|
| vector_cold_static | 311 / 484 | 274 / 127 | 64 / 52 | 156 / 98 | 6.2 / 6.4 | 17 / 19 | 137 / 122 | 0.1 | 0.0 |
| vector_warm_bytes_static | 0 (disk) | 609 / 376 | 297 / 120 | 263 / 163 | 7.1 / 8.6 | 17 | 118 | 0.2 | 0.1 |
| vector_cold_overzoom | 185 / 76 | 16589 / 14555 | 13622 / 59 | 19305 / 18891 | 447 / 610 | 53 / 61 | 142 / 130 | 1332 / 1427 | 4008 / 3994 |
| vector_warm_parsed_static | 0 (disk+parsed) | 574 / 625 | **0 / 0** | 568 / 622 | 0 | 32 / 33 | 176 / 171 | 0.0 / 0.0 | 0.4 / 0.4 |

*The strict warm-parsed scenario measures a rebuild from parsed data (the
table above is the per-attempt stage sums for its two spans reps); its
visible metric — 303–320 ms to full sharp across reps with a
−1.2..−1.9 MB RSS delta — is the honest round-trip through
record→toImage from warm parsed data.*

## What the numbers say (plan-01 question)

- **Normal zoom (z10) cold loads are not CPU-bound** — the critical path
  is network fetch → decode-gate queueing → cooperative
  recording/scheduler waits → image lane. Sync recording CPU is single
  digits of ms and parse is ~6–8 ms/tile; frames never miss budget.
  Nothing here justifies geometry/style rewrites (plans 02–04) for
  normal zoom.
- **Overzoom (z16 over z14) is the heavy outlier** — the only scenario
  with real CPU cost: ~15 s decode-gate backlog, multi-second per-tile
  record elapsed, `dash` walking 345–480 ms, ~5.4 s of label work, and
  the largest RSS delta (+38 MB). Only 50 % of cells (73 % of pixel
  area) are sharp at window end, stable across reps. This is the first
  measured target candidate — re-validated against a frozen production
  tile sample before any optimization is generalized.
- **Strict warm-parsed re-render is ~320 ms** (303–320 ms across reps;
  −1.2..−1.9 MB RSS delta): parsed data and prepared state survive the
  pin-releasing `dropRebuildableCaches(includeVisibleImages:)` reload and
  the honest round-trip through record→toImage costs ~8× a warm-image
  reload (~9 ms) but ~1.1× a warm-bytes decode (~198 ms).
- **Style reload is cheap**: 175–227 ms dip-to-full-sharp with warm disk
  bytes.
- **Return pans to recently visited areas are nearly free** (the
  `warm_parsed_return` round-1 measurements measured retention):
  with retention and fallback pins serving the window, ~14–18 ms to all
  sharp with zero decodes recorded — the camera is served from cache.
- **No dropped frames anywhere**: median 0 frames over the display budget
  in every native scenario; motion `uiP95` ≤ 5.6 ms.
- **Labels**: viewport label readiness coincides with all-sharp at z10
  (label payload modest); only overzoom shows label cost worth attacking.
- **Zero unreachable coverage**: `maxFailedTiles` = 0 in all scenario runs.

## Found issues (reported back from the harness)

1. **Retention laziness after a cache flush**: `RenderedTileCache.
   flushUnused` cancels the expiry timer; entries whose grid protection
   lifts later (camera moves away) stay served until another `trim()`
   runs. Harmless for correctness (imagery rebuildable) but holds RSS
   for recently visited areas and made the *strict* warm-parsed/
   cold-images measurement impossible without a pin-bypass hook — the
   shipped hook (`includeVisibleImages`) now closes that measurement.
2. **Overzoom parseWait variance**: one overzoom rep recorded 13.6 s of
   `parseWait` totals against 59 ms in the other — shared-parse waits
   behind the decode gate are the suspected term (needs the
   presentation-queue instrumentation to close out).
3. The VM timeline ring is far smaller than a 12-scenario run; the trace
   arm polls getVMTimeline without clearing (merged snapshots) and
   disables chunk-level sync spans (`fosm.vectorTraceChunks=false`, ~34×
   volume cut). Chunk-level spans flood the ring on long runs, so the
   default-on define stays available per capture round.
4. **Warm-disk "2–3 s unaccounted presentation gap" (retired finding
   from round 1)**: an artifact of the old scenario's post-arming
   re-render (a finished-but-not-settled state kept rendering for the
   whole window), traced in round-2's frame data (perf p95s 0.8 ms over
   251–264 frames). The corrected arming measures warm-disk loads at
   185–199 ms full sharp.

## Browser addendum

[baseline-browser.md](baseline-browser.md) — same harness, Chrome,
dart2js profile, separate report file apart (native parsing conclusions
do not transfer). Headline: the web build decodes cooperatively on the
main isolate; its decode-gate backlog spans 8–27 s and frame budgets
miss 10–78 frames per cold/motion scenario. Native conclusions above are
unaffected.

## Known gaps / follow-ups

1. **Thermal note** — device thermal state was not recorded this round
   (battery level/thermal state visible only via device UI, not the
   harness). The demographic can be noted at capture time going forward.
2. **Production-sample validation** of any optimization chosen from this
   baseline before generalizing (payload caveat in README).
3. The stage-file extractor embeds scenario names (fixed mid-round).
4. `vector_cold_overzoom` never completes inside a 10 s window on any
   platform — reported as partial-by-design with stable end states.

## Reproduction

```sh
cd example
# device (clean×3 spans×2 trace×1):
zsh tool/capture_vector_baseline.sh DEVICE_ID \
  ../docs/performance/vector-render-improvement/raw 192.168.178.48 3 2 1
# browser:
zsh tool/capture_vector_baseline_web.sh \
  ../docs/performance/vector-render-improvement/raw/browser \
  http://192.168.178.48:8787 2 2 8787
dart run tool/parse_benchmark_log.dart \
  ../docs/performance/vector-render-improvement/raw/vector-clean-*.log \
  > ../docs/performance/vector-render-improvement/raw/vector-clean-reps.json
dart run tool/extract_vector_stages.dart \
  ../docs/performance/vector-render-improvement/raw \
  ../docs/performance/vector-render-improvement/raw/stages
```

Multi-MB timeline JSONs and parsed per-attempt stage reports stay out of
git (see `raw/.gitignore`); the gate numbers inside them are quoted
above.
