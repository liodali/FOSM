/// Point-in-time strict-viewport coverage of one map, for workload
/// measurement: time to first/all covered cells, time to sharp coverage
/// (current-zoom imagery rather than zoom-fallback crops) and the blank
/// fraction over time during cold loads.
///
/// "Covered" counts a strict-viewport cell that shows imagery: either its
/// grid slot published its own image, or the per-region zoom fallback is
/// painting retained ancestor/descendant imagery over it. "Sharp" counts a
/// cell whose own current-zoom rendered image is retained. A cell can be
/// covered but not sharp while zoom-fallback imagery stands in for a
/// missing current-zoom tile; a cell that is neither shows the
/// checkerboard placeholder (blank).
///
/// Two coverage granularities are reported because they answer different
/// questions and can diverge at partial viewport-edge cells:
///
/// - **Cell-count coverage** (`coveredFraction`/`sharpFraction`): the
///   fraction of visible grid *cells*, each weighted equally however much
///   of the viewport it intersects. Cheap and stable, but a single huge
///   partial cell counts the same as a sliver.
/// - **Pixel-area coverage** (`coveredAreaFraction`/`sharpAreaFraction`):
///   the fraction of visible *viewport pixels* behind covered/sharp cells,
///   weighting each cell by its intersection with the viewport rectangle.
///
/// Cell identities (`visibleCellIds`/`coveredCellIds`/`sharpCellIds`) are
/// the grid cell keys — namespaced in vector mode, so a style switch
/// presents an entirely new cell set. Harnesses use them to distinguish
/// cells newly exposed during motion from cells that were visible all
/// along: time-to-sharp is only meaningful per exposure.
///
/// An empty grid (no layout yet, or no valid visible cells) reports the
/// count fractions as 1 so a not-yet-started map never looks 100% blank;
/// `visibleCells == 0` is the explicit signal to skip the sample rather
/// than read the fractions.
class FosmTileCoverage {
  const FosmTileCoverage({
    required this.visibleCells,
    required this.coveredCells,
    required this.sharpCells,
    this.visibleCellIds = const <String>{},
    this.coveredCellIds = const <String>{},
    this.sharpCellIds = const <String>{},
    this.visibleAreaPx = 0,
    this.coveredAreaPx = 0,
    this.sharpAreaPx = 0,
  })  : assert(visibleCells >= 0),
        assert(coveredCells >= 0 && coveredCells <= visibleCells),
        assert(sharpCells >= 0 && sharpCells <= visibleCells);

  /// A map with no calculated grid yet (everything reports as covered so
  /// a not-yet-started map never looks like 100% blank).
  const FosmTileCoverage.empty()
      : visibleCells = 0,
        coveredCells = 0,
        sharpCells = 0,
        visibleCellIds = const <String>{},
        coveredCellIds = const <String>{},
        sharpCellIds = const <String>{},
        visibleAreaPx = 0,
        coveredAreaPx = 0,
        sharpAreaPx = 0;

  /// Strict-viewport cells with a valid world row. Off-world rows (poles)
  /// and padding cells are excluded — they can never load imagery.
  final int visibleCells;

  /// Visible cells showing imagery: their own published image or
  /// zoom-fallback imagery (never the checkerboard).
  final int coveredCells;

  /// Visible cells with a retained current-zoom rendered image.
  final int sharpCells;

  /// Identities of the visible cells (namespaced grid keys in vector
  /// mode). Empty when the producer does not track them.
  final Set<String> visibleCellIds;

  /// Identities of the covered cells (subset of [visibleCellIds]).
  final Set<String> coveredCellIds;

  /// Identities of the sharp cells (subset of [coveredCellIds]).
  final Set<String> sharpCellIds;

  /// Viewport pixels behind valid visible cells (the pixel-area coverage
  /// denominator). Partial edge cells contribute their intersecting area.
  final double visibleAreaPx;

  /// Viewport pixels behind covered cells.
  final double coveredAreaPx;

  /// Viewport pixels behind sharp cells.
  final double sharpAreaPx;

  int get missingCells => visibleCells - coveredCells;

  /// Visible cells still served by fallback imagery or blank.
  int get sharpMissingCells => visibleCells - sharpCells;

  /// Every valid visible cell shows some imagery.
  bool get allCovered => visibleCells == 0 || coveredCells >= visibleCells;

  /// Every valid visible cell shows its own current-zoom image.
  bool get allSharp => visibleCells == 0 || sharpCells >= visibleCells;

  /// Fraction of valid visible cells with any imagery (own or fallback);
  /// 1 for an empty grid. `1 - coveredFraction` is the blank cell
  /// fraction.
  double get coveredFraction =>
      visibleCells == 0 ? 1 : coveredCells / visibleCells;

  /// Fraction of valid visible cells with sharp imagery; 1 for an empty
  /// grid. `1 - sharpFraction` counts blank plus fallback-covered cells.
  double get sharpFraction =>
      visibleCells == 0 ? 1 : sharpCells / visibleCells;

  /// Fraction of visible viewport pixels behind covered cells; 1 for an
  /// empty grid (mirrors [coveredFraction]'s convention).
  double get coveredAreaFraction =>
      visibleAreaPx == 0 ? 1 : coveredAreaPx / visibleAreaPx;

  /// Fraction of visible viewport pixels behind sharp cells; 1 for an
  /// empty grid.
  double get sharpAreaFraction =>
      visibleAreaPx == 0 ? 1 : sharpAreaPx / visibleAreaPx;

  @override
  String toString() =>
      'FosmTileCoverage(visible: $visibleCells, covered: $coveredCells, '
      'sharp: $sharpCells)';
}
