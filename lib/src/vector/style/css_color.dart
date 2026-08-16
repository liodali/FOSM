import 'dart:ui' show Color;

/// Parses the CSS color forms used by MapLibre styles: `#rgb`, `#rgba`,
/// `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()`, `hsl()/hsla()` and a few named
/// colors. Returns `null` for anything else so callers can apply the style
/// spec's default.
Color? parseCssColor(String input) {
  var s = input.trim().toLowerCase();
  if (s.isEmpty) return null;

  if (s.startsWith('#')) {
    return _parseHex(s.substring(1));
  }
  if (s.startsWith('rgb(') || s.startsWith('rgba(')) {
    return _parseRgb(s.substring(s.indexOf('(') + 1, s.length - 1));
  }
  if (s.startsWith('hsl(') || s.startsWith('hsla(')) {
    return _parseHsl(s.substring(s.indexOf('(') + 1, s.length - 1));
  }
  return _namedColors[s];
}

Color? _parseHex(String hex) {
  switch (hex.length) {
    case 3:
      final rgb = _hexPair(hex[0], hex[0], hex[1], hex[1], hex[2], hex[2]);
      return rgb == null ? null : Color(0xFF000000 | rgb);
    case 4: // #rgba
      final rgb = _hexPair(hex[0], hex[0], hex[1], hex[1], hex[2], hex[2]);
      final a = _hexByte(hex[3] * 2);
      return (rgb == null || a == null) ? null : Color((a << 24) | rgb);
    case 6:
      final rgb = _hexPair(hex[0], hex[1], hex[2], hex[3], hex[4], hex[5]);
      return rgb == null ? null : Color(0xFF000000 | rgb);
    case 8: // #rrggbbaa — alpha is last in CSS.
      final rgb = _hexPair(hex[0], hex[1], hex[2], hex[3], hex[4], hex[5]);
      final a = _hexByte(hex.substring(6, 8));
      return (a == null || rgb == null) ? null : Color((a << 24) | rgb);
    default:
      return null;
  }
}

int? _hexByte(String chars) {
  if (chars.length != 2) return null;
  final hi = _hexNibble(chars[0]);
  final lo = _hexNibble(chars[1]);
  return (hi == null || lo == null) ? null : (hi << 4) | lo;
}

int? _hexNibble(String char) {
  final code = char.codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10; // a-f
  return null;
}

int? _hexPair(String r1, String r2, String g1, String g2, String b1, String b2) {
  final r = _hexByte(r1 + r2);
  final g = _hexByte(g1 + g2);
  final b = _hexByte(b1 + b2);
  return (r == null || g == null || b == null) ? null : (r << 16) | (g << 8) | b;
}

Color? _parseRgb(String body) {
  final parts = body.split(',');
  if (parts.length < 3) return null;

  final r = _channel(parts[0]);
  final g = _channel(parts[1]);
  final b = _channel(parts[2]);
  final a = parts.length > 3 ? _alphaChannel(parts[3]) : 1.0;
  if (r == null || g == null || b == null || a == null) return null;

  return Color.fromARGB(
    (_clamp01(a) * 255).round(),
    _clamp01(r) * 255 ~/ 1,
    _clamp01(g) * 255 ~/ 1,
    _clamp01(b) * 255 ~/ 1,
  );
}

Color? _parseHsl(String body) {
  final parts = body.split(',');
  if (parts.length < 3) return null;

  final hue = double.tryParse(parts[0].replaceAll(RegExp('[^0-9.+-]'), ''));
  final sat = double.tryParse(parts[1].replaceAll('%', '').trim());
  final light = double.tryParse(parts[2].replaceAll('%', '').trim());
  final a = parts.length > 3 ? _alphaChannel(parts[3]) : 1.0;
  if (hue == null || sat == null || light == null || a == null) return null;

  // Standard HSL → RGB (s in [0,1], l in [0,1]).
  final s = _clamp01(sat / 100);
  final l = _clamp01(light / 100);
  final c = (1 - (2 * l - 1).abs()) * s;
  final hp = (hue % 360) / 60;
  final x = c * (1 - (hp % 2 - 1).abs());
  final double r, g, b;
  if (hp < 1) {
    r = c; g = x; b = 0;
  } else if (hp < 2) {
    r = x; g = c; b = 0;
  } else if (hp < 3) {
    r = 0; g = c; b = x;
  } else if (hp < 4) {
    r = 0; g = x; b = c;
  } else if (hp < 5) {
    r = x; g = 0; b = c;
  } else {
    r = c; g = 0; b = x;
  }
  final m = l - c / 2;
  return Color.fromARGB(
    (_clamp01(a) * 255).round(),
    (r + m) * 255 ~/ 1,
    (g + m) * 255 ~/ 1,
    (b + m) * 255 ~/ 1,
  );
}

/// Accepts `0..255` or `0%..100%` color channels, returning 0..1.
double? _channel(String raw) {
  final s = raw.trim();
  if (s.endsWith('%')) {
    final v = double.tryParse(s.substring(0, s.length - 1));
    return v == null ? null : _clamp01(v / 100);
  }
  final v = double.tryParse(s);
  return v == null ? null : _clamp01(v / 255);
}

double? _alphaChannel(String raw) => double.tryParse(raw.trim());

double _clamp01(double v) => v.clamp(0.0, 1.0);

const Map<String, Color> _namedColors = {
  'transparent': Color(0x00000000),
  'black': Color(0xFF000000),
  'white': Color(0xFFFFFFFF),
  'red': Color(0xFFFF0000),
  'green': Color(0xFF008000),
  'blue': Color(0xFF0000FF),
  'yellow': Color(0xFFFFFF00),
  'orange': Color(0xFFFFA500),
  'gray': Color(0xFF808080),
  'grey': Color(0xFF808080),
  'brown': Color(0xFFA52A2A),
  'pink': Color(0xFFFFC0CB),
  'purple': Color(0xFF800080),
};
