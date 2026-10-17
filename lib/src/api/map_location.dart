import 'geo_point.dart';

/// A position supplied by the host's GPS, replay, or other location provider.
/// [accuracyMeters] is a horizontal radius; [bearing] is clockwise from north.
/// [timestamp] lets the controller reject fixes older than its last accepted fix.
class MapLocation {
  const MapLocation(
      {required this.point, this.accuracyMeters, this.bearing, this.timestamp});

  final LatLng point;
  final double? accuracyMeters;
  final double? bearing;
  final DateTime? timestamp;

  bool get isValid =>
      point.latitude.isFinite &&
      point.latitude.abs() <= 90 &&
      point.longitude.isFinite &&
      point.longitude.abs() <= 180 &&
      (accuracyMeters == null ||
          (accuracyMeters!.isFinite && accuracyMeters! >= 0)) &&
      (bearing == null ||
          (bearing!.isFinite && bearing! >= 0 && bearing! < 360));
}
