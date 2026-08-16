import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/style/css_color.dart';
import 'package:fosm/src/vector/style/expression.dart';

void main() {
  const props = {
    'class': 'motorway',
    'admin_level': 4,
    'name': 'Zürich',
    'brunnel': 'tunnel',
  };

  EvaluationContext ctx(double zoom) =>
      EvaluationContext(zoom: zoom, properties: props);

  group('expression detection', () {
    test('lists with a known operator are expressions', () {
      expect(isExpression(['zoom']), isTrue);
      expect(isExpression(['get', 'class']), isTrue);
    });

    test('plain arrays are not expressions', () {
      expect(isExpression([1, 2]), isFalse); // dasharray
      expect(isExpression(['Noto Sans Regular']), isFalse); // font stack
      expect(isExpression('motorway'), isFalse);
      expect(isExpression(null), isFalse);
    });

    test('property dependence detection', () {
      expect(dependsOnProperties(['get', 'class']), isTrue);
      expect(dependsOnProperties(['has', 'name']), isTrue);
      expect(dependsOnProperties(['zoom']), isFalse);
      expect(dependsOnProperties(['interpolate', ['linear'], ['zoom'],
          5, ['step', 2, ['get', 'rank'], 5, 3]]), isTrue);
      expect(dependsOnProperties(['literal', ['get', 'class']]), isFalse);
    });
  });

  group('basic operators', () {
    test('zoom and get', () {
      expect(evaluateExpression(['zoom'], ctx(7.5)), 7.5);
      expect(evaluateExpression(['get', 'class'], ctx(7)), 'motorway');
      expect(evaluateExpression(['get', 'missing'], ctx(7)), isNull);
      expect(evaluateExpression(['has', 'name'], ctx(7)), isTrue);
      expect(evaluateExpression(['has', 'missing'], ctx(7)), isFalse);
    });

    test('comparisons with coercion', () {
      expect(
        evaluateExpression(['==', ['get', 'class'], 'motorway'], ctx(7)),
        isTrue,
      );
      expect(
        evaluateExpression(['>=', ['get', 'admin_level'], 4], ctx(7)),
        isTrue,
      );
      expect(
        evaluateExpression(['<', ['get', 'admin_level'], 4], ctx(7)),
        isFalse,
      );
      // "4" (string) == 4 (number) under loose equality.
      expect(evaluateExpression(['==', '4', 4], ctx(7)), isTrue);
    });

    test('all / any', () {
      final all = [
        'all',
        ['==', ['get', 'class'], 'motorway'],
        ['>=', ['get', 'admin_level'], 2],
      ];
      expect(evaluateExpression(all, ctx(7)), isTrue);

      final any = [
        'any',
        ['==', ['get', 'class'], 'residential'],
        ['==', ['get', 'brunnel'], 'tunnel'],
      ];
      expect(evaluateExpression(any, ctx(7)), isTrue);
    });

    test('concat and to-string', () {
      expect(
        evaluateExpression(['concat', 'a ', ['get', 'name']], ctx(7)),
        'a Zürich',
      );
      expect(evaluateExpression(['to-string', 1.0], ctx(7)), '1');
      expect(evaluateExpression(['to-string', 1.5], ctx(7)), '1.5');
      expect(stringifyStyleValue(3.0), '3');
    });

    test('coalesce picks first non-null', () {
      final expr = ['coalesce', ['get', 'missing'], ['get', 'name']];
      expect(evaluateExpression(expr, ctx(7)), 'Zürich');
    });
  });

  group('interpolate / step', () {
    test('linear interpolation of numbers', () {
      final expr = [
        'interpolate',
        ['linear'],
        ['zoom'],
        5,
        1,
        10,
        3,
      ];
      expect(evaluateExpression(expr, ctx(5)), 1);
      expect(evaluateExpression(expr, ctx(7.5)), 2);
      expect(evaluateExpression(expr, ctx(10)), 3);
      expect(evaluateExpression(expr, ctx(3)), 1); // below first stop
    });

    test('linear interpolation of colors', () {
      final expr = [
        'interpolate',
        ['linear'],
        ['zoom'],
        0,
        '#000000',
        10,
        '#ffffff',
      ];
      final result = evaluateExpression(expr, ctx(5));
      expect(result, isA<Color>());
      expect((result as Color).r, closeTo(0.5, 0.01));
    });

    test('exponential interpolation uses the base curve', () {
      final expr = [
        'interpolate',
        ['exponential', 2],
        ['zoom'],
        0,
        0,
        1,
        10,
      ];
      // factor at t=0.5: (2^0.5 − 1) / (2^1 − 1) ≈ 0.4142 → value ≈ 4.142
      final result = evaluateExpression(expr, ctx(0.5)) as num;
      expect(result, closeTo(4.142, 0.01));
    });

    test('step picks the output for the last reached stop', () {
      final expr = ['step', ['zoom'], 1, 7, 2, 12, 3];
      expect(evaluateExpression(expr, ctx(6)), 1);
      expect(evaluateExpression(expr, ctx(7)), 2);
      expect(evaluateExpression(expr, ctx(12)), 3);
      expect(evaluateExpression(expr, ctx(20)), 3);
    });
  });

  group('match / case', () {
    test('match with single labels and fallback', () {
      final expr = [
        'match',
        ['get', 'class'],
        'motorway',
        '#e892a2',
        'trunk',
        '#f9b29c',
        '#ccc',
      ];
      final ctx0 = ctx(7);
      expect(
        evaluateColorExpr(expr, ctx0),
        parseCssColor('#e892a2'),
      );

      final props2 = {...props, 'class': 'trunk'};
      final ctx2 = EvaluationContext(zoom: 7, properties: props2);
      expect(
        evaluateColorExpr(expr, ctx2),
        parseCssColor('#f9b29c'),
      );
    });

    test('match with label arrays', () {
      final expr = [
        'match',
        ['get', 'class'],
        ['motorway', 'trunk'],
        'major',
        'minor',
      ];
      expect(evaluateExpression(expr, ctx(7)), 'major');
    });

    test('case picks the first true condition', () {
      final expr = [
        'case',
        ['==', ['get', 'brunnel'], 'tunnel'],
        'tunnel-style',
        ['==', ['get', 'brunnel'], 'bridge'],
        'bridge-style',
        'plain',
      ];
      expect(evaluateExpression(expr, ctx(7)), 'tunnel-style');
    });
  });

  group('filters', () {
    test('legacy == filter with bare property name', () {
      expect(matchesFilter(['==', 'class', 'motorway'], ctx(7)), isTrue);
      expect(matchesFilter(['==', 'class', 'residential'], ctx(7)), isFalse);
    });

    test('expression-style filter', () {
      final filter = [
        'all',
        ['==', ['get', 'class'], 'motorway'],
        ['>=', ['get', 'admin_level'], 2],
      ];
      expect(matchesFilter(filter, ctx(7)), isTrue);
    });

    test('legacy in / !in / has / !has', () {
      expect(matchesFilter(['in', 'class', 'trunk', 'motorway'], ctx(7)), isTrue);
      expect(matchesFilter(['!in', 'class', 'trunk', 'trunk'], ctx(7)), isTrue);
      expect(matchesFilter(['has', 'name'], ctx(7)), isTrue);
      expect(matchesFilter(['!has', 'missing'], ctx(7)), isTrue);
      expect(matchesFilter(['none', ['==', 'class', 'x']], ctx(7)), isTrue);
    });

    test('null filter matches everything', () {
      expect(matchesFilter(null, ctx(7)), isTrue);
    });
  });

  group('typed accessors', () {
    test('evaluateNumExpr applies fallback and clamps', () {
      expect(evaluateNumExpr(null, ctx(7), fallback: 1.5), 1.5);
      expect(
        evaluateNumExpr(5, ctx(7), fallback: 0, min: 0, max: 3),
        3,
      );
    });

    test('evaluateColorExpr parses strings', () {
      expect(evaluateColorExpr('#ff0000', ctx(7)), const Color(0xFFFF0000));
      expect(evaluateColorExpr(['to-color', '#00ff0080'], ctx(7)),
          isA<Color>());
    });

    test('unknown operator yields typed fallback, not a crash', () {
      expect(evaluateNumExpr(['voodoo', ['zoom']], ctx(7), fallback: 42), 42);
      expect(evaluateColorExpr(['voodoo'], ctx(7)), isNull);
    });
  });

  group('CSS colors', () {
    test('hex forms', () {
      expect(parseCssColor('#f00'), const Color(0xFFFF0000));
      expect(parseCssColor('#ff0000'), const Color(0xFFFF0000));
      expect(parseCssColor('#ff000080')!.a, closeTo(128 / 255, 0.01));
      expect(parseCssColor('#f00c')!.a, closeTo(204 / 255, 0.01));
    });

    test('rgb / rgba forms', () {
      expect(parseCssColor('rgb(255, 0, 0)'), const Color(0xFFFF0000));
      expect(parseCssColor('rgba(255, 0, 0, 0.5)')!.a, closeTo(0.5, 0.01));
      expect(parseCssColor('rgb(100%, 0%, 0%)'), const Color(0xFFFF0000));
    });

    test('hsl and named colors', () {
      // hsl(0, 100%, 50%) is pure red.
      expect(parseCssColor('hsl(0, 100%, 50%)'), const Color(0xFFFF0000));
      expect(parseCssColor('transparent')!.a, 0);
      expect(parseCssColor('not-a-color'), isNull);
    });
  });
}
