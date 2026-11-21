import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:fosm/fosm.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import 'package:example/src/demo_settings.dart';

/// Opens the demo settings sheet (a forui modal sheet sliding from the
/// bottom).
///
/// The sheet rebuilds from [DemoSettings] (a [ChangeNotifier]) and the
/// [MarkerManager], so every control stays live without manual state
/// synchronization between the page and the sheet route.
Future<void> showMapSettingsSheet(
  BuildContext context, {
  required DemoSettings settings,
  required MarkerManager markers,
  required VoidCallback onAddTextMarker,
}) {
  return showFSheet<void>(
    context: context,
    side: FLayout.btt,
    useSafeArea: true,
    mainAxisMaxRatio: 0.85,
    builder: (context) {
      // forui's Sheet is a behavior shell (drag/barrier/animation) — the
      // content provides its own surface.
      final theme = context.theme;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colors.background,
          borderRadius: BorderRadius.vertical(
            top: theme.style.borderRadius.xl2.topLeft,
          ),
          border: Border(
            top: BorderSide(
              color: theme.colors.border,
              width: theme.style.borderWidth,
            ),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colors.border,
                  borderRadius: theme.style.borderRadius.pill,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: _MapSettingsSheet(
                settings: settings,
                markers: markers,
                onAddTextMarker: onAddTextMarker,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _MapSettingsSheet extends StatelessWidget {
  const _MapSettingsSheet({
    required this.settings,
    required this.markers,
    required this.onAddTextMarker,
  });

  final DemoSettings settings;
  final MarkerManager markers;
  final VoidCallback onAddTextMarker;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Center(
            child: Text(
              'Map settings',
              style: theme.typography.display.md.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colors.foreground,
              ),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionLabel('Appearance'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: appThemeMode,
            builder: (context, mode, _) => Row(
              children: [
                Expanded(
                  child: _Toggle(
                    label: 'Light',
                    icon: FLucideIcons.sun,
                    selected: mode == ThemeMode.light,
                    onSelect: (_) => appThemeMode.value = ThemeMode.light,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Toggle(
                    label: 'System',
                    icon: FLucideIcons.monitor,
                    selected: mode == ThemeMode.system,
                    onSelect: (_) => appThemeMode.value = ThemeMode.system,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Toggle(
                    label: 'Dark',
                    icon: FLucideIcons.moon,
                    selected: mode == ThemeMode.dark,
                    onSelect: (_) => appThemeMode.value = ThemeMode.dark,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (settings.mode == MapMode.vector) ...[
            const _SectionLabel('Vector style'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in mapStylePresets)
                  _Toggle(
                    compact: true,
                    label: preset.label,
                    selected: settings.styleUrl == preset.url,
                    onSelect: (_) =>
                        settings.edit((s) => s.styleUrl = preset.url),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _CustomStyleField(
              styleUrl: settings.styleUrl,
              onApply: (url) => settings.edit((s) => s.styleUrl = url),
            ),
            const SizedBox(height: 6),
            Text(
              'Presets by OpenFreeMap — any MapLibre style URL works.',
              style: theme.typography.body.xs.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 24),
          ],
          const _SectionLabel('Camera & gestures'),
          FTileGroup(
            children: [
              _switchTile(
                icon: FLucideIcons.sparkles,
                title: 'Animate zoom',
                value: settings.animateZoom,
                onChange: (v) => settings.edit((s) => s.animateZoom = v),
              ),
              _switchTile(
                icon: FLucideIcons.zoomIn,
                title: 'Fractional zoom',
                subtitle: 'Smooth zoom levels instead of integer steps',
                value: settings.fractionalZoom,
                onChange: (v) => settings.edit((s) => s.fractionalZoom = v),
              ),
              _switchTile(
                icon: FLucideIcons.hand,
                title: 'Momentum panning',
                value: settings.enableFling,
                onChange: (v) => settings.edit((s) => s.enableFling = v),
              ),
              _switchTile(
                icon: FLucideIcons.mouse,
                title: 'Mouse-wheel zoom',
                value: settings.enableScrollZoom,
                onChange: (v) => settings.edit((s) => s.enableScrollZoom = v),
              ),
              _switchTile(
                icon: FLucideIcons.ruler,
                title: 'Scale bar',
                value: settings.showScaleBar,
                onChange: (v) => settings.edit((s) => s.showScaleBar = v),
              ),
            ],
          ),
          if (settings.animateZoom) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _Toggle(
                  compact: true,
                  label: 'Scale',
                  icon: FLucideIcons.maximize,
                  selected: settings.zoomStyle == ZoomAnimationStyle.scale,
                  onSelect: (_) => settings.edit(
                    (s) => s.zoomStyle = ZoomAnimationStyle.scale,
                  ),
                ),
                const SizedBox(width: 8),
                _Toggle(
                  compact: true,
                  label: 'Crossfade',
                  icon: FLucideIcons.eye,
                  selected: settings.zoomStyle == ZoomAnimationStyle.crossfade,
                  onSelect: (_) => settings.edit(
                    (s) => s.zoomStyle = ZoomAnimationStyle.crossfade,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          const _SectionLabel('Markers'),
          FTileGroup(
            children: [
              _switchTile(
                icon: FLucideIcons.circleDot,
                title: 'Cluster markers',
                subtitle: 'Group nearby pins when zoomed out',
                value: settings.clustering,
                onChange: (v) => settings.edit((s) => s.clustering = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: markers,
            builder: (context, _) => Row(
              children: [
                Text(
                  '${markers.length} on the map',
                  style: theme.typography.body.xs.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
                const Spacer(),
                FButton(
                  variant: FButtonVariant.secondary,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: onAddTextMarker,
                  prefix: const Icon(FLucideIcons.type, size: 15),
                  child: const Text('Text'),
                ),
                const SizedBox(width: 8),
                FButton(
                  variant: FButtonVariant.secondary,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: markers.isEmpty ? null : markers.clear,
                  prefix: const Icon(FLucideIcons.trash2, size: 15),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('Location'),
          FTileGroup(
            children: [
              _switchTile(
                icon: FLucideIcons.locateFixed,
                title: 'Simulate location',
                subtitle:
                    'Walks a circle near Zürich — drag to pause following',
                value: settings.simulateLocation,
                onChange: (v) => settings.edit((s) => s.simulateLocation = v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label.toUpperCase(),
        style: theme.typography.body.xs.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: theme.colors.mutedForeground,
        ),
      ),
    );
  }
}

/// Outline button that behaves as a toggle (shadcn-style toggle group).
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    this.icon,
    required this.selected,
    required this.onSelect,
    this.compact = false,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final ValueChanged<bool> onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: FButtonVariant.outline,
      size: FButtonSizeVariant.sm,
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      selected: selected,
      onPress: () => onSelect(!selected),
      prefix: icon == null ? null : Icon(icon, size: 15),
      child: Text(label),
    );
  }
}

/// Settings row — an [FTile] with a trailing [FSwitch]; tapping anywhere on
/// the row toggles it.
FTile _switchTile({
  required IconData icon,
  required String title,
  String? subtitle,
  required bool value,
  required ValueChanged<bool> onChange,
}) {
  return FTile(
    prefix: Icon(icon, size: 18),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    suffix: FSwitch(value: value, onChange: onChange),
    onPress: () => onChange(!value),
  );
}

/// Custom MapLibre style URL entry, kept in sync when a preset is selected
/// elsewhere in the sheet.
class _CustomStyleField extends StatefulWidget {
  const _CustomStyleField({required this.styleUrl, required this.onApply});

  final String styleUrl;
  final ValueChanged<String> onApply;

  @override
  State<_CustomStyleField> createState() => _CustomStyleFieldState();
}

class _CustomStyleFieldState extends State<_CustomStyleField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.styleUrl,
  );

  @override
  void didUpdateWidget(covariant _CustomStyleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.styleUrl != oldWidget.styleUrl &&
        _controller.text != widget.styleUrl) {
      _controller.text = widget.styleUrl;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    widget.onApply(url);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: FTextField(
            control: FTextFieldControl.managed(controller: _controller),
            label: const Text('Custom style URL'),
            hint: 'https://example.com/style.json',
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: FButton(
            variant: FButtonVariant.secondary,
            mainAxisSize: MainAxisSize.min,
            onPress: _apply,
            child: const Text('Apply'),
          ),
        ),
      ],
    );
  }
}
