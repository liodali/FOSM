import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fosm/src/common/rendered_tile_cache.dart';

/// Point-in-time attribution of the memory FOSM retains for one map.
///
/// Read it periodically (for example once per second during a captured
/// workload) to observe which bucket grows. Byte figures are estimates:
/// rendered images count RGBA pixel memory, parsed tiles a coarse heap
/// estimate, compressed bytes their payload length. Process RSS is not
/// included and must be sampled separately — these numbers attribute
/// *retained* resources, they do not measure peak allocation.
///
/// Vector-only buckets ([parsedTiles], [rasterTiles], labels) are `null`
/// in raster mode and after the vector runtime was disposed.
///
/// Byte coverage: [estimatedTotalBytes] includes every bucket with a
/// meaningful estimate — rendered images, compressed bytes, parsed tiles,
/// raster sources and geometry. Deliberately **not** summed: prepared
/// label painters (reported as [preparedLabels] counts only — text
/// layout heap varies too much per label for a fixed allowance to be
/// honest), the sprite atlas, the marker/clustering index and the
/// persistent disk cache. Attribute those buckets separately when a
/// capture needs them.
class FosmMemoryAttribution {
  const FosmMemoryAttribution({
    required this.renderedImages,
    required this.compressedBytes,
    required this.compressedEntries,
    required this.geometryRings,
    required this.geometryVertexUnits,
    required this.geometryEstimatedBytes,
    required this.inFlightLoads,
    required this.queuedLoads,
    required this.pendingPresentations,
    required this.pendingFetches,
    this.parsedTiles,
    this.parsedTileEstimatedBytes,
    this.rasterTiles,
    this.rasterTileBytes,
    this.preparedLabelTiles,
    this.preparedLabels,
    this.labelJobsOutstanding,
  });

  /// Rendered (decoded) tile images, split into protected and evictable.
  final RenderedTileCacheStats renderedImages;

  /// In-memory compressed tile payload bytes (adjacent-zoom preloads).
  final int compressedBytes;

  /// Entries backing [compressedBytes].
  final int compressedEntries;

  /// Cached route/polygon rings (view layer), or 0 without shapes.
  final int geometryRings;

  /// Vertex units charged against the geometry cache budget (16 bytes of
  /// coordinates per unit, doubled once a segment index exists).
  final int geometryVertexUnits;

  /// Estimated coordinate storage of the cached rings:
  /// [geometryVertexUnits] × 16 bytes. This is the flat normalized world
  /// coordinate payload (plus built segment indexes), not Dart list/box
  /// overhead.
  final int geometryEstimatedBytes;

  /// Logical tiles currently being fetched or decoded.
  final int inFlightLoads;

  /// Load jobs waiting for a concurrency slot.
  final int queuedLoads;

  /// Decoded-but-unpublished presentations (queued plus active).
  final int pendingPresentations;

  /// Raw network fetches awaiting bytes or timeout.
  final int pendingFetches;

  /// Parsed source tiles shared across over-zoom siblings, or `null` in
  /// raster mode.
  final int? parsedTiles;

  /// Coarse heap estimate of the parsed tiles, or `null` in raster mode.
  final int? parsedTileEstimatedBytes;

  /// Decoded raster-source tiles (relief and similar layers), or `null`
  /// in raster mode.
  final int? rasterTiles;

  /// Estimated RGBA pixel bytes of the raster-source tiles, or `null` in
  /// raster mode.
  final int? rasterTileBytes;

  /// Tiles with cached prepared labels, or `null` in raster mode.
  final int? preparedLabelTiles;

  /// Prepared labels (text/halo painter pairs) across those tiles, or
  /// `null` in raster mode.
  final int? preparedLabels;

  /// Label-preparation work still outstanding (queued jobs plus the
  /// active preparation), or `null` in raster mode. A stable
  /// [preparedLabels] count alone does not prove preparation finished —
  /// a batch can be mid-flight without changing the cached count; this
  /// counter reaching zero is what settles.
  final int? labelJobsOutstanding;

  /// Estimated retained bytes across all buckets with a meaningful
  /// estimate: rendered images, compressed bytes, parsed tiles, raster
  /// sources and geometry coordinates. Label painters, the sprite atlas,
  /// the marker index and the disk cache are counted but not byte-summed
  /// — see the class documentation.
  int get estimatedTotalBytes =>
      renderedImages.bytes +
      compressedBytes +
      (parsedTileEstimatedBytes ?? 0) +
      (rasterTileBytes ?? 0) +
      geometryEstimatedBytes;

  /// One-line summary suitable for periodic logging.
  @override
  String toString() {
    final vector = parsedTiles == null
        ? ''
        : ' parsed~${_kb(parsedTileEstimatedBytes)}($parsedTiles)'
            ' raster~${_kb(rasterTileBytes)}($rasterTiles)'
            ' labels=$preparedLabels/${preparedLabelTiles}tiles';
    return 'FOSM memory: rendered~${_kb(renderedImages.bytes)}'
        ' (protected~${_kb(renderedImages.protectedBytes)},'
        ' evictable~${_kb(renderedImages.evictableBytes)},'
        ' ${renderedImages.entries} imgs)'
        ' compressed~${_kb(compressedBytes)}($compressedEntries)'
        ' geometry~${_kb(geometryEstimatedBytes)}($geometryRings rings/$geometryVertexUnits vu)'
        ' outstanding=loads:$inFlightLoads queued:$queuedLoads'
        ' presents:$pendingPresentations fetches:$pendingFetches'
        '$vector total~${_kb(estimatedTotalBytes)}';
  }
}

String _kb(int? bytes) {
  if (bytes == null) return 'n/a';
  if (bytes < 1024) return '${bytes}B';
  return '${(bytes / 1024).round()}K';
}

/// Opt-in periodic attribution logging for long-session memory captures.
///
/// Enable in profile builds with `--dart-define=fosm.traceMemory=true` and
/// read the `FOSM memory:` lines from the device log alongside OS memory
/// reporting (iOS footprint, Android `dumpsys meminfo`): the attribution
/// lines explain *retained* buckets, the OS numbers include the Dart heap,
/// GPU surfaces and allocator peaks. Disabled builds start no timers and
/// the [MapView] code path is free.
class MemoryTrace {
  MemoryTrace._();

  static const bool enabled = bool.fromEnvironment('fosm.traceMemory');

  /// Sampling period of the periodic logger.
  static const Duration interval = Duration(seconds: 1);

  /// Logs [attribution] every [interval]. Returns the cancel callback, or
  /// `null` when tracing is disabled so callers need no flag checks.
  static VoidCallback? start(FosmMemoryAttribution Function() attribution) {
    if (!enabled) return null;
    final timer = Timer.periodic(interval, (_) {
      debugPrint(attribution().toString());
    });
    return timer.cancel;
  }
}
