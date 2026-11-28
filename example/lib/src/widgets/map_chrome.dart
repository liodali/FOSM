import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:fosm/fosm.dart';

/// Floating panel used for every control that hovers over the map — an
/// [FCard] with a translucent background and soft shadow so the map stays
/// faintly visible underneath.
class MapPanel extends StatelessWidget {
  const MapPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.maxWidth,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final card = FCard(
      style: FCardStyleDelta.delta(
        decoration: DecorationDelta.shapeDelta(
          color: theme.colors.card.withValues(alpha: 0.94),
          shadows: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.12),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
          // Tighter corners than the card default (lg).
          shape: RoundedSuperellipseBorder(
            side: BorderSide(
              color: theme.colors.border,
              width: theme.style.borderWidth,
            ),
            borderRadius: theme.style.borderRadius.md,
          ),
        ),
      ),
      // FCard's default builder ignores style.padding — pad explicitly.
      child: Padding(padding: padding, child: child),
    );
    return maxWidth == null
        ? card
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth!),
            child: card,
          );
  }
}

/// Square icon tool button — a ghost [FButton.icon] with an [FTooltip].
///
/// [active] marks a toggle that is on; [busy] swaps the icon for a spinner
/// and disables the button; [iconColor] overrides the icon tint.
class MapToolButton extends StatelessWidget {
  const MapToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPress,
    this.active = false,
    this.busy = false,
    this.iconColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPress;
  final bool active;
  final bool busy;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return FTooltip(
      tipBuilder: (context, _) => Text(tooltip),
      child: FButton.icon(
        variant: FButtonVariant.ghost,
        selected: active,
        onPress: busy ? null : onPress,
        child: busy
            ? const FCircularProgress(size: FCircularProgressSizeVariant.sm)
            : Icon(
                icon,
                size: 20,
                color:
                    iconColor ?? (active ? colors.primary : colors.foreground),
              ),
      ),
    );
  }
}

/// Vertically grouped tool buttons with dividers — one floating panel
/// instead of a scatter of individually positioned buttons.
class MapToolGroup extends StatelessWidget {
  const MapToolGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return MapPanel(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: FDivider(),
              ),
          ],
        ],
      ),
    );
  }
}

/// Small pill showing live map state (zoom, marker count, …).
class MapStatusChip extends StatelessWidget {
  const MapStatusChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return FBadge(
      variant: FBadgeVariant.secondary,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colors.mutedForeground),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

/// App brand pill shown at the top-left of the map.
class MapBrandChip extends StatelessWidget {
  const MapBrandChip({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return MapPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FLucideIcons.map, size: 15, color: theme.colors.foreground),
          const SizedBox(width: 7),
          Text(
            'FOSM',
            style: theme.typography.body.sm.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: theme.colors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom cluster badge demonstrating [MarkerClusterOptions.builder].
class MapClusterBadge extends StatelessWidget {
  const MapClusterBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final size = count >= 10 ? 44.0 : 38.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primary,
        shape: BoxShape.circle,
        border: Border.all(color: colors.background, width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        '$count',
        style: context.theme.typography.body.sm.copyWith(
          color: colors.primaryForeground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Compact ghost icon action used inside the floating cards.
class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.tooltip,
    required this.onPress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return FTooltip(
      tipBuilder: (context, _) => Text(tooltip),
      child: FButton.icon(
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.xs,
        onPress: onPress,
        child: Icon(icon, size: 15),
      ),
    );
  }
}

/// Marker overlay ("info window") content — an ordinary Flutter widget that
/// FOSM anchors to its marker and moves with the camera.
class MarkerInfoCard extends StatelessWidget {
  const MarkerInfoCard({
    super.key,
    required this.title,
    required this.point,
    required this.accent,
    required this.onClose,
  });

  final String title;
  final LatLng point;
  final Color accent;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return MapPanel(
      maxWidth: 240,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.typography.body.sm.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${point.latitude.toStringAsFixed(4)}, '
                  '${point.longitude.toStringAsFixed(4)}',
                  style: theme.typography.body.xs.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          _CardAction(
            icon: FLucideIcons.x,
            tooltip: 'Close',
            onPress: onClose,
          ),
        ],
      ),
    );
  }
}

/// Route progress/result card shown under the status chip.
///
/// Three states: fetching (spinner), failed (message + retry), and drawn
/// (distance/duration + style cycle + clear).
class MapRouteCard extends StatelessWidget {
  const MapRouteCard({
    super.key,
    required this.loading,
    this.summary,
    this.error,
    required this.styleIcon,
    required this.styleTooltip,
    required this.onCycleStyle,
    required this.onRetry,
    required this.onDismiss,
  });

  final bool loading;
  final String? summary;
  final String? error;
  final IconData styleIcon;
  final String styleTooltip;
  final VoidCallback onCycleStyle;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final titleStyle = theme.typography.body.sm.copyWith(
      fontWeight: FontWeight.w600,
      color: theme.colors.foreground,
    );
    final captionStyle = theme.typography.body.xs.copyWith(
      color: theme.colors.mutedForeground,
    );

    final Widget content;
    if (loading) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const FCircularProgress(size: FCircularProgressSizeVariant.sm),
          const SizedBox(width: 10),
          Text('Fetching route…', style: titleStyle),
        ],
      );
    } else if (error != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FLucideIcons.alertCircle,
            size: 16,
            color: theme.colors.destructive,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: captionStyle,
            ),
          ),
          _CardAction(
            icon: FLucideIcons.refreshCcw,
            tooltip: 'Retry',
            onPress: onRetry,
          ),
          _CardAction(
            icon: FLucideIcons.x,
            tooltip: 'Dismiss',
            onPress: onDismiss,
          ),
        ],
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FLucideIcons.route, size: 16, color: theme.colors.foreground),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(summary ?? '', style: titleStyle),
                Text('To Zürich HB', style: captionStyle),
              ],
            ),
          ),
          _CardAction(
            icon: styleIcon,
            tooltip: styleTooltip,
            onPress: onCycleStyle,
          ),
          _CardAction(
            icon: FLucideIcons.x,
            tooltip: 'Clear route',
            onPress: onDismiss,
          ),
        ],
      );
    }

    return MapPanel(
      maxWidth: 340,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: content,
    );
  }
}
