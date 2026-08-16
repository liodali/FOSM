import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/src/vector/style/style_loader.dart';

void main() {
  test('VectorMapStyle compares by value', () {
    // MapView relies on this to skip style reloads when an equal-but-not
    // identical instance is passed on rebuild.
    const a = VectorMapStyle(id: 'x', styleUrl: 'https://s/x.json');
    const b = VectorMapStyle(id: 'x', styleUrl: 'https://s/x.json');
    const c = VectorMapStyle(id: 'y', styleUrl: 'https://s/x.json');

    expect(a == b, isTrue);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });

  test('openFreeMapLiberty preset points at the Liberty style', () {
    expect(openFreeMapLiberty.styleUrl,
        'https://tiles.openfreemap.org/styles/liberty');
    expect(openFreeMapLiberty.id, 'openfreemap-liberty');
  });
}
