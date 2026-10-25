# Physical iPhone profile results

Two runs of the pre-change saved binary and two runs of the fractional-zoom
binary were captured on the same connected physical iPhone, in profile mode
with Metal/Impeller, iOS 27.0.1, a 60 Hz display and DPR 3. The candidate recorded
1125 × 2436 physical pixels. The original baseline binary did not record numeric
viewport dimensions, so viewport equivalence was not independently logged.

**Update (2026-10-25):** the [scheduler A/B comparison](results-scheduler-ios.md)
on the same device supersedes these runs for the pacing decision: warm parity,
equal cold-load coverage latency at identical request volume, memory never
worse, and frame-tail differences within single-run noise — no regression,
with no tail claim made without repeat runs.

Each scenario used two seconds of warmup and six seconds of sampled motion,
with reporting queues drained between phases. These are short offline-raster
samples, not production-style, low-end-device, thermal, or long-session tests.

| Workload | Baseline UI p95, ms | Fractional UI p95, ms | Fractional raster p95, ms | Frames over 16.67 ms, baseline / fractional |
|---|---:|---:|---:|---:|
| markers_10000 | 8.89–9.60 | 8.93–9.35 | 0.40–0.43 | 5 / 4 |
| visible_markers_1000 | 4.92–5.16 | 5.07–5.27 | 1.88–1.90 | 0 / 0 |
| route_50000 | 4.61–4.64 | 4.63–4.65 | 1.38–1.40 | 3 / 2 |
| clusters_10000 | 7.85–8.57 | 8.13–8.49 | 0.66–0.66 | 3 / 2 |
| mixed_camera | 5.56–5.64 | 5.67–5.75 | 1.10–1.10 | 0 / 0 |

Ranges show both runs; over-budget counts aggregate both runs. The baseline
recorded 11/3600 over-budget frames; fractional recorded 8/3602.
The largest UI p95 stayed below the 16.67 ms display budget, but individual
heavy-workload UI frames still reached roughly 24–26 ms. Raster p95 remained
below 2 ms. These observations support keeping the new camera path for these
workloads; they do not establish a causal performance improvement. Clustering's
first-run difference fell inside the range observed in the repeated baseline.

The mixed camera workload changes zoom continuously in the candidate and in
integer steps in the baseline, so its timings represent different trajectories.
The other four workloads use the same scripted pans and marker/route counts.
Marker/routing data and tiles are generated locally; no HTTP traffic is timed.

Observed candidate process RSS snapshots ranged from 91.6 to 116.0 MiB.
The snapshots include engine/native allocations and vary with garbage collection;
they are not peak-memory measurements or proof of long-session leak freedom.
Unit/widget regressions separately verify image-budget fallback release,
10,000-marker viewport culling and 50,000-point route selection.

Raw reports: [baseline 1](baseline-ios.json), [baseline 2](baseline-ios-repeat.json),
[fractional 1](fractional-ios.json), [fractional 2](fractional-ios-repeat.json).
See [reproduction steps](README.md). Further validation should include production
vector styles, a slower device, constrained networks and an extended camera run.
