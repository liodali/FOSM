# Dashed-line diagnostics

The plan 01 synthetic iPhone overzoom baseline attributes 438–443 ms of
synchronous work per scenario to dashed lines. The diagnostic capture
breaks that work down by logical tile, render attempt and style layer. It
records contour and pattern-step counts, extraction count, and separately
timed `extractPath` and `drawPath` calls. A solid fallback is counted
separately. Rows include work from attempts that later cancel; a nonzero
`droppedUpdates` means the bounded report is incomplete.

The counters are opt-in and perturb the measured operations: each extracted
segment incurs two stopwatch measurements and counter updates. Timings are
useful for deciding what to investigate, not for comparing clean frame or
coverage performance. Timed extraction and dispatch are only parts of the
outer `dash` span; do not add them to that enclosing span. Window boundaries
can split a contour across reports. No report is proof of production-tile
behavior unless the inputs themselves are representative.

## Initial iPhone diagnostic (2026-10-31)

One instrumented profile run used the same physical iPhone, 60 Hz, DPR 3,
`mvt-synth/1` dense-city payload and overzoom scenario as the
[device baseline](baseline-iphone.md). All 12 scenario result and stage
payloads were captured. For `vector_cold_overzoom`, the diagnostic reported
zero dropped updates and 14 tile/attempt/layer rows:

| Style layer | Contours | Pattern steps | Extractions / draws | Extraction | Draw dispatch |
| --- | ---: | ---: | ---: | ---: | ---: |
| road-service | 181 | 138,425 | 69,264 | 163.8 ms | 112.6 ms |
| road-minor | 270 | 74,356 | 37,275 | 80.9 ms | 55.1 ms |

Durations sum the individually timed operations across the scenario and
include measurement overhead. The counts include work from cancelled
attempts; a single diagnostic run is not a performance comparison. This
confirms both extraction and issuing draws deserve investigation, while
leaving contour traversal and loop overhead within the enclosing dash span.
The local raw capture is
`raw/dash-diagnostics/iphone-diagnostic-r1.log` (ignored by git).

## Offscreen classification (2026-10-31)

A second instrumented iPhone capture classified every extracted dash by
its path bounds, expanded by the larger of the stroke's miter limit and
cap extent plus two logical pixels. A dash is counted only if its expanded
bounds lie wholly outside the tile; unknown or non-finite bounds are not
counted as offscreen. No extraction or drawing was skipped in this run.

In its overzoom window, 80,714 of 98,596 extractions (81.9%) were
classified offscreen: 50,435 of 61,321 service-road dashes and 30,279 of
37,275 minor-road dashes. There were no unknown bounds or dropped updates.
The sample includes cancelled attempts and is from one synthetic workload;
diagnostic overhead changes scheduling, so the counts are not a clean
performance comparison. The local raw log is
`raw/dash-diagnostics/iphone-offscreen-r1.log` (ignored by git).

An experimental candidate, enabled with `fosm.vectorDashCull=true`, uses
the dash start and its arc length to conservatively bound the complete
centerline before extraction, then keeps the original phase and drawing
order. Unknown or very large coordinates fall back to the original path.
The candidate remains opt-in until pixel, cancellation and repeated clean
device comparisons meet plan 04's acceptance criteria.

In a separate instrumented candidate run, the diagnostic re-extracted
each skipped dash solely to verify its expanded bounds. It checked 83,678
skips (53,582 service, 30,096 minor) and found zero whose bounds overlapped
the conservative visible region or were non-finite. An additional 295
offscreen dashes were conservatively drawn. There were no dropped updates.
This run adds extraction overhead and is a safety check, not a performance
measurement; it covers only this synthetic sample. Its local raw capture is
`raw/dash-diagnostics/iphone-cull-validation-r1.log` (ignored by git).

## Isolated overzoom comparison (2026-10-31)

Two clean and two spans runs per variant on the same iPhone used the
synthetic dense-city source, 10-second `vector_cold_overzoom` window and
identical scenario-only cold starts. Runs were sequential, baseline first;
thermal state was not recorded. Span totals are summed synchronous slices
within the window, not end-to-end tile latency. All spans runs reported zero
dropped spans. Neither clean variant reached all-sharp in the window.

| Measurement | Baseline | Experimental culling |
| --- | --- | --- |
| `dash` span sum, ms (2 runs) | 429.7, 475.5 | 252.2, 225.6 |
| `dash` span count (2 runs) | 4,101, 4,409 | 4,838, 4,838 |
| Clean first-sharp, ms | 1,215, 1,405 | 1,019, 873 |
| Clean end sharp fraction | 0.75, 0.50 | 0.667, 0.75 |
| Clean end sharp area fraction | 0.899, 0.734 | 0.831, 0.899 |
| Clean UI p99, ms | 3.354, 3.316 | 4.151, 4.207 |
| Clean raster p99, ms | 5.487, 5.665 | 5.498, 5.589 |
| Clean frames over budget | 1, 0 | 0, 0 |
| Clean RSS after minus before, MB | 88.6, 108.2 | 91.6, 92.8 |

The candidate reduces summed dash time in these runs even with more dash
chunks, and first-sharp improved in both clean runs. End coverage varied,
and UI p99 was about 0.8–0.9 ms higher with the candidate; two sequential
repetitions cannot settle frame-tail or memory effects. Instrumentation
affects timings and the workload is synthetic. The candidate remains
disabled by default pending representative production-tile and platform
validation and a decision about the tail results. Raw local logs are in
`raw/dash-paired/` (ignored by git).

## Frozen production-tile sample

The production check uses OpenFreeMap's versioned `20261025_080012_pt`
OpenMapTiles source at z14. The first fetch (below) aimed at the
benchmark's default center (47N, 8E) so the overzoom viewport matches the
synthetic workload one-for-one.

| Tile z/x/y | SHA-256 of replayed MVT |
| --- | --- |
| 14/8555/5762 | `1db19aadee64b99d4e428b23cfa476d6f8464514315ac56c182d14ae586ed188` |
| 14/8555/5763 | `f0438af1da96ea6b72b92cffc643fb24b8c85b1ec4d598623247f4c213d38144` |
| 14/8556/5762 | `645f204a6d5a16d2199f1ec2076efbca68c9d45080a7764adef93de676edbbfe` |
| 14/8556/5763 | `1c1d6eef71a4b60325a139fed7f9515234be7c3aa7550982d91118082cd02671` |

A geo-check before the comparison showed these four tiles are ~14 KB each
and cover sparse Jura-foothills roads (47.04–47.07°N, 7.93–7.98°E), not a
dense city. The sample therefore stays stored under `raw/dash-production/14/`
as the center-matched reference (fixture id
`openfreemap-20261025-z14-47n8e-v1`), but the comparison below uses the
dense central-Zurich sample instead.

## Dense central-Zurich sample (2026-10-31)

The production comparison below uses nine dense central-Zurich z14 tiles
(47.354–47.398°N, 8.503–8.569°E, 358–678 KB each) fetched from the same
OpenFreeMap versioned source, stored under
`raw/dash-production-zurich/14/` (ignored by git). Replay center for the
overzoom scenario: 47.376°N, 8.5364°E (the grid's exact center). SHA-256
of the replayed MVT files:

| Tile z/x/y | SHA-256 |
| --- | --- |
| 14/8579/5736 | `997eded77deaae48f8be015a10129fca6f15faf9820cb374b7f909714a6687e6` |
| 14/8579/5737 | `2d7dd3265c43d0b39db636857a457648f7c25d36947808427a5895b00a931bee` |
| 14/8579/5738 | `e2e0caa7e599fc0164ba140f75436120bcfb27ab3bcd7d9d6efdbfc0b421be85` |
| 14/8580/5736 | `5fff905d75d7b1bc582b3593e2824d798d075ece8c198a4f3667ef8bdd21b7fd` |
| 14/8580/5737 | `5467d99fcf95fe74eece39770f889a3e29d906ffe7595947ea250027a6638535` |
| 14/8580/5738 | `ce2cdfaea2d56862899429fef2865400423c6444f31e35b6719550b76b0ebba0` |
| 14/8581/5736 | `0e2ac324bc399d35e940f6fc19a3aa464f0a08ddc2c95d2432ff7e3dd30eefa9` |
| 14/8581/5737 | `ac21a772aad2f3c884a01ac0f7f42f76ee7e03f3d02b6314d034ed1d89f4abc1` |
| 14/8581/5738 | `5760f80240d042aad004bac85f9aebe36219e39f0de159169560ba6a2b757cfd` |

The replay server returns 404 for missing fixture coordinates instead of
substituting synthetic tiles; capture metadata records the fixture
identity (`openfreemap-20261025-z14-zurich-v1`) and no synthetic seed.
The sample uses real tile geometry but the synthetic benchmark style, so
it does not represent the full production Liberty style or all road
densities; in the benchmark style only `road-service` and `road-minor`
carry dash patterns. Data attribution:
[OpenFreeMap](https://openfreemap.org/),
[OpenMapTiles](https://openmaptiles.org/) and
[OpenStreetMap contributors](https://www.openstreetmap.org/copyright).

To capture on the existing device workload:

```sh
cd example
BENCHMARK_DASH_DIAGNOSTICS=1 zsh tool/capture_vector_baseline.sh \
  DEVICE_ID /absolute/path/to/output LAN_IP 0 1 0
```

Each `FOSM_BENCHMARK_DASH_DIAGNOSTICS` payload includes its scenario name.
The marker sink retains the full JSON payload; console output may use the
chunk protocol understood by `lib/benchmark/log_lines.dart`. Use a separate
clean, non-instrumented run for coverage, frame-tail and memory comparisons.
Summaries below are parsed with
`python3 tool/parse_dash_diagnostics.py LOG [...]`.

## Production-tile diagnostics (2026-10-31)

Two instrumented iPhone runs replayed the dense-Zurich sample
(`vector_cold_overzoom`, one run per variant, diagnostics enabled, camera
at the grid's center). On real dense-city geometry the conservative skip
kept zero unproven skips, and contour/pattern-step counts are identical
between variants, as expected for a decision that only affects extraction
and draw dispatch:

| Measurement | Baseline | Candidate (`fosm.vectorDashCull`) |
| --- | --- | --- |
| Extracted dashes | 5,358 (3,660 service, 1,698 minor) | 4,054 (2,847 service, 1,207 minor) |
| Extracted though offscreen | 1,388 (25.9% of extractions) | 84 (extracted and later classified offscreen) |
| Skipped extractions | — | 1,304 (813 service, 491 minor) |
| Skips failing the bounds proof | — | 0 |
| Unknown/non-finite bounds | 0 | 0 |
| Dropped diagnostic updates | 0 | 0 |
| Contours (service + minor) | 429 + 229 | 429 + 229 |
| Pattern steps (service + minor) | 7,092 + 3,271 | 7,092 + 3,271 |

The synthetic dense-city workload classified 81.9% of extracted dashes as
offscreen; on dense central Zurich at z16 overzoom that share is 25.9%
(1,388 of 5,358). The candidate skipped 1,304 of those 1,388 dashes and
still extracted 84 whose expanded bounds were fully outside the tile —
conservative false negatives, as designed. No skip proved a false
positive (zero unproven). Both instrumented runs include cancelled-attempt
work and diagnostic overhead, so these are counts, not performance. Raw
local logs: `raw/dash-production-zurich/ios-diag-{baseline,candidate}/`.
The paired clean/spans comparison is in the dated iPhone section below.

## Dense-Zurich desktop comparison (2026-10-31)

macOS desktop runner, profile mode, DPR 2, 60 Hz, fixture replay of the
dense-Zurich sample, scenario `vector_cold_overzoom`, screen-level cold
starts. Two clean and two spans runs per variant, sequential, baseline
first. Desktop dash work is an order of magnitude smaller than on iPhone,
so the candidate comparison rests on the iPhone measurements above; this
run validates platform compatibility and memory.

| Measurement | Baseline | Candidate |
| --- | --- | --- |
| `dash` span sum, ms (2 runs) | 29.5, 35.9 | 32.5, 26.1 |
| Dash span count | 2,601, 2,601 | 2,601, 1,930 |
| First-sharp, ms | 742, 432 | 763, 582 |
| Window reached all-sharp | 4 of 4 runs | 3 of 4 runs (spans r2 ended 0.75 sharp; its dash row is from a partial run) |
| Max failed tiles | 0 | 0 |
| RSS after minus before, MB | 133.3, 198.1 | 161.9, 209.1 |
| Peak estimated tile bytes, MB | 23.0 | 23.0 |
| UI p99, ms | 7.33, 5.57 | 9.91, 7.47 |

The candidate matches baseline within desktop noise everywhere; its UI
p99 was higher in these four runs, and on this sample the smaller
extraction volume offers no measurable desktop win. The candidate spans
run that stalled reported fewer total spans (144,115 versus 170,772) and
a 0.75 sharp fraction at window end — desktop run-to-run variance, and
the reason a 2×2 sequential pairing cannot settle tail behavior. Raw
local logs:
`raw/dash-production-zurich/macos-{baseline,candidate}/`.

## Dense-Zurich browser comparison (2026-10-31)

Chrome (CanvasKit), profile web build, fixture replay of the
dense-Zurich sample, scenario `vector_cold_overzoom`, screen-level cold
starts, one marker-sink capture per rep. Two clean + one spans runs per
variant with the standard 10-second window, then one clean + one spans
run per variant with a 60-second window (`BENCHMARK_SAMPLE_SECONDS=60`).
On web the dense cold overzoom load does not converge inside either
window — the same shared-stall behavior the earlier synthetic web
captures showed (partial coverage only, and here `peakParsedTiles: 1`
with the first covered cell at ~32.9 s in both variants). No tile ever
failed and the two variants are indistinguishable:

| Measurement (60 s window) | Baseline | Candidate |
| --- | --- | --- |
| First covered/sharp, ms | 32,867 / 32,952 | 32,633 / 32,798 |
| Sharp fraction at window end | 0.0417 | 0.0417 |
| Max failed tiles | 0 | 0 |
| UI p50 / p99, ms | 0.2 / 0.6 | 0.2 / 0.6 |
| `dash` span sum, ms (spans run) | 36.4 | 35.4 |
| Dash span count | 278 | 278 |

The web 10-second runs showed the same pattern with zero coverage (the
coverage numbers are unusable at that window length; they remain in
`raw/dash-production-zurich/web-{baseline,candidate}/`). The web stall is
parse-bound and pre-dates the candidate; this run exists only to check
functional compatibility, which passes. Raw 60 s logs:
`raw/dash-production-zurich/web-{baseline,candidate}-t60/`.

## Dense-Zurich iPhone paired comparison (2026-11-01)

Same physical iPhone, 60 Hz, DPR 3, USB attach, dense-Zurich fixture
replay, scenario `vector_cold_overzoom`, scenario-only cold starts, two
clean and two spans runs per variant, sequential, baseline first. All four
spans runs reported zero dropped spans, and both variants reached an
all-sharp viewport inside every 10-second window.

| Measurement | Baseline | Candidate |
| --- | --- | --- |
| `dash` span sum, ms (2 runs) | 17.51, 13.91 | 19.93, 17.25 |
| Dash span count (2 runs) | 827, 827 | 827, 827 |
| Clean first-sharp, ms | 722, 888 | 540, 508 |
| Clean all-sharp, ms | 2,314, 2,996 | 2,027, 2,329 |
| Clean end sharp fraction | 1.0, 1.0 | 1.0, 1.0 |
| Clean mean sharp fraction | 0.862, 0.825 | 0.875, 0.868 |
| Clean UI p99, ms | 0.520, 2.646 | 0.483, 1.651 |
| Clean frames over budget | 0, 0 | 0, 0 |
| Clean RSS after minus before, MB | 115.9, 97.9 | 115.8, 109.9 |
| Peak estimated tile bytes, MB | 11.8 | 11.8 |
| Max failed tiles (all runs) | 0 | 0 |

On representative production tiles the entire 10-second dash budget is
14–18 ms and the candidate spent consistently more time in dash chunks
than the baseline (the per-chunk arc-length/tangent query outweighs the
24.3% extraction savings at this chunk scale), while clean coverage
improved slightly and no frame-tail, failure or memory cost appeared. This
is the measurement plan 04's acceptance gate asks for, and it does not
show the production-tile CPU win required to enable the candidate by
default: the halved synthetic totals came from a workload where 81.9% of
extractions were offscreen, which dense central Zurich at z16 overzoom is
not. The prototype stays opt-in (`fosm.vectorDashCull`); enabling it is
only defensible for dash-dense synthetic-like payloads. Raw local logs:
`raw/dash-production-zurich/ios-{baseline,candidate}/`.
