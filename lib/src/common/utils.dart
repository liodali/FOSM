import 'package:fosm/src/common/cache_tile_mixin.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// Standard OSM tile size in logical pixels.
const tileWidth = 256;

/// Standard OSM tile size in logical pixels.
const tileHeight = 256;

/// Initializes the Hive tile cache. **Must be called once** before using
/// [MapView] — typically in `main()`:
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await initMap();
///   runApp(MyApp());
/// }
/// ```
///
/// If this is skipped, the map still works but tiles are fetched from the
/// network on every pan (no persistent cache).
Future<void> initMap() async {
  await Hive.initFlutter();
  await CacheTiles.initCache();
}
