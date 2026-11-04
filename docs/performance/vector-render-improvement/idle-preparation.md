# Idle preparation and cache reuse diagnostics

Plan 06 targets the bytes-only vector padding ring: padding tiles are
fetched ahead of visibility but are not parsed, recorded or snapshotted
until they enter the viewport (`byteOnlyPadding`, strict-viewport
`isTileRelevant`), so newly revealed cells pay the full pipeline at
reveal time. Raster mode decodes its padding ring because raster decodes
are cheap; vector mode deliberately does not.

## Pan-into-new-area reveal latency (2026-11-04, z10 Zurich fixture)

From the plan-05 scheduler A/B captures (z10 fixture
`openfreemap-20261101-z10-zurich-v1`, iPhone, shipped pacing and the
loosened arm — the numbers are pacing-independent, identical to the
millisecond across all four runs): during a `vector_cold_fling` into a
new area, 11 cells are newly exposed and all reach sharp within the
window:

| Measurement (4 runs) | Value |
| --- | --- |
| Newly exposed cells | 11 |
| Sharp by window end | 11 of 11 |
| Mean new-cell → sharp, ms | 786–790 |
| Max new-cell → sharp, ms | 2,003–2,008 |

This is the plan-06 gate measured directly: a padding cell that scrolls
into view has its bytes already on disk/in memory but still takes **~0.8 s
mean, ~2.0 s worst** to appear sharp. The latency is insensitive to image
lane concurrency (see the [scheduler report](snapshot-scheduling.md)),
consistent with the pipeline cost (parse + record + snapshot after reveal)
rather than queue pacing — exactly the gap speculative preparation would
close.

## Return-pan and warm-revisit measurements (2026-11-04)

Two captures on the z10 fixture, iPhone, shipped pacing. A harness caveat
surfaced first: the benchmark's motion scripts (`returnPan`, `fling`) move
the camera to **absolute coordinates around the old default centre**
(lat 47.0, lon 8.0), not the mounted `BENCHMARK_LATITUDE/LONGITUDE`
centre. The z10 fling worked because its eastward travel (lon 8.0–8.95 →
tiles x 534–536) stayed inside the fixture grid; the return oscillation
(lon 7.5–8.5) initially ran off the west edge (tile column x 533,
8 failed cells). The fixture was extended with the x 533 column
(y 357–361, 5 tiles, 0.9 MB; SHA-256 `8bca2b05…e705f7`, `3b96c750…144947`,
`e8e34451…cc9bc1`, `01d505ca…7403f2`, `bc490e74…ca847d`) and the return
re-run as fixture id `openfreemap-20261101-z10-zurich-v2` (30 tiles,
4.9 MB). The 25-tile v1 set remains the identity recorded by the
scheduler-A/B fling and warm-parsed captures.

**Warm-parsed reload (final, v1 fixture):** reloading the settled
viewport with warm parsed data and cold images takes **258–275 ms to
all-sharp** (first sharp 58–75 ms, mean sharp fraction 0.98, zero
failures, zero over-budget frames, +2–4 MB RSS). Spans isolate the
per-tile cost: record p50 37.5 ms and `toImage` p50 3.4 ms with parse
already warm — consistent with round-1's synthetic 303–320 ms. This is
the floor any speculative preparation must beat: an offscreen-prepared
cell reveals instantly (cache hit ≈ free) versus ~260 ms warm / ~790 ms
cold (fling) through the on-demand pipeline.

**Retention under motion (from the west-failed v1 return run):** across
~3.3 oscillation cycles the spans show exactly 12 published decodes (the
initial centre columns) and **zero re-decodes** of already-published tiles
as cells re-exposed every cycle — the rendered cache held everything
within the window (20 s default expiry exceeds it). The 8 west-failed
cells make this run's reveal-latency numbers unusable, hence the v2
re-run; the no-re-decode observation itself is unaffected.

**Return oscillation (final, v3 fixture):** with the full halo present,
both clean reps are clean — 14 of 14 newly exposed cells reach sharp,
zero failed tiles, zero over-budget frames, UI p99 ≈ 6.0 ms:

| Measurement (2 reps) | Value |
| --- | --- |
| Mean new-cell → sharp, ms | 423, 349 |
| Max new-cell → sharp, ms | 1,187, 933 |
| First sharp / all sharp, ms | 290/558, 420/636 |
| UI p99, ms | 6.0, 6.0 |
| Published decodes (spans run) | 20 unique tiles, columns x 532–536 |
| Re-decodes of published tiles | 0 across ~3.3 oscillation cycles |
| Peak rendered / parsed | 5.0 MB / 20 tiles |

(The v1 run failed the west column x 533 — the motion scripts oscillate
around the benchmark's old default centre, not the mounted fixture
centre; the v2 run failed the south visible row y 362. Both runs are
retained under `raw/plan06/` as the retention reference; only v3 is
valid for reveal latency.)

**Fixture v3 (final):** the scenario's real footprint is wider than the
visible grid — the bytes-only padding ring sweeps x 530–540 × y 355–363
at z10 and adjacent-zoom preloading requests a z11 block
(x 1064–1075 × y 714–723). Fixture
`openfreemap-20261101-z10-zurich-v3` covers all of it: 219 tiles
(99 z10 + 120 z11, 26 MB, same `20261101_080013_pt` source), with a
per-tile SHA-256 manifest at `raw/dash-production-zurich-z10/hashes.sha256`
(manifest self-hash
`48da5a247ab24031e19a44cf3475a4d4eac6dd4be4304c090bf70d099918850d`) —
superseding the inline 25-tile table above, which remains as v1 history.
Fail-closed 404s for padding and adjacent-zoom tiles do not count as
failed tiles (the fling runs stayed `failed=0` while 404ing their ring);
only visible-set misses do.

## Task-1 summary and what it implies for the implementation

| Reveal context | Mean → sharp | Max |
| --- | --- | --- |
| Fling into new area (cold, on-demand) | 786–790 ms | 2,003–2,008 ms |
| Return oscillation (cold, on-demand) | 349–423 ms | 933–1,187 ms |
| Warm-parsed full re-render (floor) | 258–275 ms (all-sharp) | — |
| Rendered-cache hit (retention) | no decode at all | — |

Two design conclusions fall out before any speculative code is written:

1. **Speculation must produce images, not parsed data.** Parsed-only
   preparation saves ~1.5–7 ms/tile of parse, while the reveal path's
   cost is dominated by record + snapshot (the warm-parsed floor is
   ~260 ms even with parsing entirely warm). Only a rendered image in
   the rendered cache makes a reveal instant.
2. **The prize is bounded but real.** On-demand reveals cost 0.35–0.8 s
   mean (up to 2 s worst) per cell while the map is otherwise idle after
   the initial load; the retention side is already effective (zero
   re-decodes under motion, 20 s expiry covers typical pans). The
   implementation tasks (speculative admission, relevance, budgets)
   should therefore target the *first-visit* reveal only — retention
   work (the last plan task) has nothing left to fix on this evidence.

## Cache-hit accounting method

Cache-served re-exposures produce no decode spans: a cell that re-enters
the grid from the rendered cache goes sharp without `parse`/`publish`
activity for its tile key. Hit rate for a return cycle is therefore
(re-exposed sharp cells with no new decode) / (re-exposed cells), read
from the per-tile span identities of the spans run. The memory
attribution buckets (`peakRenderedBytes`, `peakParsedTiles`) bound what
retention is holding at the window's peak.
