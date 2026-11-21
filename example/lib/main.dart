import 'package:flutter/foundation.dart';
import 'package:forui/forui.dart';
import 'package:fosm/fosm.dart';
import 'package:material_ui/material_ui.dart';

import 'package:example/src/demo_settings.dart';
import 'package:example/src/map_demo_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initMap();
  runApp(const FosmDemoApp());
}

/// Root of the FOSM demo — a full-screen map with a
/// [forui](https://forui.dev) (shadcn/ui-inspired) interface in light & dark.
class FosmDemoApp extends StatelessWidget {
  const FosmDemoApp({super.key, this.home});

  /// Start page; overridable so tests can inject a stub tile fetcher.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    final touch = const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    }.contains(defaultTargetPlatform);
    // FTheme.neutral caches its platform variants, so repeated builds reuse
    // identical theme instances (FTheme relies on equality to avoid flicker).
    final light = touch
        ? FTheme.neutral.light.touch
        : FTheme.neutral.light.desktop;
    final dark = touch
        ? FTheme.neutral.dark.touch
        : FTheme.neutral.dark.desktop;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'FOSM Demo',
        debugShowCheckedModeBanner: false,
        supportedLocales: FLocalizations.supportedLocales,
        localizationsDelegates: FLocalizations.localizationsDelegates,
        themeMode: mode,
        // Keep the Material widgets inside FOSM's built-in controls themed
        // consistently with the forui chrome.
        theme: light.toApproximateMaterialTheme(),
        darkTheme: dark.toApproximateMaterialTheme(),
        builder: (context, child) => FTheme(
          data: Theme.brightnessOf(context) == Brightness.light ? light : dark,
          child: FToaster(child: FTooltipGroup(child: child!)),
        ),
        home: home ?? const MapDemoPage(),
      ),
    );
  }
}
