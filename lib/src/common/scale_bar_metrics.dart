import 'dart:math' as math;

import 'osm_transformation_utilities.dart';
import 'utils.dart' show tileWidth;

/// Units displayed by the map's distance scale.
enum ScaleBarUnit { metric, imperial }

/// Internal measurement shared by painting and accessibility labels.
class ScaleBarMetrics {
  const ScaleBarMetrics(this.width, this.label, this.semanticLabel);

  final double width;
  final String label;
  final String semanticLabel;
}

/// Approximate ground resolution at the camera center on spherical Web
/// Mercator, in meters per logical map pixel (not decoded image pixels).
/// See https://docs.maptiler.com/google-maps-coordinates-tile-bounds-projection/
double mapMetersPerPixel(double latitude, num zoom) =>
    2 *
    math.pi *
    6378137 *
    math.cos(clampLatitude(latitude) * math.pi / 180) /
    (tileWidth * math.pow(2, zoom));

ScaleBarMetrics? calculateScaleBar({
  required double latitude,
  required num zoom,
  required double maxWidth,
  required ScaleBarUnit unit,
}) {
  if (!latitude.isFinite ||
      !zoom.isFinite ||
      zoom < 0 ||
      zoom > 30 ||
      !maxWidth.isFinite ||
      maxWidth <= 0) {
    return null;
  }
  final resolution = mapMetersPerPixel(latitude, zoom);
  final capacityMeters = resolution * maxWidth;
  final double metersPerUnit;
  final String abbreviation;
  final String singular;
  final String plural;
  if (unit == ScaleBarUnit.metric) {
    final kilometers = capacityMeters >= 1000;
    metersPerUnit = kilometers ? 1000 : 1;
    abbreviation = kilometers ? 'km' : 'm';
    singular = kilometers ? 'kilometer' : 'meter';
    plural = kilometers ? 'kilometers' : 'meters';
  } else {
    final miles = capacityMeters >= 1609.344;
    metersPerUnit = miles ? 1609.344 : 0.3048;
    abbreviation = miles ? 'mi' : 'ft';
    singular = miles ? 'mile' : 'foot';
    plural = miles ? 'miles' : 'feet';
  }
  final capacity = capacityMeters / metersPerUnit;
  if (!capacity.isFinite || capacity <= 0) return null;
  final decade =
      math.pow(10, (math.log(capacity) / math.ln10).floor()).toDouble();
  final normalized = capacity / decade;
  final distance = (normalized >= 5
          ? 5
          : normalized >= 2
              ? 2
              : 1) *
      decade;
  final decimals =
      math.max(0, -(math.log(distance) / math.ln10).floor()).clamp(0, 10);
  final number = distance.toStringAsFixed(decimals);
  return ScaleBarMetrics(
    (distance * metersPerUnit / resolution).clamp(0, maxWidth),
    '$number $abbreviation',
    'Map scale: $number ${distance == 1 ? singular : plural}',
  );
}
