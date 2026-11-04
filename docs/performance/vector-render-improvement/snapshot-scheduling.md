# Snapshot and scheduling diagnostics

Plan 05 investigates image generation (`Picture.toImage` snapshots) and the
shared work scheduler that paces them. Two opt-in span events bracket the
snapshot path: `imageWait` wraps the whole scheduler image-lane round trip
(queue wait, frame-boundary waits, the snapshot itself) and `toImage` wraps
only the `picture.toImage(256, 256)` call. Their difference is scheduler
pacing, not CPU. Stage totals below come from `FOSM_BENCHMARK_VECTOR_STAGES`
payloads parsed from the existing raw captures; nothing was re-run for this
analysis.

## imageWait versus toImage (existing captures)

Averaged per image, summed per capture set (all spans runs to date):

| Capture set (platform, workload) | Images | `imageWait` avg / p95, ms | `toImage` avg / p95, ms | Lane share of `imageWait` |
| --- | ---: | --- | --- | ---: |
| iOS synthetic, round 1 (z10 cold, 2 runs) | 230 + 230 | 16.1 / 17.7 | 2.3 / 2.4 | ~86% |
| iOS synthetic, round 2 (all scenarios) | 456 | 17.3 / 36.1 | 2.5 / 12.0 | 85.5% |
| iOS synthetic overzoom pair (dash round) | 24 + 36 | 26.7 / 24.7 | 11.7 / 10.6 | ~57% |
| iOS dense-Zurich fixture (baseline / candidate) | 32 + 32 | 19.3 / 22.4 | 5.0 / 6.2 | ~73% |
| macOS dense-Zurich fixture | 96 + 84 | 23.5 / 20.4 | 8.2 / 7.1 | 65% |
| Chrome synthetic (round captures) | 65–72 | 22.6–27.0 | 16.6–21.5 | 21–26% |
| Chrome dense-Zurich 60 s window (1 image) | 1 | 50.3–53.1 | 41.8–43.4 | ~18% |

Readings:

- On native platforms **65–86% of `imageWait` is scheduler-lane pacing**
  (the nominal 2 ms budget, 2 image starts per frame, 2 active images), not
  snapshot work. At 60 Hz a saturated lane adds at least one frame (~16.7 ms)
  of queue time per image beyond the first two of a frame — visible as
  `imageWait` p50 ≈ 17 ms on the synthetic iOS rounds.
- On the browser engine the split inverts: the CanvasKit snapshot itself is
  the larger term (16–43 ms elapsed), and lane pacing is ~20%. Web
  optimizations should target the snapshot cost, not the lane.
- `toImage` elapsed grows with zoom (round-2 timeline: z10 p50 1.7 ms,
  z16 overzoom p50 10.2 ms, max 21.9 ms) — heavy overzoom snapshots are the
  expensive ones.

## Is `toImage` UI-thread CPU? (round-2 timeline analysis)

The Dart-VM timeline capture `raw/round2/vector-trace-r1-timeline.json`
(109,211 events, all 13 scenarios) contains 122 `fosm.vector.toImage` async
spans on the UI thread. Their wall time is elapsed future completion, so the
plan-05 question is whether that time is actually UI-thread work. Analysis
of UI-thread busy spans (Animate, Build, Layout, Paint, Compositing, Finalize
tree) inside each `toImage` window:

- UI-thread busy time inside `toImage` windows: **4 ms of 300 ms total (1%)**.
- Longest UI-thread silence inside a window: p50 1.9 ms, p95 6.1 ms,
  max 16.1 ms — within the ordinary busy-gap distribution of the same thread
  (p95 15.7 ms, p99 16.6 ms, the 60 Hz frame cadence).
- The seven z16 overzoom windows (5.5–21.9 ms, the heavy case) contain
  0–4 ms of UI work each, and the next busy span starts 2.8–10.9 ms *after*
  each window ends. A blocked UI thread would show the opposite signature:
  pending frame work starting exactly at window end. The thread idles through
  the snapshot; it does not block.
- Corroborating evidence: the benchmark recorded zero frames over the
  display budget in every native scenario while up to two snapshots were in
  flight, and `publishWait` ≈ 0.1 ms (the finished image's hop back to the
  render set is free).

Conclusion: on native, `toImage` runs off the UI thread and its future
resolves later; the image lane's deliberate pacing is what `imageWait`
measures. Loosening pacing can only shorten time-to-sharp if the lane is the
binding constraint (record/parse may bind instead) — that is exactly what the
plan-05 scheduler A/B must measure, with stationary loading, gestures and
animation separated.

Limitations: the Dart timeline carries no engine raster-thread or GC
categories, so off-UI execution is inferred from the absence of a blocking
signature plus the frame-budget record, not from direct raster-thread
attribution. Chrome version for the browser captures is not recorded (see
`dash-diagnostics.md`, Versions and provenance).

## Discard counting (task 2 instrumentation)

The stale-work gates were rechecked in code: the runtime checks relevance
while queued for a decode slot, before recording, after recording, after the
1 ms pre-snapshot delay, and the scheduler re-evaluates relevance when a
lane slot opens — obsolete work never enters `toImage`. Spans already
counted `staleAbort` marks (decode-slot waits, cancelled records) and
`payloadInvalid`. The gaps were the two pre-snapshot exits and the
scheduler-side lane drops; both are now marked:

- `snapshotDiscard` — the attempt finished recording but went stale before
  entering the snapshot lane (either pre-lane check). The most expensive
  avoided work.
- `laneDiscard` — the scheduler dropped the work from the image queue
  because relevance went false before a slot opened. Fired via a new
  per-submission `onRelevanceDrop` callback so the shared scheduler stays
  free of vector-package imports; disposal aborts do not fire it.

Both land in `FOSM_BENCHMARK_VECTOR_STAGES` (`markers.snapshotDiscard` /
`markers.laneDiscard` globally, per-attempt rows `snapshotDiscards` /
`laneDiscards`). Unit tests cover the scheduler callback semantics (fires
exactly once per relevance drop, never on disposal) and the stage-report
counting. Capture with `--dart-define=fosm.vectorSpans=true` as usual; the
counts ride the existing stage payload with no extra defines.

## Scheduler budget A/B (task 3 preparation)

`MapViewController`-level pacing is now overridable by compile-time defines
so A/B arms change only the values under test:

- `fosm.workBudgetMs` (default 2) — cooperative UI-work budget.
- `fosm.imageStartsPerFrame` (default 2).
- `fosm.activeImages` (default 2).
- `fosm.unpaced` — the existing kill switch (scheduler off).

`capture_vector_baseline.sh` forwards `BENCHMARK_WORK_BUDGET_MS`,
`BENCHMARK_IMAGE_STARTS` and `BENCHMARK_ACTIVE_IMAGES` to these defines.
Invalid values fail construction loudly rather than silently mispacing.

Planned device matrix (iPhone, dense-Zurich fixture, fixture id
`openfreemap-20261025-z14-zurich-v1`, center 47.376/8.536): arms
{shipped 2/2/2, `4ms budget`, `3 starts / 3 active`, `4 starts / 4 active`}
× scenarios {`vector_cold_static` (stationary loading), `vector_cold_fling`
(gesture), `vector_cold_pinch` (continuous animation)}, 2 clean + 1 spans
rep per cell, baseline arm first. Compare first-sharp/all-sharp, UI/raster
p95/p99, missed frames, `laneDiscard`/`snapshotDiscard` counts and memory.
An arm is acceptable only if stationary loading improves without harming
motion frame budgets or input responsiveness; interaction-aware pacing
(plan task 4) stays unprototyped unless the fixed budgets leave measured
idle headroom, and the 1 ms pre-snapshot delay stays unless a dedicated
A/B shows frame responsiveness unaffected without it.

## Scheduler A/B: overzoom stationary cell (2026-11-04)

First pass: `vector_cold_overzoom` on the dense-Zurich z14 fixture, iPhone
(60 Hz, DPR 3, USB), two clean + one spans run per arm, sequential,
baseline first. Arms: shipped pacing (`2 ms` budget, 2 starts/frame,
2 active) versus a loosened lane (`2 ms`, 3 starts, 3 active). Zero
`laneDiscard`/`snapshotDiscard` in both arms — expected with a stationary
camera; the counters need motion to become nonzero.

| Measurement (clean, 2 reps) | Baseline 2/2/2 | Starts3 |
| --- | --- | --- |
| First sharp, ms | 487, 404 | 571, 506 |
| All sharp, ms | 2,044, 1,946 | 2,311, 2,230 |
| Mean sharp fraction | 0.878, 0.888 | 0.865, 0.873 |
| UI p99, ms | 0.477, 1.872 | 2.405, 0.472 |
| Frames over budget | 0, 0 | 0, 0 |
| RSS after minus before, MB | 112, 108 | 99, 103 |
| Max failed tiles | 0, 0 | 0, 0 |

| Spans run | Baseline | Starts3 |
| --- | --- | --- |
| `record` sum, ms (8 tiles) | 5,938.5 (p50 900) | 7,080.8 (p50 986, max 1,285) |
| `imageWait` sum, ms | 150.2 | 163.7 |
| `toImage` sum, ms | 46.5 | 48.6 |

Loosening the image lane made time-to-sharp **worse**: all-sharp slipped
13–18% and first-sharp rose ~90–100 ms, with no frame-budget benefit and
memory flat. The spans identify the mechanism: `record` is the binding
stage (per-tile p50 ~0.9 s), and a third concurrent tile splits the same
2 ms-per-frame cooperative budget three ways, stretching every tile's
recording — including the last, which is what all-sharp waits for. The
image lane was not the constraint on this stationary heavy workload.
Conclusion for this cell: keep the shipped 2/2/2 pacing; the interaction
pacing prototype (task 4) has no idle-headroom motivation here. The
motion cells (z10 fixture) are the remaining half of the matrix.

## z10 Zurich fixture for motion scenarios (2026-11-04)

The dense-Zurich z14 fixture only supports the overzoom scenario:
`vector_cold_static` and `vector_cold_fling` run at the default z10 camera
and request z10 source tiles, which the fail-closed replay server cannot
serve (an initial A/B attempt with the z14 fixture failed all 12 visible
tiles in every run — 404s by design; those runs were discarded). A
companion z10 fixture was fetched for the motion cells: 25 tiles (5×5,
x 534–538, y 357–361, 153–235 KB each, 4.0 MB total) from OpenFreeMap
version `20261101_080013_pt` (the version current at fetch time; note the
planet source rotates versions, so re-fetching later yields different
bytes), stored git-ignored under `raw/dash-production-zurich-z10/10/`.
Replay center stays 47.376°N, 8.5364°E (inside tile 536/359, ≥1 tile of
fling headroom on every side). Fixture id:
`openfreemap-20261101-z10-zurich-v1`. SHA-256 of the replayed tiles:

| Tile | SHA-256 | Tile | SHA-256 |
| --- | --- | --- | --- |
| 10/534/357 | `0b068ce8d9ac0593edd4fbc54f58f94f68637a8331c7937dcdb76027b65bfb19` | 10/536/357 | `195a463f0b1e80e714680eaac19145643463105707cdfa62f412bcc85b76517a` |
| 10/534/358 | `6d07bf37bfaea664e642bff7dd8ebc5225396589206699f4ecea13d9fa309368` | 10/536/358 | `9459dcbaf9e901c7c767d9cb926c6014f7aadcec73d4750f26f7015b6bfa65db` |
| 10/534/359 | `9a4512781f6fcdb813db4b44970c87168132154950e9b603b4719a59242b54b4` | 10/536/359 | `05ac20aa03dfa26f63792f7910c025e1687d2b9c11cc765a2c672aafcdc43ce0` |
| 10/534/360 | `bf4808b7fd8c31dea8d6209116562345e2450a239746e715b71cc187aaae55e6` | 10/536/360 | `4b40bb3b848be230351f1ce7623af748dd662509ad924c4fa41bf09fd4931e08` |
| 10/534/361 | `cc79b3caa0193ba67526b0350b0ca5efaaea7672fc71809a6d0450a4c9976b8c` | 10/536/361 | `dc05927b3b67e36f57c9ef195285e85377b60c2e29d49ce64ae19fa9f6e01a46` |
| 10/535/357 | `e2f879a085872f4fdc81f5041b9722f427a2dcef9a32f45b5300d96e103e7ee7` | 10/537/357 | `836f18fc780b94050595da6a5e851052f1b4aa6c1b1aa0e310ef103782253bf2` |
| 10/535/358 | `0526a5f6cab0eddfe70e1ee7c2c4a7e0a2eda8fd27374e40d2ca65450bfc2fd4` | 10/537/358 | `819c413755707c949d6dec0df2562648a5cf2ec2f31b7a30747d805d1607b484` |
| 10/535/359 | `9742cf486cd4b6e1b28e8f6281f6609b9ed408fb6b4c33d45f74764ef4e97765` | 10/537/359 | `dae29cef6f33099157a8db7192d6f909c1554a9f043937c55b2a79c14c4bb822` |
| 10/535/360 | `50c8021f053aee059650683d6493fa8980a34467ff8b7a421d9fa319c9d17254` | 10/537/360 | `7a6ff2e4675fe1e95ec6befa9e2b594347922553db99c3c65318f1364d1dc774` |
| 10/535/361 | `dcc19dc684181f17c4c59b88a8560ea135d4c22ae4f8617b6dead8128a5a8c9d` | 10/537/361 | `f4bf24389fc6d62c90f8080031a4c5db3d5a79ba774b32bc1e262287f968c884` |
| — | — | 10/538/357 | `e06aa711447f43382ab5ea5b95a83bd737984c6343118396cc2f6f1810907cd2` |
| 10/538/358 | `3919649d98112f9409dee8f4189c9adfa6d4c3c837766ed7f781d96668c169e1` | 10/538/359 | `f04cf5ba812c62243330329caf3576e22bf739e041854fc04814ef946c7a9b82` |
| 10/538/360 | `d365f635980d111aa9bc10e22bc8f9d0437953503296724dfe2849b0268d074a` | 10/538/361 | `729258c6aa0590d2ae44646fdb3c1a54661f749bd8554f5f60949c85eeebaee9` |

## Scheduler A/B: z10 motion cells (2026-11-04)

Same device and protocol, scenarios `vector_cold_static` (stationary) and
`vector_cold_fling` (gesture) on the z10 Zurich fixture
(`openfreemap-20261101-z10-zurich-v1`), 2 clean + 1 spans per arm,
sequential, baseline first.

| Measurement (clean, 2 reps) | Baseline static | Starts3 static | Baseline fling | Starts3 fling |
| --- | --- | --- | --- | --- |
| First sharp, ms | 87, 88 | 86, 101 | 186, 185 | 136, 150 |
| All sharp, ms | 337, 389 | 387, 368 | 352, 354 | 352, 383 |
| Mean sharp fraction | 0.978, 0.976 | 0.975, 0.975 | 0.969, 0.970 | 0.971, 0.971 |
| UI p95 / p99, ms | 1.3 / 2.2 | 1.3 / 2.2 | 5.4 / 6.1 | 5.4 / 6.2 |
| Frames over budget | 0, 0 | 0, 0 | 0, 0 | 0, 0 |
| RSS delta, MB | 21, 25 | 16, 20 | 15, 27 | 21, 21 |

Spans: static `toImage` is trivial (12 tiles, 1.1–1.4 ms p50) and the load
is fetch-bound (2.1 s of overlapping localhost fetch spans); fling
`imageWait` sums 320 ms (baseline) vs 293 ms (starts3) across 20 tiles.
`laneDiscard`/`snapshotDiscard` were zero in every z10 cell — the short
fling never made an in-flight tile irrelevant (historical captures do
contain 88 `staleAbort` marks, so the gates fire in other workload shapes;
a pinch or far-return scenario would be needed to exercise the new
counters on device).

Reading: at z10 the lane loosening is a wash on stationary loading
(all-sharp overlaps) and shows a first-sharp win on fling (136/150 vs
186/185 ms — the third active slot lets the first tiles finish sooner),
but all-sharp, frame budgets and memory are unchanged there. Combined with
the overzoom stationary regression (+13–18% all-sharp), the matrix does
not support changing the shipped pacing: the win is confined to the first
moments of a gesture while the cost lands on the heaviest loading case.
Task 4 (interaction-aware pacing — loosen during gestures, tighten while
stationary) would be the only way to keep both, and the plan gates it on
measured idle headroom, which the record-bound overzoom cell does not show
(the cooperative budget is saturated while recording; there is no idle to
reclaim). Recommend: keep shipped 2/2/2 pacing; do not pursue the
interaction-pacing prototype on this evidence.
