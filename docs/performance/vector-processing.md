# Vector processing measurements

Enable instrumentation in a profile build with:

```sh
flutter run --profile --dart-define=fosm.traceVector=true
```

Run from the example directory on the target device. Capture the Dart timeline
and CPU samples in DevTools; include the MVT worker isolate. Disable the define
for final frame-rate comparisons: detailed style and chunk events add overhead.
Normal builds leave the instrumentation disabled.

| Event prefix `fosm.vector.` | Meaning |
| --- | --- |
| `fetch` | Logical tile's shared byte fetch (per tile-manager job, before any decode attempt). Over-zoom siblings joining one in-flight download report the same wait. Cache hits skip this event. |
| `queueWait` | Elapsed from decode-gate entry to slot acquisition, including relevance rechecks. Span-log only (no timeline event); never sum as CPU. |
| `parseWait` | Logical tile's wait for parsing, including shared-parse waits, worker startup/queue and transport. Cache hits skip this event. |
| `parseDispatch` | Native main-isolate request send. |
| `parse` | Synchronous decode on the persistent native worker, or inline test/fallback path. Worker timeline events carry the triggering tile/attempt as arguments. |
| `parseReply` | Native worker reply send, including synchronous object-copy work. |
| `parseCooperative` | Browser decode wall time, including cooperative yields. |
| `record` | Picture recording wall time, including scheduler waits. |
| `recordChunk.<layer id>` | Synchronous recording slice, excluding awaits; inspect CPU samples and nested style/geometry/dash spans. |
| `style` | Renderer paint expression or feature-filter evaluation. Static cache hits do not evaluate again. |
| `geometry` | Bounds scan and path-verb construction slices. |
| `dash` | Path metric traversal, segment extraction and stroke dispatch slices. |
| `imageWait` | Image lane queue plus image creation. |
| `toImage` | Actual snapshot future, starting after the scheduler grants the image slot. |
| `labels.build` | Label feature scanning and style evaluation for one tile, including cooperative yields; nested per-feature work is not traced separately. |
| `labels.layout` | Text/halo `TextPainter.layout` batch for one tile. |
| `labels.paint` | Synchronous label overlay paint: viewport collision placement and drawing of prepared labels. |
| `publish` (marker) | The tile manager placed a decoded image into the visible grid — the end of that tile's fetch → queue → parse → record → image critical path. |

Every span is correlated by logical tile, rendering attempt
(`<runtimeId>.<sequence>`, assigned at decode-gate entry so queueing
through `toImage` and the label lane share one id — tile coordinates
alone cannot identify an attempt across return pans, retries and style
switches) and resolved source tile (over-zoom siblings sharing one
parse/download correlate through it). Timeline events carry these as
`arguments` (`tile`, `attempt`, `source`); the span log carries them as
span fields, and the benchmark's stage report keeps stage sums and
wall-clock windows **per attempt**. A shared parse's worker spans carry
the triggering (first-requester) attempt. `publish` markers claim the
completed decode attempt of the tile they place.

Async spans measure elapsed time, not UI CPU. They may overlap across tiles;
do not sum them as CPU time. Dispatch/reply spans expose synchronous send costs,
but do not isolate all VM transfer/deserialization costs. Worker `parse` and
main-isolate `parseWait` together help distinguish decoding from queue/transport
latency. The one-shot `compute` fallback remains aggregated in `parseWait`.
No transport-only latency measurement is claimed.

## Changes in this pass

- Bounds scans yield after 512 tested vertices, including parts that are entirely
  off-tile and never build a path. Once accumulated bounds overlap, scanning
  stops: adding more points cannot shrink those bounds.
- Dash traversal yields once per contour and after 64 pattern steps. Phase,
  current distance and alternating draw/gap state survive each yield.
- Cancellation uses the existing renderer cleanup: end and dispose the partial
  Picture; the runtime bridges stale renders to `TileDecodeAborted`.

These are work-count checkpoints, not a guarantee of a 2 ms slice. Native
`PathMetric` advancement/extraction, `drawPath` and `toImage` remain indivisible.
Measure their tails before changing batch sizes or retained representations.

## Next captures

Use the same physical device, viewport, style, tile payloads and camera path
for baseline and candidate. Capture cold source parsing, warm parsed tiles,
dense dashed roads and overzoom siblings separately. Record UI/raster frame
p50/p95/p99, longest synchronous chunk, coverage latency and peak memory.
Compare pixels, clipping, opacity and layer order alongside timings.

Decide on prepared geometry/retained Pictures only after these captures show
which stage dominates. Reuse must preserve source coordinates, overzoom
transforms, style zoom and LRU memory limits. Zoom-only expression reuse is
implemented for label preparation (plan 05); use the `labels.*` spans to
profile collision placement during motion separately from feature scanning
and text layout. No physical-device FPS improvement is established
by the unit and browser regressions.
