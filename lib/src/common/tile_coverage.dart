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
class FosmTileCoverage {
  const FosmTileCoverage({
    required this.visibleCells,
    required this.coveredCells,
    required this.sharpCells,
  })  : assert(visibleCells >= 0),
        assert(coveredCells >= 0 && coveredCells <= visibleCells),
        assert(sharpCells >= 0 && sharpCells <= visibleCells);

  /// A map with no calculated grid yet (everything reports as covered so
  /// a not-yet-started map never looks like 100% blank).
  const FosmTileCoverage.empty()
      : visibleCells = 0,
        coveredCells = 0,
        sharpCells = 0;

  /// Strict-viewport cells with a valid world row. Off-world rows (poles)
  /// and padding cells are excluded — they can never load imagery.
  final int visibleCells;

  /// Visible cells showing imagery: their own published image or
  /// zoom-fallback imagery (never the checkerboard).
  final int coveredCells;

  /// Visible cells with a retained current-zoom rendered image.
  final int sharpCells;

  int get missingCells => visibleCells - coveredCells;

  /// Visible cells still served by fallback imagery or blank.
  int get sharpMissingCells => visibleCells - sharpCells;

  /// Every valid visible cell shows some imagery.
  bool get allCovered => visibleCells == 0 || coveredCells >= visibleCells;

  /// Every valid visible cell shows its own current-zoom image.
  bool get allSharp => visibleCells == 0 || sharpCells >= visibleCells;

  /// Fraction of valid visible cells with any imagery (own or fallback);
  /// 1 for an empty grid. `1 - coveredFraction` is the blank fraction.
  double get coveredFraction =>
      visibleCells == 0 ? 1 : coveredCells / visibleCells;

  /// Fraction of valid visible cells with sharp imagery; 1 for an empty
  /// grid. `1 - sharpFraction` counts blank plus fallback-covered area.
  double get sharpFraction => visibleCells == 0 ? 1 : sharpCells / visibleCells;

  @override
  String toString() =>
      'FosmTileCoverage(visible: $visibleCells, covered: $coveredCells, '
      'sharp: $sharpCells)';
}
