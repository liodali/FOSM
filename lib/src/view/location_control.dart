import 'package:flutter/material.dart';

import '../api/map_location_controller.dart';

/// Recenter/follow button, also available as MapView's built-in overlay.
class MapLocationControl extends StatelessWidget {
  const MapLocationControl(
      {super.key,
      required this.controller,
      this.alignment = Alignment.bottomRight,
      this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 120)});

  final MapLocationController controller;
  final Alignment alignment;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasFix = controller.location != null;
        final following = controller.isFollowing;
        final canFollow = hasFix && controller.error == null;
        final tooltip = controller.error != null
            ? 'Location unavailable'
            : !hasFix
                ? 'Waiting for location'
                : following
                    ? 'Following location'
                    : 'Recenter and follow location';
        return SafeArea(
            child: Align(
                alignment: alignment,
                child: Padding(
                    padding: padding,
                    child: Material(
                        color: Colors.white.withValues(alpha: 0.92),
                        elevation: 2,
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                            width: 44,
                            height: 44,
                            child: IconButton(
                                tooltip: tooltip,
                                onPressed: canFollow ? controller.follow : null,
                                icon: Icon(
                                    controller.error != null
                                        ? Icons.gps_off
                                        : (following
                                            ? Icons.gps_fixed
                                            : Icons.gps_not_fixed),
                                    color: canFollow
                                        ? (following
                                            ? Colors.blue.shade700
                                            : Colors.black87)
                                        : Colors.grey)))))));
      });
}
