import 'dart:convert';
import 'dart:math' as math;

/// Shared with the standalone Swift companion. Coordinates interpolate
/// linearly; integer zoom holds until the next waypoint. No engine easing.
class ComparisonScenario {
  ComparisonScenario(this.name, this.waypoints) {
    if (waypoints.length < 2 ||
        waypoints.first.isEmpty ||
        waypoints.first[0] != 0) {
      throw const FormatException('At least two waypoints starting at zero');
    }
    for (var i = 0; i < waypoints.length; i++) {
      final p = waypoints[i];
      if (p.length != 4 ||
          p.any((v) => !v.isFinite) ||
          (i > 0 && p[0] <= waypoints[i - 1][0]) ||
          p[1].abs() > 85 ||
          p[2].abs() > 180 ||
          p[3] < 1 ||
          p[3] > 18 ||
          p[3] != p[3].roundToDouble()) {
        throw const FormatException('Invalid comparison waypoint');
      }
    }
    // A looping trajectory must return to the initial camera pose.
    for (var i = 1; i < 4; i++) {
      if (waypoints.first[i] != waypoints.last[i]) {
        throw const FormatException('Comparison trajectory must close');
      }
    }
  }

  final String name;
  final List<List<double>> waypoints;

  /// Latitude, longitude and zoom at a wall-clock offset in seconds.
  List<double> pose(double seconds) {
    final t = seconds % waypoints.last[0];
    var i = 0;
    while (i + 1 < waypoints.length - 1 && waypoints[i + 1][0] <= t) {
      i++;
    }
    final a = waypoints[i];
    final b = waypoints[i + 1];
    final f = (t - a[0]) / (b[0] - a[0]);
    return [a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3]];
  }
}

/// Expected EPSG:3857 viewport at a camera pose, in logical Flutter pixels.
/// Compare this with MapCore's actual bounds before accepting timing pairs.
Map<String, double> comparisonBounds(
    List<double> pose, double width, double height) {
  final scale = 256 * math.pow(2, pose[2]);
  final lat = pose[0] * math.pi / 180;
  final centerY =
      (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2;
  double latitude(double y) =>
      (2 * math.atan(math.exp(math.pi * (1 - 2 * y))) - math.pi / 2) *
      180 /
      math.pi;
  return {
    'north': latitude(centerY - height / 2 / scale),
    'south': latitude(centerY + height / 2 / scale),
    'west': pose[1] - width / 2 / scale * 360,
    'east': pose[1] + width / 2 / scale * 360,
  };
}

class NativeComparisonWorkload {
  NativeComparisonWorkload.fromJson(String text) {
    document = (jsonDecode(text) as Map).cast<String, dynamic>();
    styleUrl = document['styleUrl'] as String;
    final uri = Uri.parse(styleUrl);
    warmupSeconds = (document['warmupSeconds'] as num).toDouble();
    sampleSeconds = (document['sampleSeconds'] as num).toDouble();
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        !warmupSeconds.isFinite ||
        warmupSeconds <= 0 ||
        !sampleSeconds.isFinite ||
        sampleSeconds <= 0) {
      throw const FormatException('Invalid comparison workload');
    }
    scenarios = [
      for (final s in document['scenarios'] as List)
        ComparisonScenario(s['name'] as String, [
          for (final p in s['waypoints'] as List)
            [for (final n in p as List) (n as num).toDouble()]
        ])
    ];
    if (scenarios.isEmpty) throw const FormatException('No scenarios');
  }

  late final Map<String, dynamic> document;
  late final String styleUrl;
  late final double warmupSeconds;
  late final double sampleSeconds;
  late final List<ComparisonScenario> scenarios;
}
