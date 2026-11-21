import 'dart:typed_data';

import 'package:example/main.dart';
import 'package:example/src/demo_settings.dart';
import 'package:example/src/map_demo_page.dart';
import 'package:example/src/widgets/map_chrome.dart';
import 'package:example/src/widgets/settings_sheet.dart';
import 'package:forui/forui.dart';
import 'package:fosm/fosm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Minimal valid 1×1 PNG — used as a fake tile so the demo page renders
/// without network access.
final Uint8List _tinyPng = Uint8List.fromList([
  137, 80, 78, 71, 13, 10, 26, 10, // PNG signature
  0, 0, 0, 13, // IHDR length
  73, 72, 68, 82, // IHDR
  0, 0, 0, 1, 0, 0, 0, 1, // 1×1
  8, 2, 0, 0, 0, // 8-bit RGB
  144, 119, 83, 222, // CRC
  0, 0, 0, 12, // IDAT length
  73, 68, 65, 84, // IDAT
  8, 215, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0,
  24, 221, 142, 232, // CRC
  0, 0, 0, 0, // IEND length
  73, 69, 78, 68, // IEND
  174, 66, 96, 130, // CRC
]);

Future<Uint8List> _stubFetcher(int z, int x, int y) async => _tinyPng;

Widget _app() => FosmDemoApp(home: MapDemoPage(tileFetcher: _stubFetcher));

void main() {
  setUp(() {
    appThemeMode.value = ThemeMode.system;
  });

  test('DemoSettings.edit notifies listeners once', () {
    final settings = DemoSettings();
    var calls = 0;
    settings.addListener(() => calls++);
    settings.edit((s) => s.showScaleBar = false);
    expect(calls, 1);
    expect(settings.showScaleBar, isFalse);
    settings.dispose();
  });

  testWidgets('floating panels pad their content', (tester) async {
    // Regression: FCard's default builder ignores style.padding, so panels
    // must wrap their child in a real Padding — content was flush against
    // the card edges (brand text clipped, info-card accent bar touching).
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FTheme(
          data: FTheme.neutral.light.desktop,
          child: child!,
        ),
        home: const Center(child: MapBrandChip()),
      ),
    );
    await tester.pump();

    final chip = tester.getSize(find.byType(FCard));
    final label = tester.getSize(find.text('FOSM'));
    expect(chip.width, greaterThan(label.width + 28));
    expect(chip.height, greaterThanOrEqualTo(label.height + 18));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => FTheme(
          data: FTheme.neutral.light.desktop,
          child: child!,
        ),
        home: Center(
          child: MarkerInfoCard(
            title: 'Cluster point 29',
            point: const LatLng(latitude: 47.4218, longitude: 8.4860),
            accent: const Color(0xFF16A34A),
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    final card = tester.getSize(find.byType(FCard));
    // The 32px accent bar must not touch the card's top/bottom edges.
    expect(card.height, greaterThan(32 + 24));
  });

  testWidgets('demo chrome renders over the map', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('FOSM'), findsOneWidget);
    expect(find.text('Raster'), findsOneWidget);
    expect(find.text('Vector'), findsOneWidget);
    expect(find.byIcon(FLucideIcons.slidersHorizontal), findsOneWidget);
    expect(find.textContaining('Zoom'), findsOneWidget);
    expect(find.byType(MapScaleBar), findsOneWidget);
    expect(find.byType(MapView), findsOneWidget);
  });

  testWidgets('settings sheet toggles reach the map', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.byIcon(FLucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();

    expect(find.text('Map settings'), findsOneWidget);
    expect(find.text('CAMERA & GESTURES'), findsOneWidget);

    // Scroll the camera section up, then turn the scale bar off.
    await tester.dragFrom(const Offset(400, 450), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scale bar'));
    await tester.pumpAndSettle();

    // The markers section is below the fold — scroll it into view.
    await tester.dragFrom(const Offset(400, 450), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('MARKERS'), findsOneWidget);

    // Dismiss the sheet by tapping the barrier above it.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(find.text('Map settings'), findsNothing);
    expect(find.byType(MapScaleBar), findsNothing);
  });

  testWidgets('appearance switch changes the app theme', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.byIcon(FLucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });

  testWidgets('settings sheet shows style presets in vector mode', (
    tester,
  ) async {
    final settings = DemoSettings()..mode = MapMode.vector;
    final markers = MarkerManager();
    final theme = FTheme.neutral.light.touch;
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: FLocalizations.supportedLocales,
        localizationsDelegates: FLocalizations.localizationsDelegates,
        builder: (context, child) => FTheme(
          data: theme,
          child: FToaster(child: FTooltipGroup(child: child!)),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FButton(
                onPress: () => showMapSettingsSheet(
                  context,
                  settings: settings,
                  markers: markers,
                  onAddTextMarker: () {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('VECTOR STYLE'), findsOneWidget);
    final presets = find.byType(Wrap);
    expect(
      find.descendant(of: presets, matching: find.text('Liberty')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: presets, matching: find.text('Bright')),
      findsOneWidget,
    );
    // 'Dark' also labels the theme toggle — match inside the preset wrap.
    expect(
      find.descendant(of: presets, matching: find.text('Dark')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: presets, matching: find.text('Positron')),
      findsOneWidget,
    );

    // Selecting a preset updates the shared settings.
    await tester.tap(
      find.descendant(of: presets, matching: find.text('Bright')),
    );
    await tester.pumpAndSettle();
    expect(settings.styleUrl, 'https://tiles.openfreemap.org/styles/bright');

    settings.dispose();
    markers.dispose();
  });
}
