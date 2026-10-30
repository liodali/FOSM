# Plan 01 — vector-render baseline, browser (Chrome) addendum

Separate capture per the plan's requirement: native parsing conclusions do
not transfer to web, so the browser run is an *addendum* to
[baseline-iphone.md](baseline-iphone.md) — same harness, same payload
identity (`mvt-synth/1` denseCity, seed 20261027, LAN HTTP), same camera
paths and cache states. Captured 2026-10-30 with
`example/tool/capture_vector_baseline_web.sh`.

## Setup and why this is a separate report

| | |
|---|---|
| Host | macOS desktop, Google Chrome 156, 60 Hz, DPR **1** (native device runs at DPR 3) |
| Renderer | Flutter web, dart2js **profile** build, ui renderer |
| Decoder | MVT decodes **cooperatively on the main isolate** (`lib/src/isolate/mvt_isolate.dart` — no worker isolate on web), so there is no worker timeline to save and no trace arm; the spans arm attributes decode from the in-process span log |
| Capture transport | The app POSTs every payload line to the payload server's `/log` marker sink (`BENCHMARK_MARKER_URL`); flutter_tools' Chrome has no debug extension (it starts with `--disable-extensions`) and cannot relay app prints, so run logs are sink-written, one file per label |
| Arms | clean ×2, spans ×2 (12 result lines each, all scenarios settled) |
| Debug builds | `build/web-clean` and `build/web-spans` (profile, `--dart-define=BENCHMARK_ATTACH_DELAY_MS=10000` baked so the capture attaches before the first marker) |

**Cross-platform caveat** — the DPR difference (1 vs 3) changes viewport
tile density and hence tile counts per scenario; do **not** read the
tables below as native-vs-web speed ratios, only as the web build's own
behavior per the identical workload.

## Headline table (clean arm, median of 2 reps)

| Scenario | allSharp | 95% sharp | labels | uiP50 | uiP95 | rP95 | >budget |
|---|---|---|---|---|---|---|---|
| raster_control_static | 382 | 373 | – | 3 | 6 | 15 | 1 |
| raster_control_fling | 1140 | 1012 | – | 2 | 4 | 5 | 5 |
| vector_cold_static | 6748 | 6700 | 6764 | 0 | 1 | 12 | 10 |
| vector_cold_fling | 2480 | 1615 | 2497 | 2 | 4 | 13 | 22 |
| vector_cold_return | 7845 | 7354 | 7862 | 1 | 3 | 11 | 6 |
| vector_cold_pinch | 5230 | 5164 | – | 1 | 3 | 20 | 78 |
| vector_cold_overzoom | — | — | – | 0 | 1 | 15 | 37 |
| vector_warm_static | 5 | 5 | 5 | 2 | 3 | 1 | 0 |
| vector_warm_fling | 6 | 6 | 6 | 2 | 3 | 1 | 0 |
| vector_warm_bytes_static | 1758 | 1710 | 1774 | 0 | 1 | 12 | 3 |
| vector_warm_parsed_static | – (sharpEnd 0.17/0.33) | – | – | 0 | 1 | 11 | 11 |
| vector_style_switch | dip-recovery **≈4.8 s**, never fully sharp | – | – | 0 | 1 | 11 | 8 |

`>budget` = frames whose build+raster exceeded the 60 Hz deadline
(median of reps). The native device had **0 in every scenario**; the web
build misses frames at scale in every vector cold/motion scenario — the
one headline contrast between the platforms that IS apples-to-apples
(frame pacing at the actual refresh rate).

## Attribution (spans arm, per-attempt stage sums)

Stage window sums overlap (per-attempt totals over concurrent tiles) —
they are critical-path context, not CPU. Medians across 2 reps where
both contain the scenario (`vector-web-spans-r1/r2`, `browser/stages/`).

| Scenario | fetch | queueWait | parseWait | record | recordChunk (sync) | toImage | imageWait | labels.build | labels.layout |
|---|---|---|---|---|---|---|---|---|---|
| vector_cold_static | 729 | 27228 | 1028 | 8255 | 77 | 224 | 292 | 27 | 0.6 |
| vector_cold_overzoom | 158 | 8306 | 98 | 8126 | 329 | 59 | 65 | 1354 | 0.0 |
| vector_warm_bytes_static | 0 (disk) | 20872 | 645 | 7165 | 47 | 153 | 216 | 0.6 | 0.1 |
| vector_warm_parsed_static | 0 | 20604 | **0** | 9903 | 32 | 91 | 127 | 0.0 | 0.2 |

Reading the table:

- **The decode gate dominates**: `queueWait` sums of 8–27 s mean decoded
  work queues far behind presentation demand; elapsed `record` sums are
  likewise multiple seconds per scenario (8–10 s), against 0.9 s of that
  on the native device. Sync `recordChunk` slices stay tens of ms — the
  cost is cooperative-yield latency layered on the single isolate, not
  per-chunk CPU.
- **`vector_warm_parsed_static` shows parseWait = 0 with record work
  unchanged** — the strict warm-parsed state holds on web too (parsed
  cache survives the pin-releasing reload); the scenario never reaches
  all-sharp inside the 10 s window on web (sharpEnd 0.17/0.33 across
  reps), which is the honest statement of web-scale re-render cost.
- `warm_bytes_static` shows the same all-disk fast path as native
  (fetch sums 0), but the stage sums further out (queue+record) still
  explain the visible ~1.8 s on web vs ~198 ms on device.
- **Style switch never recovers to full sharp inside the window**
  (dip to 0.04, ~4.8–4.9 s below-period) — the web reload is heavier than
  the retention/fast-path behaviors of the switch.

## What this addendum does NOT claim

- No native-vs-web speed ratio (DPR/tile-density and code-generation
  differences invalidate direct comparison).
- No raster-vs-vector conclusion from the browser control (the raster
  control is transport-bound on the same loopback).
- The web build is **not** a tier-1 target of the optimization plans:
  plans 02–06 are evidence-driven against the *device* critical path.
  This report exists so web regressions from any chosen optimization are
  visible early (a device number can be kept only if Chrome also
  regresses/holds).

## Reproduction

```sh
cd example
zsh tool/capture_vector_baseline_web.sh \
  ../docs/performance/vector-render-improvement/raw/browser \
  http://192.168.178.48:8787 2 2 8787
dart run tool/parse_benchmark_log.dart \
  ../docs/performance/vector-render-improvement/raw/browser/*.log \
  > ../docs/performance/vector-render-improvement/raw/browser/report.json
dart run tool/extract_vector_stages.dart \
  ../docs/performance/vector-render-improvement/raw/browser \
  ../docs/performance/vector-render-improvement/raw/browser/stages
```

The marker-sink server (= `vector_payload_server.dart --marker-log-dir`)
must be running for the run to land logs; the capture script starts it.
