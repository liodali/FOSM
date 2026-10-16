import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/scale_bar_metrics.dart';

export '../common/scale_bar_metrics.dart' show ScaleBarUnit;

/// A distance ruler using approximate ground scale at [latitude].
///
/// Enable via `MapView.showScaleBar`, or use independently in a bounded Stack.
/// Widths are logical map pixels and remain independent of display density.
/// The ruler ignores pointers and uses 1/2/5 distances that fit [maxWidth].
class MapScaleBar extends StatelessWidget {
  const MapScaleBar({
    super.key,
    required this.latitude,
    required this.zoom,
    this.unit = ScaleBarUnit.metric,
    this.maxWidth = 120,
    this.alignment = Alignment.bottomLeft,
    this.padding = const EdgeInsets.fromLTRB(12, 12, 12, 28),
  }) : assert(maxWidth > 0 && maxWidth < double.infinity);

  final double latitude;
  final int zoom;
  final ScaleBarUnit unit;

  /// Maximum ruler length, excluding its background's 12 pixels of padding.
  final double maxWidth;
  final Alignment alignment;

  /// Default bottom gap leaves space for provider attribution.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: SafeArea(
          child: Padding(
            padding: padding,
            child: LayoutBuilder(builder: (context, constraints) {
              final width = math.min(maxWidth, constraints.maxWidth - 12);
              final height =
                  MediaQuery.textScalerOf(context).scale(12) * 1.2 + 22;
              if (width < 24 || constraints.maxHeight < height) {
                return const SizedBox.shrink();
              }
              final scale = calculateScaleBar(
                  latitude: latitude, zoom: zoom, maxWidth: width, unit: unit);
              if (scale == null) return const SizedBox.shrink();
              return Align(
                alignment: alignment,
                child: Semantics(
                  label: scale.semanticLabel,
                  child: ExcludeSemantics(
                    child: Container(
                      width: width + 12,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(scale.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.2,
                                  color: Colors.black87,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          CustomPaint(
                              size: Size(scale.width, 6),
                              painter: const _RulerPainter()),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      );
}

class _RulerPainter extends CustomPainter {
  const _RulerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 5)
      ..lineTo(size.width, 5)
      ..lineTo(size.width, 0);
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black87
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_RulerPainter oldDelegate) => false;
}
