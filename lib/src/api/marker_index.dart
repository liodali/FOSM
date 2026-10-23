import '../common/osm_transformation_utilities.dart';
import 'marker.dart';

/// One indexed [Marker] with its cached normalized Web-Mercator coordinates.
///
/// `nx`/`ny` are zoom-independent world coordinates (`lon2TileX(lng, 0)` /
/// `lat2TileY(lat, 0)`): the expensive trigonography runs once per marker
/// instance ([Marker.point] is immutable), and every per-frame projection
/// — to screen pixels or to clustering world pixels at any zoom — reduces
/// to an exact power-of-two scaling of these cached values.
class MarkerIndexEntry {
  const MarkerIndexEntry(this.marker, this.nx, this.ny, this.seq);

  final Marker marker;

  /// Normalized world X: `(lng + 180) / 360`. In `[0, 1]` for longitudes in
  /// [-180, 180]; kept unwrapped outside that range so off-world markers
  /// project exactly like a direct [Marker.point] projection would.
  final double nx;

  /// Normalized world Y: `lat2TileY(lat, 0)`. In `[0, 1]` for latitudes
  /// inside the Web Mercator range.
  final double ny;

  /// Insertion sequence number; queries return entries oldest first.
  final int seq;

  /// Non-finite projections (for example the south pole) remain in the
  /// collection, but cannot be assigned a grid cell or drawn on the map.
  bool get isProjectable => nx.isFinite && ny.isFinite;
}

/// Uniform-grid geographic index over a marker collection.
///
/// The world (normalized Mercator units, `[0, 1]²`) is divided into
/// [gridSide] × [gridSide] cells. Insertion, removal and `removeWhere`
/// maintain the grid incrementally — insertion costs O(1) amortized
/// (plus one-time projection); removals and bulk filtering cost O(n).
/// Every mutation is expected to be paired with a [MarkerManager] revision
/// bump, so
/// consumers can reason about index freshness via the revision alone.
///
/// Semantics intentionally mirror the plain [List] the manager exposes:
/// - Entries keep insertion order (see [entries], [queryRect]).
/// - The same marker instance may be inserted more than once; removal
///   removes the first occurrence, matching [List.remove].
/// - Identity comparison (markers do not override `==`).
class MarkerIndex {
  /// Cells per axis. One cell spans `1/gridSide` of the world — about one
  /// viewport at zoom 10 — which keeps viewport queries to a handful of
  /// cells across the supported zoom range.
  static const int gridSide = 256;

  static const double _cellSize = 1.0 / gridSide;

  /// Ordered entries, oldest first — the authoritative insertion order.
  final List<MarkerIndexEntry> _ordered = [];

  /// First entry per marker identity — coordinates of any duplicate are
  /// identical ([Marker.point] is final), so one entry serves lookups.
  final Map<Marker, MarkerIndexEntry> _first = {};

  /// Cell (x, y) → entries, in insertion order within each cell.
  final Map<(int, int), List<MarkerIndexEntry>> _cells = {};

  int _seq = 0;

  /// Number of indexed entries (counting duplicates).
  int get length => _ordered.length;

  bool get isEmpty => _ordered.isEmpty;

  bool get isNotEmpty => _ordered.isNotEmpty;

  /// All entries in insertion order. Do not mutate; internal use.
  List<MarkerIndexEntry> get entries => _ordered;

  /// Whether [marker] (by identity) is present.
  bool contains(Marker marker) => _first.containsKey(marker);

  /// Cached coordinates for [marker], or null when absent. For duplicated
  /// markers this returns the first entry — coordinates are identical.
  MarkerIndexEntry? operator [](Marker marker) => _first[marker];

  static (int, int) _cellOf(double nx, double ny) =>
      ((nx / _cellSize).floor(), (ny / _cellSize).floor());

  /// Appends [marker] with its projected coordinates.
  void insert(Marker marker) {
    final entry = MarkerIndexEntry(
      marker,
      lon2TileX(marker.point.longitude, 0),
      lat2TileY(marker.point.latitude, 0),
      _seq++,
    );
    // Compute the cell before publishing the entry to any lookup. A pole
    // can project to infinity; retain its list/identity semantics without
    // trying to floor that coordinate into a grid cell.
    final cell = entry.isProjectable ? _cellOf(entry.nx, entry.ny) : null;
    _ordered.add(entry);
    if (cell != null) _cells.putIfAbsent(cell, () => []).add(entry);
    _first.putIfAbsent(marker, () => entry);
  }

  /// Appends every marker of [markers] in iteration order.
  void insertAll(Iterable<Marker> markers) {
    for (final marker in markers) {
      insert(marker);
    }
  }

  /// Removes the first occurrence of [marker] (by identity), matching
  /// [List.remove]. Returns whether an entry was removed.
  bool remove(Marker marker) {
    // O(n) identity scan — same cost class as the previous plain-list
    // removal. Typical hot paths (clear/removeWhere) avoid per-marker
    // scans.
    final entryCount = _ordered.length;
    for (var i = 0; i < entryCount; i++) {
      if (identical(_ordered[i].marker, marker)) {
        _removeAt(i);
        return true;
      }
    }
    return false;
  }

  /// Removes every entry whose marker matches [test]. Returns the number
  /// of removed entries.
  int removeWhere(bool Function(Marker marker) test) {
    // Evaluate in list order, then commit in one pass. Repeated _removeAt
    // calls would rescan remaining identities and shift bucket lists for
    // each removed entry, making fleet updates quadratic.
    final kept = <MarkerIndexEntry>[];
    for (final entry in _ordered) {
      if (!test(entry.marker)) kept.add(entry);
    }
    final removed = _ordered.length - kept.length;
    if (removed == 0) return 0;
    _ordered
      ..clear()
      ..addAll(kept);
    _first.clear();
    _cells.clear();
    for (final entry in kept) {
      _first.putIfAbsent(entry.marker, () => entry);
      if (entry.isProjectable) {
        _cells.putIfAbsent(_cellOf(entry.nx, entry.ny), () => []).add(entry);
      }
    }
    return removed;
  }

  void clear() {
    _ordered.clear();
    _first.clear();
    _cells.clear();
  }

  void _removeAt(int index) {
    final entry = _ordered.removeAt(index);
    if (entry.isProjectable) {
      final cell = _cellOf(entry.nx, entry.ny);
      final cellEntries = _cells[cell];
      if (cellEntries != null) {
        cellEntries.remove(entry);
        if (cellEntries.isEmpty) _cells.remove(cell);
      }
    }
    if (identical(_first[entry.marker], entry)) {
      // A duplicate instance may still be present; hand the lookup over
      // to the next remaining entry of the same marker, if any.
      MarkerIndexEntry? next;
      for (final other in _ordered) {
        if (identical(other.marker, entry.marker)) {
          next = other;
          break;
        }
      }
      if (next != null) {
        _first[entry.marker] = next;
      } else {
        _first.remove(entry.marker);
      }
    }
  }

  /// Entries whose cached coordinates lie inside the given normalized
  /// world rectangle, in insertion order.
  ///
  /// The cell scan is coarse (cell granularity); callers do the exact
  /// boundary test on the returned candidates. [slack] pads the query
  /// rectangle so floating-point boundary cases can never drop a marker
  /// an exact screen-space test would keep.
  List<MarkerIndexEntry> queryRect(
    double minNx,
    double minNy,
    double maxNx,
    double maxNy, {
    double slack = 1e-7,
  }) {
    final results = <MarkerIndexEntry>[];

    final cellMinX = ((minNx - slack) / _cellSize).floor();
    final cellMaxX = ((maxNx + slack) / _cellSize).floor();
    final cellMinY = ((minNy - slack) / _cellSize).floor();
    final cellMaxY = ((maxNy + slack) / _cellSize).floor();

    // Whole-world (or wider) queries scan the ordered list directly —
    // cheaper than visiting every existing cell and sorting afterwards.
    if (cellMinX <= 0 &&
        cellMaxX >= gridSide - 1 &&
        cellMinY <= 0 &&
        cellMaxY >= gridSide - 1) {
      for (final entry in _ordered) {
        if (_inRect(entry, minNx, minNy, maxNx, maxNy, slack)) {
          results.add(entry);
        }
      }
      return results;
    }

    var contributingCells = 0;

    for (var cy = cellMinY; cy <= cellMaxY; cy++) {
      for (var cx = cellMinX; cx <= cellMaxX; cx++) {
        final cellEntries = _cells[(cx, cy)];
        if (cellEntries == null) continue;
        var cellMatched = 0;
        for (final entry in cellEntries) {
          if (_inRect(entry, minNx, minNy, maxNx, maxNy, slack)) {
            results.add(entry);
            cellMatched++;
          }
        }
        if (cellMatched > 0) contributingCells++;
      }
    }

    // Entries within a cell are already in insertion order; a single
    // contributing cell needs no sort. (The whole-world path above
    // iterates the ordered list and never sorts.)
    if (contributingCells > 1) {
      results.sort((a, b) => a.seq.compareTo(b.seq));
    }
    return results;
  }

  static bool _inRect(
    MarkerIndexEntry entry,
    double minNx,
    double minNy,
    double maxNx,
    double maxNy,
    double slack,
  ) {
    return entry.nx >= minNx - slack &&
        entry.nx <= maxNx + slack &&
        entry.ny >= minNy - slack &&
        entry.ny <= maxNy + slack;
  }
}
