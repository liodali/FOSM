import 'package:fosm/fosm.dart';
import 'package:material_ui/material_ui.dart';

/// App-wide theme mode, switchable from the settings sheet's Appearance
/// section.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

/// Tile rendering mode demonstrated by the app.
enum MapMode { raster, vector }

/// OpenFreeMap style presets offered in the settings sheet.
const List<({String label, String url})> mapStylePresets = [
  (label: 'Liberty', url: 'https://tiles.openfreemap.org/styles/liberty'),
  (label: 'Bright', url: 'https://tiles.openfreemap.org/styles/bright'),
  (label: 'Dark', url: 'https://tiles.openfreemap.org/styles/dark'),
  (label: 'Positron', url: 'https://tiles.openfreemap.org/styles/positron'),
];

/// Mutable demo configuration shared by the map page and the settings sheet.
///
/// A [ChangeNotifier] so both trees rebuild from a single source of truth —
/// no manual page/sheet state synchronization.
class DemoSettings extends ChangeNotifier {
  MapMode mode = MapMode.raster;
  String styleUrl = mapStylePresets.first.url;

  bool animateZoom = true;
  bool fractionalZoom = true;
  bool enableFling = true;
  bool enableScrollZoom = true;
  bool showScaleBar = true;
  bool clustering = true;
  bool simulateLocation = false;
  ZoomAnimationStyle zoomStyle = ZoomAnimationStyle.scale;

  /// Applies [mutate] and notifies listeners once.
  void edit(void Function(DemoSettings settings) mutate) {
    mutate(this);
    notifyListeners();
  }
}
