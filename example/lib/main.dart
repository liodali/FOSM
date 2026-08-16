import 'package:flutter/material.dart';
import 'package:fosm/fosm.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initMap();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FOSM Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MyHomePage(),
    );
  }
}

enum _MapMode { raster, vector }

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const String defaultStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

  int _zoom = 7;
  bool _animateZoom = true; // Toggle for zoom animation
  // TEMP: default vector to reproduce the Chrome issue with console logs.
  _MapMode _mode = _MapMode.vector;

  /// Style URL currently applied to the map (vector mode).
  late String _activeStyleUrl = defaultStyleUrl;
  final TextEditingController _styleUrlController =
      TextEditingController(text: defaultStyleUrl);

  @override
  void dispose() {
    _styleUrlController.dispose();
    super.dispose();
  }

  VectorMapStyle get _vectorStyle => _styleFor(_activeStyleUrl);

  /// The bundled preset for the default URL (stable cache namespace);
  /// anything else gets a namespace derived deterministically from the URL.
  VectorMapStyle _styleFor(String url) {
    if (url == openFreeMapLiberty.styleUrl) return openFreeMapLiberty;
    return VectorMapStyle(id: 'custom-${_stableId(url)}', styleUrl: url);
  }

  void _applyStyleUrl() {
    final url = _styleUrlController.text.trim();
    if (url.isEmpty || url == _activeStyleUrl) return;
    setState(() => _activeStyleUrl = url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FOSM Map')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                // Map fills the area. The key forces a fresh map state when
                // the mode or style URL changes (different tile pipelines).
                KeyedSubtree(
                  key: ValueKey('$_mode|$_activeStyleUrl'),
                  child: MapView(
                    latLng: const LatLng(
                      latitude: 47.4358055,
                      longitude: 8.4737324,
                    ),
                    zoom: 7,
                    minZoom: 1,
                    maxZoom: 19,
                    vectorStyle:
                        _mode == _MapMode.vector ? _vectorStyle : null,
                    showZoomControls: true,
                    animateZoom: _animateZoom, // Control animation
                    zoomAnimationDuration: const Duration(milliseconds: 300),
                    onZoomChanged: (zoom) {
                      setState(() => _zoom = zoom);
                    },
                  ),
                ),

                // Zoom level indicator (top-left)
                Positioned(
                  top: 16,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      'Zoom: $_zoom',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ),

                // Animation toggle (top-right)
                Positioned(
                  top: 16,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.animation,
                            size: 18, color: Colors.black87),
                        const SizedBox(width: 8),
                        const Text(
                          'Animate',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Switch(
                          value: _animateZoom,
                          onChanged: (value) {
                            setState(() => _animateZoom = value);
                          },
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Tile source controls ─────────────────────────────────────
          _buildSourceControls(),
        ],
      ),
    );
  }

  Widget _buildSourceControls() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_MapMode>(
              segments: const [
                ButtonSegment(
                  value: _MapMode.raster,
                  label: Text('Raster (OSM)'),
                  icon: Icon(Icons.image, size: 16),
                ),
                ButtonSegment(
                  value: _MapMode.vector,
                  label: Text('Vector'),
                  icon: Icon(Icons.layers, size: 16),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                setState(() => _mode = selection.first);
              },
              showSelectedIcon: false,
            ),
            if (_mode == _MapMode.vector) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _styleUrlController,
                      enabled: _mode == _MapMode.vector,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Style URL',
                        hintText: defaultStyleUrl,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        prefixIcon: Icon(Icons.link, size: 16),
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      onSubmitted: (_) => _applyStyleUrl(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _applyStyleUrl,
                    child: const Text('Apply'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Default: OpenFreeMap Liberty — any MapLibre style URL works',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.black.withValues(alpha: 0.45),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// FNV-1a 32-bit — a stable (restart-independent) id for custom style URLs,
/// used as the tile-cache namespace.
String _stableId(String input) {
  var hash = 0x811c9dc5;
  for (final byte in input.codeUnits) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
