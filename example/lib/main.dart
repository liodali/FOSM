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
  static const LatLng initialCenter = LatLng(
    latitude: 47.4358055,
    longitude: 8.4737324,
  );

  // Tile source selection
  _MapMode _mode = _MapMode.raster;

  /// Style URL currently applied to the map (vector mode).
  late String _activeStyleUrl = defaultStyleUrl;
  final TextEditingController _styleUrlController =
      TextEditingController(text: defaultStyleUrl);

  // Camera state — kept in sync via [MapView.onCameraChanged] so switching
  // tile sources rebuilds the map at the same place.
  LatLng _center = initialCenter;
  int _zoom = 7;

  bool _animateZoom = true;

  // ── Markers ─────────────────────────────────────────────────────────
  // Owned by the page so markers survive raster/vector mode switches.
  final MarkerManager _markers = MarkerManager()
    ..add(
      const Marker(
        point: initialCenter,
        alignment: Alignment.bottomCenter,
        child: Icon(Icons.location_on, size: 40, color: Colors.red),
      ),
    )
    ..add(
      Marker.text(
        'Munich',
        const LatLng(latitude: 48.1351, longitude: 11.5820),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
      ),
    );

  static const List<Color> _pinColors = [
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
  ];

  @override
  void initState() {
    super.initState();
    _markers.addListener(_onMarkersChanged);
  }

  @override
  void dispose() {
    _markers.removeListener(_onMarkersChanged);
    _styleUrlController.dispose();
    super.dispose();
  }

  void _onMarkersChanged() {
    if (mounted) setState(() {});
  }

  void _addPinAtCenter() {
    final color = _pinColors[_markers.length % _pinColors.length];
    _markers.add(
      Marker(
        point: _center,
        alignment: Alignment.bottomCenter,
        child: Icon(Icons.location_on, size: 40, color: color),
      ),
    );
  }

  void _addTextAtCenter() {
    _markers.add(
      Marker.text(
        'Marker #${_markers.length + 1}',
        _center,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
      ),
    );
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

  /// Rebuilds the map (new key) with the current camera, preserving the
  /// viewport across raster/vector switches. New modes need a fresh
  /// [MapView] state because they use different tile pipelines.
  void _setMode(_MapMode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FOSM Map')),
      body: Stack(
        children: [
          // Single full-screen map. The key forces a fresh map state when
          // the mode or style URL changes; latLng/zoom restore the camera.
          KeyedSubtree(
            key: ValueKey('$_mode|$_activeStyleUrl'),
            child: MapView(
              latLng: _center,
              zoom: _zoom,
              minZoom: 1,
              maxZoom: 19,
              vectorStyle: _mode == _MapMode.vector ? _vectorStyle : null,
              showZoomControls: true,
              animateZoom: _animateZoom,
              zoomAnimationDuration: const Duration(milliseconds: 300),
              onZoomChanged: (zoom) => setState(() => _zoom = zoom),
              onCameraChanged: (center, zoom) {
                setState(() {
                  _center = center;
                  _zoom = zoom;
                });
              },
              markers: _markers,
            ),
          ),

          // Zoom level indicator (top-left)
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                'Zoom: $_zoom · ${_markers.length} markers',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ),
          ),

          // ── Markers button (drops a pin at the current map center)
          Positioned(
            right: 16,
            bottom: 230,
            child: _AddMarkerButton(
              onPressed: _addPinAtCenter,
            ),
          ),

          // ── Layers button (above the zoom controls, Google Maps style)
          Positioned(
            right: 16,
            bottom: 176,
            child: _LayersButton(
              mode: _mode,
              onPressed: () => _showTileOptions(context),
            ),
          ),
        ],
      ),
    );
  }

  void _showTileOptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => _buildSourceControls(),
    );
  }

  Widget _buildSourceControls() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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
              onSelectionChanged: (selection) => _setMode(selection.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.animation, size: 18, color: Colors.black87),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Animate zoom',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.black87,
                    ),
                  ),
                ),
                Switch(
                  value: _animateZoom,
                  onChanged: (value) => setState(() => _animateZoom = value),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.location_on, size: 18, color: Colors.black87),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Markers (${_markers.length})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.black87,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _addTextAtCenter,
                  icon: const Icon(Icons.text_fields, size: 16),
                  label: const Text('Text'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed:
                      _markers.isEmpty ? null : _markers.clear,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Clear'),
                ),
              ],
            ),
            if (_mode == _MapMode.vector) ...[
              const SizedBox(height: 12),
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

/// Floating round button that drops a pin at the current map center.
class _AddMarkerButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _AddMarkerButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: SizedBox(
        width: 44,
        height: 44,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: const Tooltip(
            message: 'Add marker at center',
            child: Icon(
              Icons.add_location_alt,
              size: 22,
              color: Colors.red,
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating round button styled after Google Maps' "layers" button,
/// placed directly above the zoom controls.
class _LayersButton extends StatelessWidget {
  final _MapMode mode;
  final VoidCallback onPressed;

  const _LayersButton({required this.mode, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final isVector = mode == _MapMode.vector;
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: SizedBox(
        width: 44,
        height: 44,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Tooltip(
            message: 'Tile options',
            child: Icon(
              isVector ? Icons.layers : Icons.map,
              size: 22,
              color: Colors.grey[800],
            ),
          ),
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
