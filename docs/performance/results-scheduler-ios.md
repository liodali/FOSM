# Scheduler A/B: physical iPhone results

Measured: 2026-10-25, three capture iterations as the harness was
hardened (see the correction history below). One binary, two arms — the
comparison changes only the feature under test
(`--dart-define=fosm.unpaced=true` leaves every map's tile work unpaced:
no shared cooperative allowance, unbounded image submission — the
pre-scheduler behaviour). Device: the same physical iPhone as the
[earlier saved runs](results-ios.md), iOS 27.0.1, 60 Hz, 1125 × 2436
@ DPR 3, profile mode, generated offline raster tiles. The coldnet arm
shapes every fetch through a simulated 150 ms RTT / 1 Mbps link
(`BENCHMARK_NET_DELAY_MS=150 BENCHMARK_NET_KBPS=1000`, 12 s sampling
windows). Warm runs use the standard five scenarios with instant tiles;
coldnet runs use the six `BENCHMARK_LOAD` scenarios. Cold starts unmount
the map, clear storage with nothing able to race the clear, arm
recording, then mount a fresh map — the replacement's first load frame
(mount, grid build, fetch issuance, early arrivals) is the first frame
of the measured window. Coverage means integrate across the complete
recording window with boundary extension; zoom-fallback-painted cells
count as covered, not blank.

These are single runs per arm on one 60 Hz device with synthetic raster
tiles: evidence for these recorded workloads, not a universal FPS claim,
and not production-vector coverage. Raw reports (final iteration):
[paced](scheduler-paced-ios.json), [unpaced](scheduler-unpaced-ios.json),
[paced-coldnet](scheduler-paced-coldnet-ios.json),
[unpaced-coldnet](scheduler-unpaced-coldnet-ios.json).

**Correction history.** Capture 1 measured a cold start that leaked a
few disk-cache tiles before its window (a map-key swap without a
rebuild); capture 2 fixed the leak but armed recording only after the
replacement map had already mounted and begun loading, and averaged
coverage only across sampled frames. Capture 3 — the reports above —
unmounts before clearing, arms recording before mounting, and integrates
coverage over the whole window: the series now opens blank at the mount
frame (~16 ms) and first coverage lands with the first 150 ms-RTT batch
in both arms. Numbers from earlier captures are superseded; in
particular the "37% faster all-sharp" reading from capture 1 was an
artifact and is retracted.

## Warm scenarios (instant tiles): parity

| Workload | UI p95 ms (paced/unpaced) | UI p99 | UI max | Frames over budget |
|---|---:|---:|---:|---:|
| markers_10000 | 5.82 / 5.89 | 6.46 / 6.40 | 7.68 / 7.00 | 0 / 0 |
| visible_markers_1000 | 5.02 / 5.28 | 5.66 / 5.74 | 9.10 / 10.18 | 0 / 0 |
| route_50000 | 2.46 / 2.26 | 2.76 / 2.77 | 8.47 / 6.46 | 0 / 0 |
| clusters_10000 | 8.19 / 8.25 | 13.69 / 12.97 | 19.38 / 20.49 | 1 / 1 |
| mixed_camera | 4.38 / 4.34 | 4.92 / 4.61 | 6.73 / 7.34 | 0 / 0 |

With warm caches and instant tiles there is no decode/image-lane
contention to arbitrate, and the arms are equivalent within single-run
noise — i.e. **the scheduler costs nothing warm**, matching the earlier
saved baseline/fractional comparison.

## Cold loads under a constrained link (final capture)

Frame tails (UI ms, paced / unpaced) and coverage:

| Workload | UI p95 | UI p99 | UI max | first covered | all sharp | mean cov | mean sharp |
|---|---:|---:|---:|---:|---:|---:|---:|
| cold_static | 6.34 / 5.51 | 8.37 / 6.85 | 8.37 / 6.85 | 188 / 198 ms | 373 / 366 ms | 0.98 / 0.98 | 0.98 / 0.98 |
| cold_fling | 3.70 / 3.86 | **4.55 / 4.96** | **8.17 / 8.63** | 198 / 195 ms | 549 / 530 ms | 0.97 / 0.97 | 0.97 / 0.97 |
| cold_pinch | 4.79 / 5.03 | 6.06 / 5.97 | **7.79 / 9.52** | 186 / 187 ms | 689 / 187 ms* | 0.96 / 0.97 | 0.91 / 0.91 |
| warm_fling | 3.55 / 3.43 | 3.78 / 3.67 | 3.93 / 5.39 | 4 / 4 ms | 4 / 4 ms | 1.0 / 1.0 | 1.0 / 1.0 |
| warm_pinch | 4.80 / 4.80 | 5.35 / 5.30 | 7.25 / 7.04 | 18 / 5 ms | 18 / 5 ms | 1.0 / 1.0 | 1.0 / 1.0 |
| follow | 2.27 / 2.31 | 2.48 / 2.38 | 2.58 / 2.60 | — | — | — | — |

\* under continuous zoom oscillation the single-frame "all sharp"
rewards one burst-publish frame before the oscillation starts crossing
zoom levels; the window-integrated means show coverage is equal
(0.91 vs 0.91 sharp, 0.96 vs 0.97 covered — the gap between them is the
fallback-served time, visible in both arms).

What this evidence supports:

- **Coverage latency is equal**, not traded away: first covered and
  all-sharp times match within a few percent in every cold scenario, and
  window-integrated mean coverage is equal. The unpaced arm ramps faster
  in the first batch (0.75 vs 0.25 at the first arrival) before both
  converge — one-frame-later first paint is the cost of not publishing a
  whole batch on the UI thread at once.
- **Frame tails are within single-run noise, with mixed direction**:
  this capture favours paced under motion (cold_fling p99 4.55 vs 4.96,
  max 8.17 vs 8.63; cold_pinch max 7.79 vs 9.52) and favours unpaced on
  the still camera's burst (cold_static p95 5.51 vs 6.34). The
  *previous* capture — same arms, equally valid window minus its first
  load frames — showed the opposite sign on cold_static. We therefore
  make **no tail-improvement claim**: repeated runs per arm are required
  before any tail difference (either direction) is established.
- **Traffic is identical**: requests and served bytes match exactly in
  every scenario (68/68, 108/108, 181/181, 40/40, 4/4, 0/0) — the
  scheduler changes *when* work runs, not what is fetched.
- **Memory is never worse**: paced post-scenario RSS was equal in three
  scenarios and lower in the other three (72/72, 81/81, 83/83, 85/87,
  87/89, 87/88 MiB). Earlier captures had shown a consistently lower
  paced RSS; the corrected window narrows it to "not worse".

Zero frames over the 16.67 ms budget in every coldnet scenario in both
arms; all differences above are inside-budget tail behaviour.

## Verdict against the completion rule

Retain the scheduler, on what the evidence actually establishes for
these raster workloads: **no warm cost, no cold cost, equal coverage
latency at identical traffic, and memory never worse** — while the
pacing bound (cooperative allowance, bounded image starts per frame)
remains the load-bearing protection for heavier decode pipelines
(production vector loads) that this raster benchmark deliberately does
not exercise. A tail improvement on 60 Hz raster cannot be claimed from
single runs; repeat runs and vector captures remain the open follow-up.

Open: repeat runs per arm for run-to-run variance (the earlier warm
methodology used two runs per arm), production vector loads, mode/style
switches, real network variability, pointer-event input latency,
background/resume sessions, a slower device and 120 Hz hardware.

## Reproduction

```sh
cd example
zsh tool/capture_scheduler_ab.sh DEVICE_ID /tmp/fosm-ab-captures
dart tool/parse_benchmark_log.dart /tmp/fosm-ab-captures/paced.log \
  > ../docs/performance/scheduler-paced-ios.json   # …one per arm
```
