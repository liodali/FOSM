import 'dart:math' as math;
import 'dart:ui' show Color;

import 'css_color.dart';

/// Evaluation context for style expressions: the current zoom plus (for
/// data-driven expressions) the feature's property map.
class EvaluationContext {
  final double zoom;
  final Map<String, dynamic>? properties;

  const EvaluationContext({required this.zoom, this.properties});
}

/// Operators fosm understands. Anything else evaluates to `null` so paint
/// code can fall back to the style spec default — an unsupported operator
/// degrades one property, never the whole render.
const Set<String> _operators = {
  'zoom', 'get', 'has', 'at', 'length',
  '==', '!=', '<', '<=', '>', '>=',
  'all', 'any',
  'case', 'match', 'step', 'interpolate', 'coalesce',
  'to-color', 'to-number', 'to-string', 'to-boolean',
  'literal', 'array', 'concat', 'image', 'format',
};

/// A value is an expression when it is a list whose first element is a
/// known operator. Plain arrays (dash patterns, font stacks, …) start with
/// a non-operator and are treated as literal values.
bool isExpression(dynamic value) {
  if (value is! List || value.isEmpty) return false;
  final first = value.first;
  return first is String && _operators.contains(first);
}

/// Whether [expr] reads feature properties (`get`/`has`) anywhere, i.e.
/// must be re-evaluated per feature instead of cached per layer.
bool dependsOnProperties(dynamic expr) {
  if (expr is! List || expr.isEmpty) return false;
  final op = expr.first;
  if (op is String) {
    if (op == 'literal') return false;
    if (op == 'get' || op == 'has') return true;
  }
  for (final arg in expr.skip(1)) {
    if (dependsOnProperties(arg)) return true;
  }
  return false;
}

/// Evaluates a style expression against [ctx]. Non-expression values are
/// returned as-is; unsupported operators yield `null`.
dynamic evaluateExpression(dynamic expr, EvaluationContext ctx) {
  if (expr == null) return null;
  if (expr is num || expr is bool || expr is String || expr is Color) {
    return expr;
  }
  if (expr is! List || expr.isEmpty) return expr;
  final op = expr.first;
  if (op is! String || !_operators.contains(op)) return expr;
  final args = expr.sublist(1);

  switch (op) {
    case 'zoom':
      return ctx.zoom;

    case 'get':
      if (args.isEmpty) return null;
      final key = args.first;
      return (key is String) ? (ctx.properties?[key]) : null;

    case 'has':
      if (args.isEmpty || args.first is! String) return false;
      return ctx.properties?.containsKey(args.first as String) ?? false;

    case 'at':
      final index = _asNum(evaluateExpression(args.first, ctx));
      final list = evaluateExpression(args.length > 1 ? args[1] : null, ctx);
      if (index == null || list is! List) return null;
      final i = index.toInt();
      return i >= 0 && i < list.length ? list[i] : null;

    case 'length':
      final v = evaluateExpression(args.first, ctx);
      return v is List ? v.length : (v is String ? v.length : null);

    case '==':
      return _looseEquals(
        evaluateExpression(_arg(args, 0), ctx),
        evaluateExpression(_arg(args, 1), ctx),
      );
    case '!=':
      return !_looseEquals(
        evaluateExpression(_arg(args, 0), ctx),
        evaluateExpression(_arg(args, 1), ctx),
      );
    case '<':
    case '<=':
    case '>':
    case '>=':
      return _compare(
        op,
        evaluateExpression(_arg(args, 0), ctx),
        evaluateExpression(_arg(args, 1), ctx),
      );

    case 'all':
      for (final arg in args) {
        if (!_truthy(evaluateExpression(arg, ctx))) return false;
      }
      return true;
    case 'any':
      for (final arg in args) {
        if (_truthy(evaluateExpression(arg, ctx))) return true;
      }
      return false;

    case 'case':
      // [case, cond, value, …pairs…, fallback]
      var i = 0;
      while (i + 1 < args.length) {
        if (_truthy(evaluateExpression(args[i], ctx))) {
          return evaluateExpression(args[i + 1], ctx);
        }
        i += 2;
      }
      return i < args.length ? evaluateExpression(args[i], ctx) : null;

    case 'match':
      // [match, input, label(s), value, …, fallback]
      final input = evaluateExpression(args.first, ctx);
      var i = 1;
      while (i + 1 < args.length) {
        final labels = args[i];
        final matches = labels is List
            ? labels.any((l) => _looseEquals(l, input))
            : _looseEquals(labels, input);
        if (matches) return evaluateExpression(args[i + 1], ctx);
        i += 2;
      }
      return i < args.length ? evaluateExpression(args[i], ctx) : null;

    case 'step':
      // [step, input, base, stop1, value1, stop2, value2, …]
      final input = _asNum(evaluateExpression(args.first, ctx));
      if (args.length < 2) return null;
      var value = evaluateExpression(args[1], ctx);
      if (input == null) return value;
      var i = 2;
      while (i + 1 < args.length) {
        final stop = _asNum(evaluateExpression(args[i], ctx));
        if (stop != null && input < stop) return value;
        value = evaluateExpression(args[i + 1], ctx);
        i += 2;
      }
      return value;

    case 'interpolate':
      return _interpolate(args, ctx);

    case 'coalesce':
      for (final arg in args) {
        final v = evaluateExpression(arg, ctx);
        if (v != null) return v;
      }
      return null;

    case 'to-color':
      for (final arg in args) {
        final color = _asColor(evaluateExpression(arg, ctx));
        if (color != null) return color;
      }
      return null;

    case 'to-number':
      for (final arg in args) {
        final v = evaluateExpression(arg, ctx);
        if (v is num) return v;
        if (v is String) {
          final parsed = double.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return args.isNotEmpty ? evaluateExpression(args.last, ctx) : null;

    case 'to-string':
      return stringifyStyleValue(evaluateExpression(args.first, ctx));

    case 'to-boolean':
      return _truthy(evaluateExpression(args.first, ctx));

    case 'literal':
      return args.isNotEmpty ? args.first : null;

    case 'array':
      final v = evaluateExpression(args.first, ctx);
      return v is List ? v : (v == null ? null : [v]);

    case 'concat':
      final buffer = StringBuffer();
      for (final arg in args) {
        buffer.write(stringifyStyleValue(evaluateExpression(arg, ctx)));
      }
      return buffer.toString();

    case 'image':
      // ["image", name] resolves to the sprite name for icon painting.
      return stringifyStyleValue(evaluateExpression(args.first, ctx));

    case 'format':
      // ["format", [text, options], …] → plain concatenated string.
      final buffer = StringBuffer();
      for (final arg in args) {
        if (arg is List && arg.isNotEmpty) {
          buffer.write(stringifyStyleValue(evaluateExpression(arg.first, ctx)));
        }
      }
      return buffer.toString();

    default:
      return null;
  }
}

dynamic _arg(List args, int index) => index < args.length ? args[index] : null;

dynamic _interpolate(List args, EvaluationContext ctx) {
  // [interpolate, interpolation, input, stop1, value1, stop2, value2, …]
  if (args.length < 4) return null;

  var base = 1.0; // linear
  final interpolation = args[0];
  if (interpolation is List && interpolation.isNotEmpty) {
    if (interpolation.first == 'exponential' && interpolation.length > 1) {
      base = _asNum(interpolation[1]) ?? 1.0;
    }
    // cubic-bezier: approximated as linear.
  }

  final input = _asNum(evaluateExpression(args[1], ctx));
  if (input == null) return null;

  var stop = _asNum(evaluateExpression(args[2], ctx));
  var value = evaluateExpression(args[3], ctx);
  if (stop != null && input <= stop) return value;

  for (var i = 4; i + 1 < args.length; i += 2) {
    final nextStop = _asNum(evaluateExpression(args[i], ctx));
    final nextValue = evaluateExpression(args[i + 1], ctx);
    if (nextStop == null) continue;
    if (input <= nextStop) {
      final t = _interpolationFactor(base, stop ?? nextStop, input, nextStop);
      return _lerpValue(value, nextValue, t);
    }
    stop = nextStop;
    value = nextValue;
  }
  return value;
}

/// MapLibre interpolation factor: linear ratio, or the exponential curve
/// `(base^Δ − 1) / (base^total − 1)` for `["exponential", base]`.
double _interpolationFactor(double base, double s0, double t, double s1) {
  if (s1 <= s0) return 1;
  if (base <= 0 || base == 1.0) return ((t - s0) / (s1 - s0)).clamp(0.0, 1.0);
  final delta = s1 - s0;
  final factor =
      (math.pow(base, t - s0) - 1) / (math.pow(base, delta) - 1);
  return factor.clamp(0.0, 1.0);
}

dynamic _lerpValue(dynamic a, dynamic b, double t) {
  if (a is num && b is num) return a + (b - a) * t;
  // Interpolated paint values are often color *strings* at the stops —
  // coerce them so lerping produces a Color.
  final colorA = _asColor(a);
  final colorB = _asColor(b);
  if (colorA != null && colorB != null) {
    return Color.lerp(colorA, colorB, t) ?? colorB;
  }
  if (a is num || b is num) {
    final na = _asNum(a);
    final nb = _asNum(b);
    if (na != null && nb != null) return na + (nb - na) * t;
  }
  return t < 1 ? a : b;
}

// ── Filter evaluation ───────────────────────────────────────────────────────

/// Evaluates a layer filter — either the expression form
/// (`["all", ["==", ["get","class"], "motorway"], …]`) or the legacy form
/// (`["==", "class", "motorway"]`, where the first argument is a bare
/// property name). A `null` filter matches everything.
bool matchesFilter(dynamic filter, EvaluationContext ctx) {
  if (filter == null) return true;
  if (filter is! List || filter.isEmpty) return true;
  final op = filter.first;
  if (op is! String) return _truthy(evaluateExpression(filter, ctx));
  final args = filter.sublist(1);

  switch (op) {
    case 'all':
      return args.every((f) => matchesFilter(f, ctx));
    case 'any':
      return args.any((f) => matchesFilter(f, ctx));
    case 'none':
      return !args.any((f) => matchesFilter(f, ctx));

    case '==':
    case '!=':
    case '<':
    case '<=':
    case '>':
    case '>=':
      if (args.length < 2) return true;
      // Legacy filters name the property as a bare string; expression
      // filters wrap it in ["get", …].
      final left = (args[0] is String && !isExpression(args[0]))
          ? (ctx.properties?[args[0] as String])
          : evaluateExpression(args[0], ctx);
      final right = evaluateExpression(args[1], ctx);
      switch (op) {
        case '==':
          return _looseEquals(left, right);
        case '!=':
          return !_looseEquals(left, right);
        default:
          return _compare(op, left, right) ?? false;
      }

    case 'in':
      if (args.isEmpty) return false;
      final value = (args[0] is String && !isExpression(args[0]))
          ? (ctx.properties?[args[0] as String])
          : evaluateExpression(args[0], ctx);
      return args.skip(1).any((c) => _looseEquals(c, value));
    case '!in':
      if (args.isEmpty) return true;
      final value = (args[0] is String && !isExpression(args[0]))
          ? (ctx.properties?[args[0] as String])
          : evaluateExpression(args[0], ctx);
      return !args.skip(1).any((c) => _looseEquals(c, value));

    case 'has':
      if (args.isEmpty) return false;
      final key = args[0];
      if (key is String) return ctx.properties?.containsKey(key) ?? false;
      return _truthy(evaluateExpression(key, ctx));
    case '!has':
      if (args.isEmpty) return true;
      final key = args[0];
      if (key is String) return !(ctx.properties?.containsKey(key) ?? false);
      return !_truthy(evaluateExpression(key, ctx));

    default:
      return _truthy(evaluateExpression(filter, ctx));
  }
}

// ── Typed accessors with spec defaults ─────────────────────────────────────

Color? evaluateColorExpr(dynamic expr, EvaluationContext ctx) {
  if (expr == null) return null;
  return _asColor(evaluateExpression(expr, ctx));
}

double evaluateNumExpr(
  dynamic expr,
  EvaluationContext ctx, {
  required double fallback,
  double min = double.negativeInfinity,
  double max = double.infinity,
}) {
  if (expr == null) return fallback;
  final v = _asNum(evaluateExpression(expr, ctx));
  if (v == null) return fallback;
  return v.clamp(min, max);
}

bool evaluateBoolExpr(dynamic expr, EvaluationContext ctx,
    {required bool fallback}) {
  if (expr == null) return fallback;
  return _truthy(evaluateExpression(expr, ctx));
}

String? evaluateStringExpr(dynamic expr, EvaluationContext ctx) {
  if (expr == null) return null;
  final v = evaluateExpression(expr, ctx);
  if (v == null) return null;
  return stringifyStyleValue(v);
}

// ── Coercions ───────────────────────────────────────────────────────────────

Color? _asColor(Object? v) {
  if (v is Color) return v;
  if (v is String) return parseCssColor(v);
  if (v is List && v.length >= 3) {
    final r = _asNum(v[0]), g = _asNum(v[1]), b = _asNum(v[2]);
    final a = v.length > 3 ? _asNum(v[3]) : 1.0;
    if (r != null && g != null && b != null) {
      return Color.fromARGB(
        ((a ?? 1).clamp(0, 1) * 255).round(),
        r.clamp(0, 255).toInt(),
        g.clamp(0, 255).toInt(),
        b.clamp(0, 255).toInt(),
      );
    }
  }
  return null;
}

double? _asNum(Object? v) {
  if (v is num) return v.toDouble();
  if (v is bool) return null;
  if (v is String) return double.tryParse(v);
  return null;
}

/// Style stringification: `1.0` renders as `"1"`, matching GL JS.
String stringifyStyleValue(Object? v) {
  if (v == null) return '';
  if (v is num) {
    return v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();
  }
  return v.toString();
}

bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

bool _looseEquals(Object? a, Object? b) {
  if (a == null || b == null) return a == b; // null only equals null
  final an = _asNum(a);
  final bn = _asNum(b);
  if (an != null && bn != null) return an == bn;
  if (a is String || b is String) return a.toString() == b.toString();
  return a == b;
}

bool? _compare(String op, Object? a, Object? b) {
  final an = _asNum(a);
  final bn = _asNum(b);
  final int cmp;
  if (an != null && bn != null) {
    cmp = an.compareTo(bn);
  } else if (a is String && b is String) {
    cmp = a.compareTo(b);
  } else {
    return null;
  }
  return switch (op) {
    '<' => cmp < 0,
    '<=' => cmp <= 0,
    '>' => cmp > 0,
    _ => cmp >= 0,
  };
}
