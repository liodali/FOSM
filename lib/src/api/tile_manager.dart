import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Size, Offset;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'package:fosm/src/common/cache_tile_mixin.dart';
import 'package:fosm/src/common/osm_transformation_utilities.dart';
import 'package:fosm/src/common/utils.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/lat_lng_bounds.dart';
import 'package:fosm/src/isolate/http_isolate.dart'
    if (dart.library.io) 'package:fosm/src/isolate/http_isolate_native.dart'
    if (dart.library.js_interop) 'package:fosm/src/isolate/http_isolate.dart';
import 'package:fosm/src/api/tile.dart';
import 'package:fosm/src/api/tile_source.dart';

// ─── Tile manager ────────────────────────────────────────────────────────────

/// Manages the visible tile grid, in-memory image cache, and network
/// fetches for an OSM map view.
class TileManager with CacheTiles {
  static const int maxMemoryCachedTiles = 200;
  static const int maxByteCacheBytes = 50 * 1024 * 1024; // 50MB compressed
  static const Duration failureBackoff = Duration(seconds: 5);
  static const int defaultTilePadding = 2;

  /// How long to wait after the user stops panning before pre-loading
  /// adjacent zoom tiles. Prevents flooding the network during active drag.
  /// Set to [Duration.zero] to disable debouncing (useful for tests).
  final Duration preloadDebounce;

  /// Maximum number of adjacent-zoom preload jobs a single preload pass
  /// enqueues. This bounds how much work is added to the queue at once; the
  /// scheduler separately bounds how many actually execute.
  static const int maxConcurrentPreloads = 20;

  /// Maximum number of foreground load jobs executing at once. Foreground
  /// work is a strict-viewport tile or a raster padding tile. Excess jobs
  /// stay queued so a newer camera generation can jump ahead of stale
  /// queued requests instead of them leaving the queue immediately.
  static const int maxConcurrentVisibleLoads = 6;

  /// Maximum number of background preload jobs executing at once. Background
  /// work is bytes-only vector padding and adjacent-zoom preloading; it only
  /// starts when no foreground work is queued or active.
  static const int maxConcurrentBackgroundLoads = 2;

  final TileFetcher _fetcher;

  /// Turns fetched bytes into a [ui.Image] — the raster codec by default,
  /// the vector parse+render pipeline in vector mode.
  final TileDecoder _decoder;

  /// Prefix for all cache keys (memory, byte and Hive). Vector styles set
  /// this to the style id so their entries never collide with raster ones.
  final String cacheNamespace;

  // ── Grid geometry ───────────────────────────────────────────────────
  late int horizontalTileCount;
  late int verticalTileCount;
  late int leftColumnTilesLngIndex;
  late int topRowTilesLatIndex;
  late double leftColumnTilesCanvasX;
  late double topRowTilesCanvasY;

  // ── Center ──────────────────────────────────────────────────────────
  double centerTileLng = 0;
  double centerTileLat = 0;
  double centerCanvasX = 0;
  double centerCanvasY = 0;
  double width;
  double height;
  LatLng centerLatLng;
  int zoom;

  // ── Visible slots ───────────────────────────────────────────────────
  final List<Tile> _renderTiles = [];
  List<Tile> get renderTiles => _renderTiles;

  // ── Caches ──────────────────────────────────────────────────────────

  /// Decoded images for visible tiles. LRU via LinkedHashMap.
  final LinkedHashMap<String, ui.Image> _memoryCache = LinkedHashMap();

  /// Compressed PNG bytes for pre-loaded adjacent zoom tiles.
  /// Checked in [_scheduleLoad] for instant decode when a tile becomes visible.
  final LinkedHashMap<String, Uint8List> _byteCache = LinkedHashMap();
  int _byteCacheSize = 0;

  /// Tile keys currently being fetched or decoded.
  final Set<String> _inFlight = {};

  /// Tiles that failed recently; retried only after [failureBackoff].
  final Map<String, DateTime> _failedUntil = {};

  // ── Padding & pre-loading ───────────────────────────────────────────
  final int tilePadding;
  final bool preloadAdjacentZoom;

  /// Optional hard bounding box the camera can never leave. `null`
  /// disables the constraint.
  LatLngBounds? cameraBounds;

  /// When `true`, the off-screen padding ring is fetched as compressed
  /// bytes only and is **not** decoded until it enters the viewport.
  ///
  /// Vector mode sets this: a vector tile decode runs MVT parsing, ~74
  /// style-layer passes, path construction, and `Picture.toImage`, so
  /// decoding all 80 padded tiles at mode switch dominates the frame
  /// budget. Raster mode leaves it `false` because a raster decode is
  /// cheap and the padded images make panning instant.
  ///
  /// Visible tiles are always decoded immediately regardless of this
  /// flag. When a prefetched padding tile scrolls into view, the next
  /// `calculate()` finds its bytes in the byte cache and decodes on
  /// demand.
  final bool byteOnlyPadding;

  /// Debounce timer for adjacent zoom pre-loading.
  Timer? _preloadTimer;

  /// The zoom level that was last pre-loaded for.
  int _lastPreloadedZoom = -1;

  /// The tile coords of the center when pre-loading last ran.
  int _lastPreloadCenterX = 0;
  int _lastPreloadCenterY = 0;

  // ── Strict viewport (Phase 1) ───────────────────────────────────────
  //
  // [calculate] retains the un-padded viewport ranges so readiness checks
  // and the scheduler can distinguish tiles that must be decoded from the
  // padding ring that intentionally may stay as bytes only.

  int _visibleHorizontalCount = 0;
  int _visibleVerticalCount = 0;

  /// Keys of currently visible, valid-world slots.
  final Set<String> _visibleKeys = {};

  /// Grid signature used to bump [revision]/[generation] only when the
  /// camera or viewport geometry really changed.
  double _calcCenterLng = double.nan;
  double _calcCenterLat = double.nan;
  int _calcZoom = -1;
  double _calcWidth = double.nan;
  double _calcHeight = double.nan;

  // ── Generation-aware scheduler (Phase 2) ────────────────────────────
  //
  // All load work enters [_loadQueue] and is drained in priority order:
  // newer camera generation first, then visible > padding > adjacent
  // zoom, then nearest-to-center. Visible work has its own concurrency
  // gate and always runs ahead of background preloads.

  int _generation = 0;

  /// The current camera generation. Bumped whenever grid geometry changes.
  int get generation => _generation;

  final List<_LoadJob> _loadQueue = [];

  /// Keys that are queued but not yet executing.
  final Set<String> _queued = {};

  /// Foreground load jobs currently executing. Bounded by
  /// [maxConcurrentVisibleLoads]; background preloads are held back while
  /// this is nonzero so visible work never competes for sockets with
  /// padding/adjacent-zoom fetches.
  int _activeForegroundLoads = 0;

  /// Background preload jobs currently executing. Bounded by
  /// [maxConcurrentBackgroundLoads].
  int _activeBackgroundLoads = 0;

  // ── Presentation stage (split from resource fetching) ───────────────
  //
  // Resource jobs (disk/network) only acquire bytes and populate the byte
  // cache, then hand off to this separate, bounded presentation queue. The
  // resource permit is released as soon as bytes exist, so a new camera
  // generation can fetch its centre tiles without waiting behind an older
  // tile that is still rendering. Queued presentations are dropped on a
  // camera change without discarding already-downloaded bytes.

  /// Jobs that have bytes and are waiting for the decode lane.
  final List<_PresentJob> _presentQueue = [];

  /// Presentation jobs currently decoding.
  int _activePresentations = 0;

  /// Presentations run on the UI/raster budget independently of network
  /// fetches. Kept at the visible-fetch limit so raster coverage is not
  /// slowed; the vector runtime further gates its own lane (1 on web) and
  /// re-orders waiters by demand.
  static const int maxConcurrentPresentations = maxConcurrentVisibleLoads;

  /// Payload-versioned corruption recovery per canonical resource. A rejected
  /// payload keeps one shared recovery future until all presentations holding
  /// that payload drain, so stale siblings cannot invalidate its replacement.
  final Map<String, _CorruptResourceState> _corruptResources = {};

  /// Presentations currently inside [_present], used to retire corruption
  /// state only after no stale sibling can report the rejected payload.
  final Set<_PresentJob> _activePresentEntries = {};

  /// Stable identity token attached to each in-memory payload object.
  final Expando<Object> _payloadVersions = Expando<Object>();

  /// One-shot timers that re-enqueue a failed job after [failureBackoff],
  /// so retries no longer depend on a grid-rebuilding `calculate()`.
  final Map<String, Timer> _retryTimers = {};

  /// The latest (highest-priority) job descriptor seen for each key. Retry
  /// timers use this instead of the descriptor captured when the failure was
  /// scheduled, so a tile promoted from padding to visible is retried with
  /// its current generation/class/`byteOnly` rather than stale metadata.
  final Map<String, _LoadJob> _jobsByKey = {};

  // ── HTTP isolate (persistent background isolate for all network I/O) ─
  final HttpIsolate _httpIsolate = HttpIsolate();

  /// Builds a tile URL from coordinates. When set, network requests
  /// go through the HTTP isolate for TCP connection reuse. When null,
  /// falls back to the [_fetcher] function.
  final String Function(int z, int x, int y)? _urlBuilder;

  /// Builds the canonical source identity of a logical tile. When null a
  /// digest of the URL builder is used, then the wrapped logical coordinates.
  final TileResourceKeyBuilder? _resourceKeyBuilder;

  /// In-flight shared source fetches keyed by resource identity. A single
  /// resource future fans out to every logical slot waiting on it, so
  /// over-zoom siblings and wrapped-X duplicates download once.
  final Map<String, Future<Uint8List>> _resourceFetches = {};

  /// Resources whose bytes have been scheduled for persistent storage, so a
  /// resource shared by several logical slots produces one Hive write.
  final Set<String> _persistedResources = {};

  /// Writes currently committing. Legacy records await this exact future
  /// before deletion instead of treating a merely scheduled write as success.
  final Map<String, Future<bool>> _resourceWrites = {};

  /// Legacy logical disk key associated with bytes in [_byteCache]. Retained
  /// across aborts/transient decoder failures until canonical migration wins.
  final Map<String, String> _legacyDiskKeys = {};

  /// Upper bound on [_persistedResources] bookkeeping before it is reset.
  /// Resetting can cause a rare duplicate write, never a missing one.
  static const int _maxPersistedResourceKeys = 1024;

  // ── Lifecycle ───────────────────────────────────────────────────────
  bool _disposed = false;

  /// Grid/camera revision — bumped only when the visible grid geometry
  /// (center, zoom, or viewport size) changes.
  int _gridRevision = 0;

  /// Tile-content revision — bumped when a tile image is published.
  int _contentRevision = 0;

  /// Combined revision used by painters' `shouldRepaint`. Strictly
  /// increasing because both parts only ever increment.
  int get revision => _gridRevision + _contentRevision;

  int get gridRevision => _gridRevision;
  int get contentRevision => _contentRevision;

  /// True while a content-change notification is registered for the next
  /// frame. Completing many tiles in one frame produces one callback.
  bool _tileNotificationScheduled = false;

  VoidCallback? onTilesChanged;

  // ── Strict viewport readiness (Phase 1) ─────────────────────────────

  /// Number of tiles in the strict (un-padded) viewport that have no
  /// image yet. Padding and invalid world-Y cells are ignored, so a
  /// vector-mode padding ring that is intentionally bytes-only never
  /// blocks readiness.
  int get missingVisibleTileCount {
    if (_visibleHorizontalCount <= 0 || _visibleVerticalCount <= 0) return 0;
    final n = 1 << zoom;
    var missing = 0;
    for (var h = 0; h < _visibleHorizontalCount; h++) {
      final row = (h + tilePadding) * verticalTileCount;
      for (var v = 0; v < _visibleVerticalCount; v++) {
        final listIndex = row + tilePadding + v;
        if (listIndex >= _renderTiles.length) continue;
        final tile = _renderTiles[listIndex];
        if (tile.latIndex < 0 || tile.latIndex >= n) continue;
        if (tile.sourceTile == null) missing++;
      }
    }
    return missing;
  }

  /// `true` when every visible, valid-world slot has an image. Padding
  /// and off-world cells are ignored.
  bool get visibleTilesReady => missingVisibleTileCount == 0;

  /// Number of strict-viewport grid cells (including off-world rows).
  int get visibleTileCount => _visibleHorizontalCount * _visibleVerticalCount;

  /// Whether [z]/[x]/[y] still justifies the expensive decode of the
  /// current mode.
  ///
  /// In vector mode (`byteOnlyPadding == true`) only strict-viewport slots
  /// are decode-relevant: the padding ring is deliberately bytes-only, so a
  /// visible tile that scrolls into padding must abort before parse/render/
  /// `toImage` and must not publish an image or repaint. Raster mode keeps
  /// decoding its padded render set because raster decodes are cheap and the
  /// padded images make panning instant.
  bool isTileRelevant(int z, int x, int y) {
    final key = _key(z, x, y);
    if (byteOnlyPadding) return _visibleKeys.contains(key);
    return _renderIndex(key) != -1;
  }

  /// Presentation priority for [VectorTileRuntime]'s decode lane: higher
  /// values run first. Newer camera generations outrank older ones; within a
  /// generation visible tiles outrank padding, and nearer-centre tiles
  /// outrank the edge.
  ///
  /// Evaluated when the single presentation slot frees up, so a camera change
  /// re-ranks work that is already queued instead of letting the old FIFO
  /// order persist.
  int tileDecodePriority(int z, int x, int y) {
    final key = _key(z, x, y);
    final visible = _visibleKeys.contains(key);
    final inRender = _renderIndex(key) != -1;
    final classRank = visible ? 2 : (inRender ? 1 : 0);
    var proximity = 0;
    if (z == zoom) {
      final dx = (x + 0.5) - centerTileLng;
      final dy = (y + 0.5) - centerTileLat;
      proximity = (1000 / (1 + dx * dx + dy * dy)).round().clamp(0, 1000);
    }
    return _generation * 100000 + classRank * 10000 + proximity;
  }

  TileManager.init({
    required this.width,
    required this.height,
    required this.centerLatLng,
    required this.zoom,
    TileFetcher? fetcher,
    TileDecoder? decoder,
    String Function(int z, int x, int y)? urlBuilder,
    TileResourceKeyBuilder? resourceKeyBuilder,
    this.cacheNamespace = '',
    this.tilePadding = defaultTilePadding,
    this.preloadAdjacentZoom = true,
    this.byteOnlyPadding = false,
    this.preloadDebounce = const Duration(milliseconds: 500),
    this.cameraBounds,
  })  : _fetcher = fetcher ?? osmTileFetcher,
        _decoder = decoder ?? _decodeRasterTile,
        _urlBuilder = urlBuilder,
        _resourceKeyBuilder = resourceKeyBuilder {
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
    setCenterTile();

    // Spawn the HTTP isolate when a URL builder is provided so that
    // visible tile fetches and preloads use the persistent background
    // isolate (TCP connection reuse). On web this is a no-op.
    if (urlBuilder != null) {
      _httpIsolate.spawn();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _tileNotificationScheduled = false;
    _preloadTimer?.cancel();
    _preloadTimer = null;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _jobsByKey.clear();
    _resourceFetches.clear();
    _resourceWrites.clear();
    _legacyDiskKeys.clear();
    _httpIsolate.dispose();
    onTilesChanged = null;
    _renderTiles.clear();
    _inFlight.clear();
    _loadQueue.clear();
    _queued.clear();
    _visibleKeys.clear();
    _failedUntil.clear();
    _presentQueue.clear();
    _activePresentEntries.clear();
    _corruptResources.clear();
    _activeForegroundLoads = 0;
    _activeBackgroundLoads = 0;
    _activePresentations = 0;
    for (final image in _memoryCache.values) {
      image.dispose();
    }
    _memoryCache.clear();
    _byteCache.clear();
    _byteCacheSize = 0;
  }

  // ── Center helpers ──────────────────────────────────────────────────

  void setCenterTile({LatLng? latLng}) {
    if (latLng != null) centerLatLng = latLng;
    final lat = clampLatitude(centerLatLng.latitude);
    final lng = clampLongitude(centerLatLng.longitude);
    centerLatLng = LatLng(latitude: lat, longitude: lng);
    centerTileLng = lon2TileX(lng, zoom);
    centerTileLat = lat2TileY(lat, zoom);
    _clampTileCoords();
    final unclampedLng = centerTileLng;
    final unclampedLat = centerTileLat;
    _clampToCameraBounds();
    // Re-derive the geographic center only when the camera-bounds clamp
    // actually moved the camera, so an unconstrained setCenterTile keeps
    // the exact lat/lng it was given.
    if (centerTileLng != unclampedLng || centerTileLat != unclampedLat) {
      centerLatLng = LatLng(
        latitude: tileY2Lat(centerTileLat, zoom),
        longitude: tileX2Lng(centerTileLng, zoom),
      );
    }
  }

  void setCenterFromTileCoords(double tileLng, double tileLat) {
    final n = math.pow(2, zoom).toDouble();
    centerTileLng = tileLng.clamp(0.0, n);
    centerTileLat = tileLat.clamp(0.0, n);
    _clampToCameraBounds();
    centerLatLng = LatLng(
      latitude: tileY2Lat(centerTileLat, zoom),
      longitude: tileX2Lng(centerTileLng, zoom),
    );
  }

  void _clampTileCoords() {
    final n = math.pow(2, zoom).toDouble();
    centerTileLng = centerTileLng.clamp(0.0, n);
    centerTileLat = centerTileLat.clamp(0.0, n);
  }

  /// Constrains the camera center so the viewport never shows anything
  /// outside [cameraBounds] at the current zoom. When the bounds are
  /// smaller than the viewport, the camera pins to the bounds' center.
  void _clampToCameraBounds() {
    final bounds = cameraBounds;
    if (bounds == null) return;
    final minX = lon2TileX(bounds.west, zoom);
    final maxX = lon2TileX(bounds.east, zoom);
    final minY = lat2TileY(bounds.north, zoom); // north = smaller tile Y
    final maxY = lat2TileY(bounds.south, zoom);
    final halfW = width / (2 * tileWidth);
    final halfH = height / (2 * tileHeight);
    // Bounds smaller than viewport → pin to their center; else clamp.
    centerTileLng = (maxX - minX <= halfW * 2)
        ? (minX + maxX) / 2
        : centerTileLng.clamp(minX + halfW, maxX - halfW);
    centerTileLat = (maxY - minY <= halfH * 2)
        ? (minY + maxY) / 2
        : centerTileLat.clamp(minY + halfH, maxY - halfH);
  }

  /// Sets the hard camera constraint to [bounds] (`null` frees the
  /// camera) and snaps the current camera inside it if it was outside.
  void setCameraBounds(LatLngBounds? bounds) {
    cameraBounds = bounds;
    _clampToCameraBounds();
    centerLatLng = LatLng(
      latitude: tileY2Lat(centerTileLat, zoom),
      longitude: tileX2Lng(centerTileLng, zoom),
    );
    calculate();
  }

  /// Projects a geographic point to viewport-local pixels under the
  /// current camera (center + zoom). Valid for the frame in which it is
  /// called — pan/zoom update the camera continuously.
  Offset latLngToScreen(LatLng point) {
    final tileX = lon2TileX(point.longitude, zoom);
    final tileY = lat2TileY(point.latitude, zoom);
    return Offset(
      (tileX - centerTileLng) * tileWidth + centerCanvasX,
      (tileY - centerTileLat) * tileHeight + centerCanvasY,
    );
  }

  void resize(Size size) {
    width = size.width;
    height = size.height;
    centerCanvasX = width / 2;
    centerCanvasY = height / 2;
    final unclampedLng = centerTileLng;
    final unclampedLat = centerTileLat;
    _clampToCameraBounds();
    if (centerTileLng != unclampedLng || centerTileLat != unclampedLat) {
      centerLatLng = LatLng(
        latitude: tileY2Lat(centerTileLat, zoom),
        longitude: tileX2Lng(centerTileLng, zoom),
      );
    }
  }

  void setZoom(int newZoom) {
    if (newZoom == zoom) return;
    zoom = newZoom;
    setCenterTile();
    calculate();
  }

  void setZoomWithFocalPoint(int newZoom, Offset focalLocal, int oldZoom) {
    if (newZoom == zoom || newZoom == oldZoom) return;

    final focalTileLng =
        centerTileLng + (focalLocal.dx - centerCanvasX) / tileWidth;
    final focalTileLat =
        centerTileLat + (focalLocal.dy - centerCanvasY) / tileHeight;
    final focalLng = tileX2Lng(focalTileLng, oldZoom);
    final focalLat = tileY2Lat(focalTileLat, oldZoom);

    final newFocalTileLng = lon2TileX(focalLng, newZoom);
    final newFocalTileLat = lat2TileY(focalLat, newZoom);

    final newCenterTileLng =
        newFocalTileLng - (focalLocal.dx - centerCanvasX) / tileWidth;
    final newCenterTileLat =
        newFocalTileLat - (focalLocal.dy - centerCanvasY) / tileHeight;

    zoom = newZoom;
    setCenterFromTileCoords(newCenterTileLng, newCenterTileLat);
    calculate();
  }

  // ── Grid computation ────────────────────────────────────────────────

  /// Rebuilds the visible tile grid. Cheap and synchronous — call on
  /// every pan frame.
  ///
  /// Recalculation is idempotent and has a real unchanged-grid fast path:
  /// when the camera/zoom/viewport geometry has not moved it returns
  /// immediately without clearing the grid, recreating jobs, sorting, or
  /// pumping the scheduler. Tile completions update the existing grid in
  /// place, and failure/backoff retries are driven by timers, so neither
  /// needs a recalculation to make progress.
  ///
  /// Only an actual geometry change bumps [revision]/[generation] and
  /// rebuilds.
  void calculate() {
    if (_disposed) return;

    final gridChanged = _calcCenterLng != centerTileLng ||
        _calcCenterLat != centerTileLat ||
        _calcZoom != zoom ||
        _calcWidth != width ||
        _calcHeight != height;
    _calcCenterLng = centerTileLng;
    _calcCenterLat = centerTileLat;
    _calcZoom = zoom;
    _calcWidth = width;
    _calcHeight = height;
    if (!gridChanged) return;
    _generation++;

    final centerPointTileX = (centerTileLng % 1) * tileWidth;
    final centerPointTileY = (centerTileLat % 1) * tileHeight;

    final centerCanvasTileX = centerCanvasX - centerPointTileX;
    final centerCanvasTileY = centerCanvasY - centerPointTileY;

    final leftColumnsBeforeCenterCount = (centerCanvasTileX / tileWidth).ceil();
    leftColumnTilesCanvasX =
        centerCanvasTileX - leftColumnsBeforeCenterCount * tileWidth;

    final topRowsBeforeCenterCount = (centerCanvasTileY / tileHeight).ceil();
    topRowTilesCanvasY =
        centerCanvasTileY - topRowsBeforeCenterCount * tileHeight;

    final centerTileLngIndex = centerTileLng.floor();
    leftColumnTilesLngIndex = centerTileLngIndex - leftColumnsBeforeCenterCount;

    final centerTileLatIndex = centerTileLat.floor();
    topRowTilesLatIndex = centerTileLatIndex - topRowsBeforeCenterCount;

    horizontalTileCount =
        ((width + -leftColumnTilesCanvasX) / tileWidth).ceil();
    verticalTileCount = ((height + -topRowTilesCanvasY) / tileHeight).ceil();

    // Capture the strict (un-padded) viewport ranges before expansion so
    // readiness checks and the scheduler can tell visible slots from the
    // padding ring that intentionally may never decode in vector mode.
    _visibleHorizontalCount = horizontalTileCount;
    _visibleVerticalCount = verticalTileCount;

    final visibleHCount = horizontalTileCount;
    final visibleVCount = verticalTileCount;

    // Expand by [tilePadding] on each side.
    final paddedHCount = horizontalTileCount + 2 * tilePadding;
    final paddedVCount = verticalTileCount + 2 * tilePadding;
    final paddedLeftLng = leftColumnTilesLngIndex - tilePadding;
    final paddedTopLat = topRowTilesLatIndex - tilePadding;
    final paddedLeftCanvasX = leftColumnTilesCanvasX - tilePadding * tileWidth;
    final paddedTopCanvasY = topRowTilesCanvasY - tilePadding * tileHeight;

    horizontalTileCount = paddedHCount;
    verticalTileCount = paddedVCount;
    leftColumnTilesLngIndex = paddedLeftLng;
    topRowTilesLatIndex = paddedTopLat;
    leftColumnTilesCanvasX = paddedLeftCanvasX;
    topRowTilesCanvasY = paddedTopCanvasY;

    _renderTiles.clear();
    _visibleKeys.clear();

    // Build the render list and collect the work to schedule. Jobs carry
    // the current generation and a priority class so the scheduler can
    // keep visible tiles ahead of padding/preloads.
    final pending = <_LoadJob>[];
    final bytePreload = <_LoadJob>[];

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;
      final isPaddingH =
          hIndex < tilePadding || hIndex >= tilePadding + visibleHCount;
      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileLatIndex = topRowTilesLatIndex + vIndex;
        final isPaddingV =
            vIndex < tilePadding || vIndex >= tilePadding + visibleVCount;
        final isPadding = isPaddingH || isPaddingV;
        final key = _key(zoom, tileLngIndex, tileLatIndex);

        if (!isPadding && _isValidWorld(zoom, tileLatIndex)) {
          _visibleKeys.add(key);
        }

        // Synchronous memory-cache hit → no flicker.
        final cached = _memoryCache.remove(key);
        if (cached != null) {
          _memoryCache[key] = cached; // refresh LRU
          _renderTiles.add(Tile(cached, key, tileLatIndex, tileLngIndex));
          continue;
        }

        _renderTiles.add(Tile(null, key, tileLatIndex, tileLngIndex));
        // Squared distance from center (no sqrt needed for ordering).
        final dx = tileLngIndex - centerTileLng;
        final dy = tileLatIndex - centerTileLat;
        final dist = dx * dx + dy * dy;

        final job = _LoadJob(
          key: key,
          resourceKey: _resourceKey(zoom, tileLngIndex, tileLatIndex),
          z: zoom,
          x: tileLngIndex,
          y: tileLatIndex,
          generation: _generation,
          jobClass: isPadding ? _JobClass.padding : _JobClass.visible,
          distance: dist,
          byteOnly: isPadding && byteOnlyPadding,
        );

        if (job.byteOnly) {
          // Off-screen padding ring in vector mode: fetch bytes only,
          // do not decode. Decoded later when the tile scrolls into view.
          bytePreload.add(job);
        } else {
          pending.add(job);
        }
      }
    }

    // Drop queued jobs that are no longer on screen (stale after a pan or
    // zoom), then enqueue the current work and drain in priority order.
    _pruneStaleQueue();
    _prunePresentQueue();
    for (final job in pending) {
      _enqueueJob(job);
    }
    for (final job in bytePreload) {
      _enqueueJob(job);
    }

    _trimMemoryCache();

    _gridRevision++;

    _pumpLoadQueue();

    // Debounce adjacent zoom pre-loading — only after user stops panning.
    if (preloadAdjacentZoom) {
      _scheduleAdjacentZoomPreloadDebounced();
    }
  }

  // ── Async tile loading (generation-aware priority scheduler) ────────

  /// Orders queued jobs: newest generation first, then visible > padding
  /// > adjacent zoom, then nearest to the viewport center.
  static int _compareJobs(_LoadJob a, _LoadJob b) {
    if (a.generation != b.generation) {
      return b.generation.compareTo(a.generation);
    }
    final cls = a.jobClass.index.compareTo(b.jobClass.index);
    if (cls != 0) return cls;
    return a.distance.compareTo(b.distance);
  }

  /// Adds [job] to the priority queue unless it is already in flight,
  /// invalid, or backed off after a failure.
  ///
  /// If the same key is already queued, the job is upgraded in place when
  /// the new one has higher priority (newer generation, more visible class,
  /// or closer to center). That promotes a padding tile that became visible
  /// instead of leaving it with its stale generation and priority.
  void _enqueueJob(_LoadJob job) {
    if (_disposed) return;
    if (!_isValidWorld(job.z, job.y)) return;
    // Record the newest descriptor even when the job is already in flight so
    // a pending retry timer can pick up the promoted priority.
    _registerLatestJob(job);
    if (_inFlight.contains(job.key)) return;
    // Byte-only work is already done once its bytes are cached; re-enqueueing
    // it would trigger a redundant network request after a pan.
    if (job.byteOnly &&
        (_byteCache.containsKey(job.resourceKey) ||
            _memoryCache.containsKey(job.key))) {
      _removeQueued(job.key);
      return;
    }
    final failedUntil = _failedUntil[job.key];
    if (failedUntil != null) {
      if (DateTime.now().isBefore(failedUntil)) {
        // Retry after the backoff even if an unchanged grid never calls
        // [calculate] again.
        _scheduleRetry(job, failedUntil.difference(DateTime.now()));
        return;
      }
      _failedUntil.remove(job.key);
    }

    final existingIndex = _queueIndex(job.key);
    if (existingIndex != -1) {
      final existing = _loadQueue[existingIndex];
      if (_compareJobs(job, existing) < 0) {
        _loadQueue[existingIndex] = job;
      }
      return;
    }
    _queued.add(job.key);
    _loadQueue.add(job);
  }

  /// Keeps [_jobsByKey] pointing at the highest-priority descriptor seen for
  /// a key. Retries read this map so they never replay stale metadata.
  void _registerLatestJob(_LoadJob job) {
    final existing = _jobsByKey[job.key];
    if (existing == null || _compareJobs(job, existing) < 0) {
      _jobsByKey[job.key] = job;
    }
  }

  /// Removes [key] from the pending queue, if present.
  void _removeQueued(String key) {
    if (!_queued.remove(key)) return;
    _loadQueue.removeWhere((job) => job.key == key);
  }

  int _queueIndex(String key) => _loadQueue.indexWhere((job) => job.key == key);

  /// Removes queued jobs that no longer belong to the current camera
  /// generation.
  ///
  /// Non-background jobs are dropped when their tile leaves the render set.
  /// Adjacent-zoom preloads normally target off-screen tiles, but a new
  /// generation drops them: a camera move must not keep launching more
  /// background jobs from the previous generation.
  void _pruneStaleQueue() {
    if (_loadQueue.isEmpty) return;
    _loadQueue.removeWhere((job) {
      if (job.jobClass == _JobClass.adjacentZoom) {
        if (job.generation != _generation) {
          _queued.remove(job.key);
          _jobsByKey.remove(job.key);
          return true;
        }
        return false;
      }
      final relevant = _renderIndex(job.key) != -1;
      if (!relevant) {
        _queued.remove(job.key);
        _jobsByKey.remove(job.key);
      }
      return !relevant;
    });
  }

  /// A foreground job is required to complete the current viewport: a
  /// visible slot, or a padding slot that decodes (raster mode). Background
  /// jobs (vector byte-only padding and adjacent-zoom preloads) are preloads
  /// that may wait.
  static bool _isForeground(_LoadJob job) =>
      job.jobClass == _JobClass.visible ||
      (job.jobClass == _JobClass.padding && !job.byteOnly);

  /// Starts queued jobs, most important first.
  ///
  /// Foreground jobs are bounded by [maxConcurrentVisibleLoads]; the rest
  /// stay queued so a newer generation can take the next freed slot instead
  /// of sitting behind dozens of older requests. Background preloads only
  /// run when no foreground work is queued or active, and are bounded by
  /// [maxConcurrentBackgroundLoads].
  void _pumpLoadQueue() {
    if (_disposed || _loadQueue.isEmpty) return;
    _loadQueue.sort(_compareJobs);

    final foregroundPending = _loadQueue.any(_isForeground);
    final backgroundBlocked = foregroundPending || _activeForegroundLoads > 0;
    var foregroundSlots = maxConcurrentVisibleLoads - _activeForegroundLoads;

    final keep = <_LoadJob>[];
    for (final job in _loadQueue) {
      if (_isForeground(job)) {
        if (foregroundSlots > 0) {
          foregroundSlots--;
          _queued.remove(job.key);
          _activeForegroundLoads++;
          unawaited(_runJob(job, foreground: true));
        } else {
          keep.add(job);
        }
      } else if (backgroundBlocked ||
          _activeBackgroundLoads >= maxConcurrentBackgroundLoads) {
        keep.add(job);
      } else {
        _queued.remove(job.key);
        _activeBackgroundLoads++;
        unawaited(_runJob(job, foreground: false));
      }
    }
    _loadQueue
      ..clear()
      ..addAll(keep);
  }

  Future<void> _runJob(_LoadJob job, {required bool foreground}) async {
    var presenting = false;
    try {
      if (_disposed) return;
      _inFlight.add(job.key);
      // Resource stage only: acquire bytes (disk/network) or cache a
      // bytes-only preload. The decode runs later on the presentation lane,
      // so this permit frees as soon as the bytes exist.
      presenting = await _acquireBytes(job);
    } finally {
      // Keep the key in flight while a presentation is outstanding so a
      // duplicate resource job is not started for the same slot.
      if (!presenting) _inFlight.remove(job.key);
      if (foreground) {
        if (_activeForegroundLoads > 0) _activeForegroundLoads--;
      } else {
        if (_activeBackgroundLoads > 0) _activeBackgroundLoads--;
      }
      if (!_disposed) _pumpLoadQueue();
    }
  }

  /// Records a failure and schedules a retry after [failureBackoff] so a
  /// retry no longer depends on a grid-rebuilding `calculate()`.
  void _markFailed(_LoadJob job) {
    if (_disposed) return;
    final until = DateTime.now().add(failureBackoff);
    _failedUntil[job.key] = until;
    _scheduleRetry(job, failureBackoff);
  }

  void _scheduleRetry(_LoadJob job, Duration delay) {
    if (_disposed || _retryTimers.containsKey(job.key)) return;
    final wait = delay.isNegative ? Duration.zero : delay;
    _retryTimers[job.key] = Timer(wait, () {
      _retryTimers.remove(job.key);
      if (_disposed) return;
      _failedUntil.remove(job.key);
      // Retry with the newest descriptor for this key, not the one captured
      // when the failure was scheduled — a padding preload may have been
      // promoted to a visible foreground decode in the meantime.
      final latest = _jobsByKey[job.key] ?? job;
      if (!_shouldRetry(latest)) return;
      _enqueueJob(latest);
      _pumpLoadQueue();
    });
  }

  /// Whether a failed [job] is still worth retrying.
  bool _shouldRetry(_LoadJob job) {
    if (_inFlight.contains(job.key) || _queued.contains(job.key)) return false;
    if (_memoryCache.containsKey(job.key)) return false;
    if (job.byteOnly && _byteCache.containsKey(job.resourceKey)) return false;
    if (job.jobClass != _JobClass.adjacentZoom && _renderIndex(job.key) == -1) {
      return false;
    }
    return true;
  }

  /// Resource stage: resolves compressed bytes for [job] into the byte
  /// cache without decoding, then hands off to the presentation lane.
  ///
  /// Returns `true` when a presentation was scheduled (the caller keeps the
  /// key in flight), `false` when the resource is complete, failed, or no
  /// longer needed.
  Future<bool> _acquireBytes(_LoadJob job) async {
    if (_disposed) return false;
    // The tile may have scrolled off screen between queueing and starting.
    // Adjacent-zoom preloads target tiles outside the render set on purpose,
    // so they bypass this check.
    if (job.jobClass != _JobClass.adjacentZoom && _renderIndex(job.key) == -1) {
      return false;
    }

    if (job.byteOnly) {
      return _acquireBytesOnly(job);
    }

    // Source bytes live under the shared resource key; the rendered image is
    // still published per logical slot by `_complete`.
    final resource = job.resourceKey;

    // 1. Join an existing payload-versioned recovery. Even after the shared
    //    fetch settles, stale siblings holding the rejected bytes continue to
    //    see this state and can neither refetch nor invalidate the replacement.
    final corrupt = _corruptResources[resource];
    if (corrupt != null) {
      try {
        final recovered = corrupt.replacementBytes ??
            await _recoverCorruptResource(job, corrupt);
        if (_disposed) return false;
        return _schedulePresentation(
          job,
          bytes: recovered,
          origin: _ByteOrigin.network,
          diskKey: _legacyDiskKeys[resource],
        );
      } catch (_) {
        _markFailed(job);
        return false;
      }
    }

    // 2. Byte cache hit — hand straight to the presentation lane, preserving
    //    any legacy provenance discovered by an earlier aborted attempt.
    final cachedBytes = _byteCache[resource];
    if (cachedBytes != null) {
      return _schedulePresentation(
        job,
        bytes: cachedBytes,
        origin: _ByteOrigin.cached,
        diskKey: _legacyDiskKeys[resource],
      );
    }

    // 3. Disk cache — canonical resource key first, then the legacy logical
    //    slot key written by older versions. A legacy record is rewritten
    //    under the canonical key after a successful decode.
    var diskKey = resource;
    if (!hasStoredTile(diskKey)) {
      final legacy = _key(job.z, job.x, job.y);
      if (legacy != resource && hasStoredTile(legacy)) {
        diskKey = legacy;
      }
    }
    if (hasStoredTile(diskKey)) {
      Uint8List? bytes;
      try {
        bytes = await storedTileBytes(diskKey);
      } catch (_) {
        bytes = null;
      }
      if (_disposed) return false;
      if (bytes == null || bytes.isEmpty) {
        // Missing/corrupt persistent record — delete it and re-download.
        await _deleteStored(diskKey);
      } else {
        _ensureBytesCached(resource, bytes);
        final legacyKey = diskKey == resource ? null : diskKey;
        if (legacyKey != null) _legacyDiskKeys[resource] = legacyKey;
        return _schedulePresentation(
          job,
          bytes: bytes,
          origin: _ByteOrigin.cached,
          diskKey: legacyKey,
        );
      }
    }

    // 4. Network.
    return _fetchNetwork(job);
  }

  /// Fetches bytes from the network into the byte cache and schedules a
  /// presentation. Bytes are not persisted until a presentation confirms
  /// they decode, so a malformed download never reaches disk.
  Future<bool> _fetchNetwork(_LoadJob job) async {
    final resource = job.resourceKey;
    late final Uint8List bytes;
    try {
      bytes = await _fetchResource(job);
    } catch (_) {
      _markFailed(job);
      return false;
    }
    if (_disposed) return false;
    _ensureBytesCached(resource, bytes);
    return _schedulePresentation(
      job,
      bytes: bytes,
      origin: _ByteOrigin.network,
    );
  }

  /// Returns the one recovery fetch for [state]. The completed replacement is
  /// retained until every presentation of [state.rejectedBytes] has drained.
  Future<Uint8List> _recoverCorruptResource(
    _LoadJob job,
    _CorruptResourceState state,
  ) {
    final existing = state.recovery;
    if (existing != null) return existing;

    late final Future<Uint8List> future;
    future = _fetchResource(job).then((bytes) {
      if (!_disposed && identical(_corruptResources[job.resourceKey], state)) {
        state.replacementBytes = bytes;
        _storeInByteCache(job.resourceKey, bytes);
      }
      return bytes;
    }, onError: (Object error, StackTrace stack) {
      if (identical(state.recovery, future)) state.recovery = null;
      Error.throwWithStackTrace(error, stack);
    });
    state.recovery = future;
    return future;
  }

  /// Resource stage for a bytes-only preload. Off-screen bytes are cached
  /// (and persisted) without a decode; a tile that scrolled into view while
  /// preloading is handed to the presentation lane instead.
  Future<bool> _acquireBytesOnly(_LoadJob job) async {
    final resource = job.resourceKey;
    final cached = _byteCache[resource];
    if (cached != null) {
      if (!isTileRelevant(job.z, job.x, job.y)) return false;
      return _schedulePresentation(
        _promote(job),
        bytes: cached,
        origin: _ByteOrigin.cached,
      );
    }

    Uint8List? diskBytes;
    if (hasStoredTile(resource)) {
      try {
        diskBytes = cachedTileBytes(resource);
      } catch (_) {
        diskBytes = null;
      }
    }

    late final Uint8List bytes;
    final _ByteOrigin origin;
    if (diskBytes != null && diskBytes.isNotEmpty) {
      bytes = diskBytes;
      origin = _ByteOrigin.cached;
    } else {
      try {
        bytes = await _fetchResource(job);
      } catch (_) {
        _markFailed(job);
        return false;
      }
      if (_disposed) return false;
      origin = _ByteOrigin.network;
    }
    _ensureBytesCached(resource, bytes);

    // Still off-screen: cache the bytes without spending a decode.
    if (!isTileRelevant(job.z, job.x, job.y)) {
      unawaited(_persistResource(job, bytes));
      return false;
    }

    // The tile scrolled into view while preloading: present it.
    return _schedulePresentation(
      _promote(job),
      bytes: bytes,
      origin: origin,
    );
  }

  /// Promotes a bytes-only preload to the foreground decode descriptor used
  /// when the tile becomes visible.
  _LoadJob _promote(_LoadJob job) {
    final foreground = _foregroundJob(job);
    _registerLatestJob(foreground);
    return foreground;
  }

  /// Queues [job] for the bounded presentation lane. Assumes its bytes are
  /// already in the byte cache.
  bool _schedulePresentation(
    _LoadJob job, {
    required Uint8List bytes,
    required _ByteOrigin origin,
    String? diskKey,
  }) {
    if (_disposed) return false;
    // A resource that finished after the camera moved keeps its bytes but
    // must not occupy the newest presentation queue.
    if (job.jobClass != _JobClass.adjacentZoom && _renderIndex(job.key) == -1) {
      return false;
    }
    _presentQueue.add(
      _PresentJob(
        job: job,
        bytes: bytes,
        payloadId: _payloadVersion(bytes),
        origin: origin,
        diskKey: diskKey,
      ),
    );
    _pumpPresentations();
    return true;
  }

  /// Starts queued presentations, newest/highest-priority first. The lane is
  /// bounded by [maxConcurrentPresentations] so decode CPU cannot flood the
  /// UI isolate.
  void _pumpPresentations() {
    if (_disposed) return;
    if (_presentQueue.isEmpty) return;
    _presentQueue.sort((a, b) => _compareJobs(a.job, b.job));
    while (_activePresentations < maxConcurrentPresentations &&
        _presentQueue.isNotEmpty) {
      final entry = _presentQueue.removeAt(0);
      final job = entry.job;
      if (job.jobClass != _JobClass.adjacentZoom &&
          _renderIndex(job.key) == -1) {
        _inFlight.remove(job.key);
        continue;
      }
      _activePresentations++;
      unawaited(_runPresentation(entry));
    }
  }

  Future<void> _runPresentation(_PresentJob entry) async {
    var refetch = false;
    _activePresentEntries.add(entry);
    try {
      refetch = await _present(entry);
    } finally {
      _activePresentEntries.remove(entry);
      if (_activePresentations > 0) _activePresentations--;
      _inFlight.remove(entry.job.key);
      if (!_disposed) {
        if (refetch) _enqueueJob(_promote(entry.job));
        _retireCorruptStateIfDrained(entry.job.resourceKey);
        _pumpPresentations();
        _pumpLoadQueue();
      }
    }
  }

  /// Decodes and publishes one presentation.
  ///
  /// Returns `true` when the bytes were cached/disk bytes found to be
  /// malformed and a single network refetch should be forced.
  Future<bool> _present(_PresentJob entry) async {
    if (_disposed) return false;
    final job = entry.job;
    final resource = job.resourceKey;
    final outcome = await _tryDecode(job, entry.bytes);
    switch (outcome) {
      case _DecodeOutcome.ok:
        // Canonical persistence is part of migration's commit point. Delete a
        // legacy entry only after that exact write succeeds.
        final persisted = await _persistResource(job, entry.bytes);
        final legacyKey = entry.diskKey ?? _legacyDiskKeys[resource];
        if (persisted && legacyKey != null) {
          await _deleteStored(legacyKey);
          if (_legacyDiskKeys[resource] == legacyKey) {
            _legacyDiskKeys.remove(resource);
          }
        }
        final recovery = _corruptResources[resource];
        if (recovery != null &&
            !identical(entry.payloadId, recovery.rejectedPayloadId)) {
          recovery
            ..replacementBytes = entry.bytes
            ..replacementAccepted = true;
        }
        return false;
      case _DecodeOutcome.aborted:
        return false;
      case _DecodeOutcome.error:
        _markFailed(job);
        return false;
      case _DecodeOutcome.corrupt:
        var recovery = _corruptResources[resource];
        if (recovery == null) {
          recovery = _CorruptResourceState(
            rejectedPayloadId: entry.payloadId,
            rejectedBytes: entry.bytes,
          );
          _corruptResources[resource] = recovery;
        } else if (!identical(
          entry.payloadId,
          recovery.rejectedPayloadId,
        )) {
          // Only the known replacement may advance the recovery generation.
          // An unrelated stale sibling must never replace current state.
          if (identical(entry.bytes, recovery.replacementBytes)) {
            recovery
              ..rejectedPayloadId = entry.payloadId
              ..rejectedBytes = entry.bytes
              ..replacementBytes = null
              ..replacementAccepted = false
              ..recovery = null
              ..persistentInvalidated = false;
          } else {
            return false;
          }
        }

        if (identical(_byteCache[resource], entry.bytes)) {
          _removeFromByteCache(resource);
        }
        if (!recovery.persistentInvalidated) {
          recovery.persistentInvalidated = true;
          await _deleteStored(resource);
          final legacyKey = entry.diskKey ?? _legacyDiskKeys[resource];
          if (legacyKey != null) await _deleteStored(legacyKey);
        }

        if (entry.origin == _ByteOrigin.network) {
          // The recovery response itself was malformed. Back off before a new
          // shared recovery generation; siblings of this payload only join.
          _markFailed(job);
          return false;
        }
        return true;
    }
  }

  /// Drops queued presentations whose tiles left the newest demand set,
  /// releasing their in-flight keys. Downloaded bytes are retained.
  void _prunePresentQueue() {
    if (_presentQueue.isEmpty) return;
    _presentQueue.removeWhere((entry) {
      final job = entry.job;
      final stale = job.jobClass == _JobClass.adjacentZoom
          ? job.generation != _generation
          : _renderIndex(job.key) == -1;
      if (stale) _inFlight.remove(job.key);
      return stale;
    });
  }

  Object _payloadVersion(Uint8List bytes) =>
      _payloadVersions[bytes] ??= Object();

  void _retireCorruptStateIfDrained(String resource) {
    final state = _corruptResources[resource];
    if (state == null || !state.replacementAccepted) return;
    final rejectedStillQueued = _presentQueue.any((entry) =>
        entry.job.resourceKey == resource &&
        identical(entry.payloadId, state.rejectedPayloadId));
    final rejectedStillActive = _activePresentEntries.any((entry) =>
        entry.job.resourceKey == resource &&
        identical(entry.payloadId, state.rejectedPayloadId));
    if (!rejectedStillQueued && !rejectedStillActive) {
      _corruptResources.remove(resource);
    }
  }

  Future<void> _deleteStored(String key) async {
    // Allow a later successful fetch to re-persist this resource.
    _persistedResources.remove(key);
    try {
      await deleteStoredTile(key);
    } catch (_) {
      // Best-effort: a failed delete must not block the network retry.
    }
  }

  /// Decodes [bytes] and publishes the tile when it is still relevant.
  ///
  /// Outcome classification:
  /// - [TileDecodeAborted] → [aborted]: stale work; keep the bytes, no
  ///   backoff.
  /// - [TilePayloadException] → [corrupt]: these bytes can never render;
  ///   callers invalidate the cache/disk entry and recover from the network.
  /// - Any other exception → [error]: the decoder failed for a reason that
  ///   says nothing about the payload (style/render/runtime). The bytes are
  ///   kept and retried rather than deleted and refetched.
  Future<_DecodeOutcome> _tryDecode(_LoadJob job, Uint8List bytes) async {
    if (_disposed) return _DecodeOutcome.aborted;
    // Cheap pre-gate: never even enter the decoder for a tile that is no
    // longer relevant (e.g. a stale raster tile that left the render set, or
    // a visible vector tile that moved into the bytes-only padding ring).
    if (!isTileRelevant(job.z, job.x, job.y)) {
      return _DecodeOutcome.aborted;
    }
    try {
      final image = await _decoder(bytes, job.z, job.x, job.y);
      if (_disposed) {
        image.dispose();
        return _DecodeOutcome.aborted;
      }
      // The camera may have moved while decoding. In vector mode padding is
      // not decode-relevant, so a former visible tile that moved into the
      // padding ring must not publish an image or repaint.
      if (!isTileRelevant(job.z, job.x, job.y)) {
        image.dispose();
        return _DecodeOutcome.aborted;
      }
      _complete(job.key, Tile(image, job.key, job.y, job.x));
      return _DecodeOutcome.ok;
    } on TileDecodeAborted {
      // Stale work stopped itself before parse/render/toImage. Keep any
      // bytes already fetched; this is not a failure.
      return _DecodeOutcome.aborted;
    } on TilePayloadException {
      return _DecodeOutcome.corrupt;
    } catch (_) {
      return _DecodeOutcome.error;
    }
  }

  /// Stores [bytes] under [resource] only when it is not already present, so
  /// a resource shared by many logical slots produces one memory insertion.
  void _ensureBytesCached(String resource, Uint8List bytes) {
    if (_byteCache.containsKey(resource)) return;
    _storeInByteCache(resource, bytes);
  }

  /// Commits one persistent write per resource. Concurrent callers share the
  /// exact write future so compatibility migration never deletes a legacy
  /// record before the canonical write has actually succeeded.
  Future<bool> _persistResource(_LoadJob job, Uint8List bytes) {
    final resource = job.resourceKey;
    if (_persistedResources.contains(resource)) return Future.value(true);
    final inFlight = _resourceWrites[resource];
    if (inFlight != null) return inFlight;

    late final Future<bool> write;
    write = (() async {
      try {
        await storeTile(
          resource,
          Tile(null, resource, job.y, job.x),
          bytes,
        );
        if (_disposed) return false;
        _persistedResources.add(resource);
        if (_persistedResources.length > _maxPersistedResourceKeys) {
          _persistedResources
            ..clear()
            ..add(resource);
        }
        return true;
      } catch (_) {
        return false;
      } finally {
        if (identical(_resourceWrites[resource], write)) {
          _resourceWrites.remove(resource);
        }
      }
    })();
    _resourceWrites[resource] = write;
    return write;
  }

  /// Fetches the shared source bytes for [job], deduplicating concurrent
  /// requests for the same resource. Over-zoom siblings and wrapped-X
  /// duplicates await one in-flight future instead of downloading once per
  /// logical slot; the first caller supplies the coordinates the fetcher
  /// resolves.
  Future<Uint8List> _fetchResource(_LoadJob job) {
    final resource = job.resourceKey;
    final existing = _resourceFetches[resource];
    if (existing != null) return existing;

    // Forward through a completer so the raw fetch future always has an
    // error handler attached; a shared failure is then delivered only to
    // the logical slots that await this resource.
    final completer = Completer<Uint8List>();
    _resourceFetches[resource] = completer.future;
    _fetchBytes(job.z, job.x, job.y).then(
      (bytes) {
        // Publish the bytes to the shared memory cache *before* clearing the
        // in-flight entry. A slot enqueued while the first logical decoder is
        // still running then reads these bytes instead of starting a
        // duplicate request.
        if (!_disposed) _storeInByteCache(resource, bytes);
        _resourceFetches.remove(resource);
        if (!completer.isCompleted) completer.complete(bytes);
      },
      onError: (Object error, StackTrace stack) {
        // Drop the in-flight entry so a retry can refetch.
        _resourceFetches.remove(resource);
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    return completer.future;
  }

  /// Converts a bytes-only preload descriptor into the foreground decode
  /// descriptor used when the tile becomes visible.
  static _LoadJob _foregroundJob(_LoadJob job) => _LoadJob(
        key: job.key,
        resourceKey: job.resourceKey,
        z: job.z,
        x: job.x,
        y: job.y,
        generation: job.generation,
        jobClass: _JobClass.visible,
        distance: job.distance,
        byteOnly: false,
      );

  Future<Uint8List> _fetchBytes(int z, int x, int y) {
    if (_httpIsolate.isReady && _urlBuilder != null) {
      // Use persistent HTTP isolate (native) — reuses TCP connections.
      return _httpIsolate.fetchUrl(_urlBuilder!(z, x, y));
    }
    // Fall back to fetcher (web or custom).
    return _fetcher(z, x, y);
  }

  void _complete(String key, Tile tile) {
    _inFlight.remove(key);
    _jobsByKey.remove(key);
    if (_disposed || tile.sourceTile == null) return;

    _memoryCache.remove(key);
    _memoryCache[key] = tile.sourceTile!;
    _trimMemoryCache();

    final i = _renderIndex(key);
    if (i == -1) return;
    if (_renderTiles[i].sourceTile != null) return;

    _renderTiles[i] = tile;
    _contentRevision++;
    _scheduleTileNotification();
  }

  /// Coalesces tile-completion notifications to one callback per frame.
  ///
  /// Completion still updates [_renderTiles] and [revision] synchronously so
  /// an unrelated rebuild sees the new tile; only the listener callback is
  /// deferred, so progressive arrivals cannot trigger a full map rebuild and
  /// label collision pass per tile.
  void _scheduleTileNotification() {
    if (_disposed || onTilesChanged == null) return;
    if (_tileNotificationScheduled) return;
    _tileNotificationScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _tileNotificationScheduled = false;
      if (_disposed) return;
      onTilesChanged?.call();
    });
  }

  // ── Adjacent zoom pre-loading (debounced, bytes-only) ───────────────

  /// Schedules adjacent zoom pre-loading with a debounce timer.
  /// Only fires after the user stops panning for [preloadDebounce].
  void _scheduleAdjacentZoomPreloadDebounced() {
    // If debounce is zero, run immediately (useful for tests).
    if (preloadDebounce == Duration.zero) {
      _checkAndPreload();
      return;
    }

    _preloadTimer?.cancel();

    final cx = centerTileLng.floor();
    final cy = centerTileLat.floor();
    if (_lastPreloadedZoom == zoom &&
        _lastPreloadCenterX == cx &&
        _lastPreloadCenterY == cy) {
      return;
    }

    _preloadTimer = Timer(preloadDebounce, () {
      if (!_disposed) _runAdjacentZoomPreload();
    });
  }

  /// Check if center has moved; if so, run preload immediately.
  void _checkAndPreload() {
    final cx = centerTileLng.floor();
    final cy = centerTileLat.floor();
    if (_lastPreloadedZoom == zoom &&
        _lastPreloadCenterX == cx &&
        _lastPreloadCenterY == cy) {
      return;
    }
    _runAdjacentZoomPreload();
  }

  /// Actually runs the pre-loading. Called only after the debounce timer
  /// fires (user has stopped panning).
  void _runAdjacentZoomPreload() {
    if (_disposed) return;

    _lastPreloadedZoom = zoom;
    _lastPreloadCenterX = centerTileLng.floor();
    _lastPreloadCenterY = centerTileLat.floor();

    // Visible area (before padding).
    final visibleLeftLng = leftColumnTilesLngIndex + tilePadding;
    final visibleTopLat = topRowTilesLatIndex + tilePadding;
    final visibleHCount = (horizontalTileCount - 2 * tilePadding).clamp(0, 100);
    final visibleVCount = (verticalTileCount - 2 * tilePadding).clamp(0, 100);

    // Only preload ±1 zoom (±2 creates 1000+ tiles that compete with
    // visible tile fetches and freeze the UI, especially in vector mode).
    // Priority: closest zoom levels first.
    final zoomDeltas = <int>[];
    for (final dz in [1, -1]) {
      final z = zoom + dz;
      if (z >= 0 && z <= 19) zoomDeltas.add(dz);
    }

    // Bound how many adjacent-zoom preloads a single run enqueues (the
    // next idle debounce enqueues more). Without this cap a low zoom or
    // large viewport would queue hundreds of background fetches at once.
    var enqueued = 0;

    outer:
    for (final dz in zoomDeltas) {
      final z = zoom + dz;
      // For zoom-in (dz > 0), one tile at current zoom maps to 2^dz × 2^dz tiles at target zoom.
      // For zoom-out (dz < 0), multiple tiles at current zoom map to one tile at target zoom.
      final tileMultiplier = dz > 0 ? (1 << dz) : 1;

      for (var h = 0; h < visibleHCount; h++) {
        for (var v = 0; v < visibleVCount; v++) {
          final lngIndex = visibleLeftLng + h;
          final latIndex = visibleTopLat + v;

          // Map this tile's top-left corner to the target zoom.
          final lng = tileX2Lng(lngIndex.toDouble(), zoom);
          final lat = tileY2Lat(latIndex.toDouble(), zoom);
          final otherX = lon2TileX(lng, z).floor();
          final otherY = lat2TileY(lat, z).floor();

          // Load all tiles that cover this geographic area at target zoom.
          for (var dx = 0; dx < tileMultiplier; dx++) {
            for (var dy = 0; dy < tileMultiplier; dy++) {
              final tx = otherX + dx;
              final ty = otherY + dy;
              final key = _key(z, tx, ty);

              // Skip if already cached, in-flight, or queued. The memory
              // cache is per slot; source bytes are per resource.
              if (_memoryCache.containsKey(key)) continue;
              if (_byteCache.containsKey(_resourceKey(z, tx, ty))) continue;
              if (_inFlight.contains(key)) continue;
              if (_queued.contains(key)) continue;
              if (ty < 0 || ty >= (1 << z)) continue;

              if (enqueued >= maxConcurrentPreloads) break outer;
              _preloadTile(key, z, tx, ty);
              enqueued++;
            }
          }
        }
      }
    }

    _pumpLoadQueue();
  }

  /// Enqueues a background, bytes-only preload for an adjacent-zoom tile.
  ///
  /// Preloads never decode and never notify [onTilesChanged] — they only
  /// populate the byte/disk cache so a later zoom decodes instantly. The
  /// scheduler gives preloads the lowest priority and holds them back
  /// while any visible work is queued or active.
  void _preloadTile(String key, int z, int x, int y) {
    _enqueueJob(_LoadJob(
      key: key,
      resourceKey: _resourceKey(z, x, y),
      z: z,
      x: x,
      y: y,
      generation: _generation,
      jobClass: _JobClass.adjacentZoom,
      distance: 0,
      byteOnly: true,
    ));
  }

  // ── Relevance helpers ───────────────────────────────────────────────

  /// Whether [y] is a real world row at [z]. Off-world padding rows can
  /// never load and must never block readiness or be scheduled.
  bool _isValidWorld(int z, int y) => y >= 0 && y < (1 << z);

  int _renderIndex(String key) =>
      _renderTiles.indexWhere((t) => t.index == key);

  void _removeFromByteCache(String key) {
    final old = _byteCache.remove(key);
    if (old != null) _byteCacheSize -= old.length;
  }

  // ── Byte cache management ───────────────────────────────────────────

  void _storeInByteCache(String key, Uint8List bytes) {
    final old = _byteCache.remove(key);
    if (old != null) _byteCacheSize -= old.length;

    _byteCache[key] = bytes;
    _byteCacheSize += bytes.length;
    _trimByteCache();
  }

  void _trimByteCache() {
    while (_byteCacheSize > maxByteCacheBytes && _byteCache.isNotEmpty) {
      final oldestKey = _byteCache.keys.first;
      final oldestBytes = _byteCache.remove(oldestKey);
      if (oldestBytes != null) _byteCacheSize -= oldestBytes.length;
    }
  }

  // ── Memory cache management ─────────────────────────────────────────

  void _trimMemoryCache() {
    while (_memoryCache.length > maxMemoryCachedTiles) {
      final oldestKey = _memoryCache.keys.first;
      final image = _memoryCache.remove(oldestKey);
      final visible = _renderTiles.any((t) => t.index == oldestKey);
      if (!visible) image?.dispose();
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  /// Namespaced slot key — the rendered-image identity (`z/x/y`, or
  /// `style/z/x/y` in vector mode). Each logical slot keeps its own image
  /// because over-zoom children render different sub-rects.
  String _key(int z, int x, int y) =>
      cacheNamespace.isEmpty ? '$z/$x/$y' : '$cacheNamespace/$z/$x/$y';

  /// Canonical source identity of the logical tile at [z]/[x]/[y].
  ///
  /// Source bytes (network, byte cache, disk) are keyed by this instead of
  /// the slot key so wrapped-X duplicates and over-zoom siblings share one
  /// download and one stored record. It is prefixed with [cacheNamespace]
  /// so a source record never leaks across styles.
  String _resourceKey(int z, int x, int y) {
    final String raw;
    final builder = _resourceKeyBuilder;
    if (builder != null) {
      // Vector sources provide an opaque source-id + resolved coordinate.
      raw = builder(z, x, y);
    } else if (_urlBuilder != null) {
      // Never persist the raw URL: a query string can carry an API token.
      // A digest of the credential-free URL keeps the resource identity
      // public while still invalidating when scheme/host/path changes.
      raw = _digestUrl(_urlBuilder!(z, x, y));
    } else {
      // Opaque coordinate identity: wraps X so antimeridian duplicates share,
      // without encoding any URL.
      raw = '$z/${_wrapX(z, x)}/$y';
    }
    return cacheNamespace.isEmpty ? raw : '$cacheNamespace|$raw';
  }

  /// Exposes the canonical resource key for tests.
  @visibleForTesting
  String resourceKeyFor(int z, int x, int y) => _resourceKey(z, x, y);

  static int _wrapX(int z, int x) {
    final n = 1 << z;
    return ((x % n) + n) % n;
  }

  /// Stable digest of the public URL identity.
  ///
  /// Content-affecting query parameters are retained in sorted order while
  /// credentials and request-signing fields are removed. The digest therefore
  /// distinguishes public variants such as `style=dark`/`style=light` without
  /// persisting secrets or changing when a token rotates.
  static String _digestUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'u${_fnv1a64(url)}';

    final publicQuery = <String, List<String>>{};
    final keys = uri.queryParametersAll.keys.toList()..sort();
    for (final key in keys) {
      if (_isCredentialQueryParameter(key)) continue;
      publicQuery[key] = List<String>.of(uri.queryParametersAll[key]!)..sort();
    }
    final public = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
      queryParameters: publicQuery.isEmpty ? null : publicQuery,
    ).toString();
    return 'u${_fnv1a64(public)}';
  }

  static bool _isCredentialQueryParameter(String name) {
    final lower = name.toLowerCase();
    return lower == 'access_token' ||
        lower == 'access-token' ||
        lower == 'token' ||
        lower == 'api_key' ||
        lower == 'api-key' ||
        lower == 'apikey' ||
        lower == 'key' ||
        lower == 'signature' ||
        lower == 'sig' ||
        lower == 'expires' ||
        lower.startsWith('x-amz-') ||
        lower.startsWith('x-goog-');
  }

  /// FNV-1a 64-bit implemented with [BigInt] so the exact same 16-hex-digit
  /// key is produced by native and JavaScript backends. This preserves all
  /// cache keys written by the previous native integer implementation.
  static String _fnv1a64(String value) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String tileKey(int z, int x, int y) => '$z/$x/$y';

  /// Raster default decoder: the bytes are an encoded image. A codec failure
  /// means the payload is malformed, so it is reported as
  /// [TilePayloadException] for the caller to invalidate and refetch.
  static Future<ui.Image> _decodeRasterTile(
    Uint8List bytes,
    int z,
    int x,
    int y,
  ) async {
    try {
      return await Tile.decodeImage(bytes);
    } catch (error) {
      throw TilePayloadException('$error');
    }
  }
}

/// Result of attempting to decode a job's bytes.
enum _DecodeOutcome {
  /// Decoded and published.
  ok,

  /// The tile went stale before publishing. Bytes are valid and retained.
  aborted,

  /// The decoder reported [TilePayloadException]: these bytes are malformed
  /// and must be invalidated and refetched.
  corrupt,

  /// The decoder threw for a reason unrelated to the payload
  /// (style/render/runtime). Keep the bytes and retry after backoff.
  error,
}

/// Priority class for a scheduled load. Lower index wins within the same
/// camera generation.
enum _JobClass {
  /// Strict-viewport tile that must decode to be displayed.
  visible,

  /// Off-screen padding ring (decoded in raster mode, bytes-only in
  /// vector mode).
  padding,

  /// Adjacent zoom level preload (bytes only).
  adjacentZoom,
}

/// A unit of tile loading work. Carries the camera [generation] that
/// requested it and the [jobClass]/[distance] used for priority ordering.
class _LoadJob {
  /// Logical slot key — rendered-image identity.
  final String key;

  /// Canonical source identity shared with sibling slots.
  final String resourceKey;

  final int z;
  final int x;
  final int y;
  final int generation;
  final _JobClass jobClass;

  /// Squared distance from the viewport center (ordering only).
  final double distance;

  /// When `true`, only source bytes are fetched — no decode.
  final bool byteOnly;

  const _LoadJob({
    required this.key,
    required this.resourceKey,
    required this.z,
    required this.x,
    required this.y,
    required this.generation,
    required this.jobClass,
    required this.distance,
    required this.byteOnly,
  });
}

/// Where presentation bytes came from. Only matters for corruption
/// recovery: cached/disk bytes are invalidated and refetched once, while a
/// malformed network response backs off rather than looping.
enum _ByteOrigin { cached, network }

/// A job whose bytes are already in the byte cache and which is waiting for
/// the bounded presentation lane to decode and publish it.
class _PresentJob {
  final _LoadJob job;

  /// Compressed bytes to decode. Already present in the byte cache; held
  /// here so the presentation never re-reads a mutated cache entry.
  final Uint8List bytes;

  /// Identity of the byte payload, shared by every sibling presentation.
  final Object payloadId;

  final _ByteOrigin origin;

  /// Persistent key the bytes were read from when they came from disk. When
  /// it differs from the canonical resource key the entry is a compatible
  /// legacy record that is migrated after a successful decode.
  final String? diskKey;

  const _PresentJob({
    required this.job,
    required this.bytes,
    required this.payloadId,
    required this.origin,
    this.diskKey,
  });
}

/// Recovery state for one rejected source payload. [recovery] and its settled
/// [replacementBytes] are shared by every logical over-zoom/wrapped sibling.
class _CorruptResourceState {
  Object rejectedPayloadId;
  Uint8List rejectedBytes;
  Future<Uint8List>? recovery;
  Uint8List? replacementBytes;
  bool replacementAccepted = false;
  bool persistentInvalidated = false;

  _CorruptResourceState({
    required this.rejectedPayloadId,
    required this.rejectedBytes,
  });
}
