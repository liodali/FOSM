# FOSM example

Interactive demo app for the [FOSM](../README.md) map library — a full-screen
map with a modern [forui](https://forui.dev) interface (shadcn/ui-inspired,
Lucide icons, Inter typeface) in light and dark themes.

## Run

```sh
flutter pub get
flutter run          # from this directory; pick any connected device
```

Requires Flutter 3.50+ / Dart 3.14+ (forui 0.28). The demo starts over Zurich
in raster (OpenStreetMap) mode. No API keys are needed: vector tiles come
from [OpenFreeMap](https://openfreemap.org) and the routing demo uses the
public OSRM server.

## What's inside

- **Raster ↔ Vector tabs** in the top bar; the camera survives the switch.
- **Vector style presets** — Liberty, Bright, Dark, Positron — plus any custom
  MapLibre style URL (settings sheet → Vector style).
- **Markers** — pins, text markers, tap-to-open info overlays, and 40 demo
  points around Zurich with **clustering** (custom count badges). Long-press
  the map to drop a pin; long-press a center-added pin to remove it.
- **Routing demo** — the route tool fetches an OSRM route from the current
  map center to Zurich HB, frames it with `fitBounds`, and shows a result
  card with distance/duration, solid/dashed/dotted style cycling, and clear.
- **Camera tools** — hard camera bounds toggle, fly-to Paris, fractional
  zoom, momentum panning, mouse-wheel zoom, zoom animation style
  (scale/crossfade), and a distance scale bar.
- **Simulated location** — a GPS track walking a circle near Zurich with
  follow/recenter behavior (settings sheet → Location).
- **Appearance** — light / system / dark switch; the forui theme and the
  Material theme used by FOSM's built-in controls stay in sync.

## UI stack

The chrome is built from forui widgets: `FTheme` (neutral theme, touch and
desktop variants), `FScaffold`, `FCard`-based floating panels, `FTabs`,
`FButton`/`FButton.icon`, `FTileGroup` + `FTile` + `FSwitch` settings rows,
`FTextField`, `FBadge`, `FTooltip`, `showFSheet`, and `showFToast`.

FOSM's built-in map controls (zoom, location, scale bar) are Material-based,
so the app derives their theme with `FThemeData.toApproximateMaterialTheme()`
and provides a transparent `Material` ancestor over the map.

## Layout

```
lib/
├── main.dart                    # App entry, forui + Material theme wiring
└── src/
    ├── demo_settings.dart       # Shared settings model + style presets
    ├── map_demo_page.dart       # Map page: camera, markers, routing demo
    └── widgets/
        ├── map_chrome.dart      # Floating panels, tool buttons, cards
        └── settings_sheet.dart  # Settings sheet (tiles, switches, toggles)
```

The benchmark harnesses under `lib/benchmark/` and `tool/` are separate
entry points used by the performance scripts in `docs/`; they are not part
of the demo UI.

## Tests

```sh
flutter test
```

`test/demo_ui_test.dart` covers the demo chrome and settings sheet with a
stub tile fetcher (no network); `test/widget_test.dart` covers `MapView`
gestures and zoom controls.
