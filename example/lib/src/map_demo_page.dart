import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:fosm/fosm.dart';
import 'package:material_ui/material_ui.dart' show Material, MaterialType;
import 'package:routing_client_dart/routing_client_dart.dart' as routing;

import 'package:example/src/demo_settings.dart';
import 'package:example/src/widgets/map_chrome.dart';
import 'package:example/src/widgets/settings_sheet.dart';

/// Full-screen map demo: an immersive [MapView] with floating forui chrome —
/// brand/mode bar, live status badge, route card, and a grouped tool column.
/// All options live in the settings sheet.
class MapDemoPage extends StatefulWidget {
  const MapDemoPage({super.key, this.tileFetcher});

  /// Optional tile fetcher override (tests use it to avoid the network).
  final TileFetcher? tileFetcher;

  @override
  State<MapDemoPage> createState() => _MapDemoPageState();
}

enum _RouteStyle { solid, dashed, dotted }

class _MapDemoPageState extends State<MapDemoPage> with MapEventListenerMixin {
  static const LatLng initialCenter = LatLng(
    latitude: 47.4358055,
    longitude: 8.4737324,
  );

  /// Demo destination — Zurich Hauptbahnhof. The origin is the current map
  /// center when the route button is pressed.
  static const LatLng _destination = LatLng(
    latitude: 47.3769,
    longitude: 8.5417,
  );

  /// Demo configuration shared with the settings sheet.
  final DemoSettings _settings = DemoSettings();

  /// Fetches and decodes route geometry via OSRM.
  final routing.RoutingManager _routingManager = routing.RoutingManager();

  /// Programmatic control surface for the map.
  final MapController _mapController = MapController();

  final MapLocationController _locations = MapLocationController();
  Timer? _locationTimer;
  bool _simulateLocation = false;

  // Camera state — kept in sync via [MapView.onCameraChanged] so switching
  // tile sources rebuilds the map at the same place.
  LatLng _center = initialCenter;
  int _zoom = 7;
  double _displayZoom = 7;

  /// Demo hard camera constraint — toggled by the bounds tool. `null`
  /// means free panning.
  LatLngBounds? _cameraBounds;

  // ── Route demo state ──────────────────────────────────────────────────
  List<LatLng>? _routePoints;
  Marker? _routeStartMarker;
  Marker? _routeEndMarker;
  String? _routeInfo;
  String? _routeError;
  bool _routeLoading = false;
  _RouteStyle _routeStyle = _RouteStyle.solid;

  // ── Markers ───────────────────────────────────────────────────────────
  // Owned by the page so markers survive raster/vector mode switches.
  late final MarkerManager _markers;

  static const List<Color> _pinColors = [
    Color(0xFFDC2626), // red
    Color(0xFF2563EB), // blue
    Color(0xFF16A34A), // green
    Color(0xFFF59E0B), // amber
  ];

  @override
  void initState() {
    super.initState();
    _markers = MarkerManager()
      ..add(
        Marker(
          point: initialCenter,
          alignment: Alignment.bottomCenter,
          // Follows the marker by default — pan/zoom with it open.
          overlayBuilder: (context) => MarkerInfoCard(
            title: 'Home pin',
            point: initialCenter,
            accent: _pinColors[0],
            onClose: _markers.hideOverlay,
          ),
          child: const Icon(
            FLucideIcons.mapPin,
            size: 36,
            color: Color(0xFFDC2626),
          ),
        ),
      )
      ..add(
        Marker(
          point: const LatLng(latitude: 48.1351, longitude: 11.5820),
          // This one demonstrates config: dismiss on the first camera
          // move, and hang below the marker instead of above.
          overlayConfig: const MarkerOverlayConfig(
            removeOnMove: true,
            anchor: MarkerOverlayAnchor.below,
            offset: Offset(0, 6),
          ),
          overlayBuilder: (context) => MarkerInfoCard(
            title: 'Munich',
            point: const LatLng(latitude: 48.1351, longitude: 11.5820),
            accent: _pinColors[1],
            onClose: _markers.hideOverlay,
          ),
          child: const Text(
            'Munich',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1F2937),
            ),
          ),
        ),
      )
      ..addAll(_buildClusterMarkers());
    _markers.addListener(_onMarkersChanged);
    _settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _locations.dispose();
    _mapController.dispose();
    _markers.removeListener(_onMarkersChanged);
    _settings.removeListener(_onSettingsChanged);
    _settings.dispose();
    super.dispose();
  }

  void _onMarkersChanged() {
    if (mounted) setState(() {});
  }

  void _onSettingsChanged() {
    if (_settings.simulateLocation != _simulateLocation) {
      _setLocationDemo(_settings.simulateLocation);
    }
    if (mounted) setState(() {});
  }

  /// Emits a simulated GPS track walking a small circle near the initial
  /// center; the map follows it until the user drags.
  void _setLocationDemo(bool enabled) {
    _locationTimer?.cancel();
    _simulateLocation = enabled;
    if (!enabled) {
      _locations.stop();
      _locations.clearLocation();
      return;
    }
    var step = 0;
    void emit() {
      final angle = step++ * math.pi / 90;
      _locations.updateLocation(
        MapLocation(
          point: LatLng(
            latitude: initialCenter.latitude + 0.001 * math.sin(angle),
            longitude: initialCenter.longitude + 0.0015 * (1 - math.cos(angle)),
          ),
          accuracyMeters: 12,
          bearing: (angle * 180 / math.pi) % 360,
          timestamp: DateTime.now(),
        ),
      );
    }

    emit();
    _locations.follow();
    _zoom = 16;
    _displayZoom = 16;
    _locationTimer = Timer.periodic(const Duration(seconds: 1), (_) => emit());
  }

  // ── Routing demo ──────────────────────────────────────────────────────

  /// Requests an OSRM route from the current map center to [_destination],
  /// decodes the encoded polyline, and renders it as a [MapPolyline] with
  /// start/end markers.
  Future<void> _fetchRoute() async {
    if (_routeLoading) return;
    setState(() {
      _routeLoading = true;
      _routeInfo = null;
      _routeError = null;
    });
    try {
      final waypoints = [
        routing.LngLat(lng: _center.longitude, lat: _center.latitude),
        routing.LngLat(lng: _destination.longitude, lat: _destination.latitude),
      ];
      final road = await _routingManager.getRoute(
        request: routing.OSRMRequest.route(waypoints: waypoints, steps: false),
      );
      // OSRM's default polyline geometry is precision-5 encoded; decode it
      // into the points FOSM draws.
      final decoded =
          road.polylineEncoded?.decodeGeometry(precision: 5) ??
          road.polyline ??
          const <routing.LngLat>[];
      if (decoded.length < 2) {
        throw Exception('Empty route returned');
      }
      if (!mounted) return;
      setState(() {
        _routePoints = decoded
            .map((p) => LatLng(latitude: p.lat, longitude: p.lng))
            .toList();
        // [Road.distance] is already in km; duration is in seconds.
        _routeInfo =
            '${road.distance.toStringAsFixed(1)} km · '
            '${(road.duration / 60).round()} min';
        _routeLoading = false;
      });
      _showRouteMarkers();
      // Frame the whole route, leaving room for the floating chrome.
      _mapController.fitBounds(
        LatLngBounds.fromPoints(_routePoints!),
        padding: const EdgeInsets.fromLTRB(48, 150, 76, 140),
        animate: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _routeLoading = false;
        _routeError = 'Route failed: $e';
      });
    }
  }

  /// Swaps the route start/end markers for the latest fetched route.
  void _showRouteMarkers() {
    final points = _routePoints!;
    if (_routeStartMarker != null) {
      _markers.remove(_routeStartMarker!);
    }
    if (_routeEndMarker != null) {
      _markers.remove(_routeEndMarker!);
    }
    final startMarker = Marker(
      point: points.first,
      alignment: Alignment.bottomCenter,
      child: const Icon(
        FLucideIcons.circleDot,
        size: 18,
        color: Color(0xFF2563EB),
      ),
    );
    final endMarker = Marker(
      point: points.last,
      alignment: Alignment.bottomCenter,
      child: const Icon(
        FLucideIcons.mapPin,
        size: 28,
        color: Color(0xFF2563EB),
      ),
    );
    _routeStartMarker = startMarker;
    _routeEndMarker = endMarker;
    _markers.addAll([startMarker, endMarker]);
  }

  void _clearRoute() {
    if (_routeStartMarker != null) {
      _markers.remove(_routeStartMarker!);
    }
    if (_routeEndMarker != null) {
      _markers.remove(_routeEndMarker!);
    }
    setState(() {
      _routeStartMarker = null;
      _routeEndMarker = null;
      _routePoints = null;
      _routeInfo = null;
      _routeError = null;
    });
  }

  // ── Markers demo ──────────────────────────────────────────────────────

  /// Sample points around Zurich that cluster when zoomed out.
  List<ClusterMarker> _buildClusterMarkers() {
    const count = 40;
    const latStart = 47.35;
    const latEnd = 47.45;
    const lngStart = 8.45;
    const lngEnd = 8.55;
    final markers = <ClusterMarker>[];
    for (var i = 0; i < count; i++) {
      final t = i / (count - 1);
      final lat = latStart + (latEnd - latStart) * t;
      final lng = lngStart + (lngEnd - lngStart) * ((i * 0.37) % 1.0);
      markers.add(
        ClusterMarker(
          clusterGroup: 'zurich',
          point: LatLng(latitude: lat, longitude: lng),
          alignment: Alignment.bottomCenter,
          overlayBuilder: (context) => MarkerInfoCard(
            title: 'Cluster point ${i + 1}',
            point: LatLng(latitude: lat, longitude: lng),
            accent: _pinColors[2],
            onClose: _markers.hideOverlay,
          ),
          child: const Icon(
            FLucideIcons.circleDot,
            size: 15,
            color: Color(0xFF16A34A),
          ),
        ),
      );
    }
    return markers;
  }

  void _addPinAtCenter() {
    final color = _pinColors[_markers.length % _pinColors.length];
    final point = _center;
    Marker? pin;
    pin = Marker(
      point: point,
      alignment: Alignment.bottomCenter,
      onLongPress: () {
        _showToast('Pin removed');
        _markers.remove(pin!);
      },
      overlayBuilder: (context) => MarkerInfoCard(
        title: 'Pin #${_markers.length + 1}',
        point: point,
        accent: color,
        onClose: _markers.hideOverlay,
      ),
      child: Icon(FLucideIcons.mapPin, size: 36, color: color),
    );
    _markers.add(pin);
  }

  void _addTextAtCenter() {
    _markers.add(
      Marker.text(
        'Marker #${_markers.length + 1}',
        _center,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1F2937),
        ),
      ),
    );
  }

  // ── Vector style ──────────────────────────────────────────────────────

  VectorMapStyle get _vectorStyle => _styleFor(_settings.styleUrl);

  /// The bundled preset for the default URL (stable cache namespace);
  /// anything else gets a namespace derived deterministically from the URL.
  VectorMapStyle _styleFor(String url) {
    if (url == openFreeMapLiberty.styleUrl) return openFreeMapLiberty;
    return VectorMapStyle(id: 'custom-${_stableId(url)}', styleUrl: url);
  }

  // ── Camera tools ──────────────────────────────────────────────────────

  void _toggleBounds() {
    setState(() {
      _cameraBounds = _cameraBounds == null
          ? LatLngBounds(
              southwest: LatLng(
                latitude: initialCenter.latitude - 0.2,
                longitude: initialCenter.longitude - 0.2,
              ),
              northeast: LatLng(
                latitude: initialCenter.latitude + 0.2,
                longitude: initialCenter.longitude + 0.2,
              ),
            )
          : null;
    });
  }

  void _showToast(String message) {
    if (!mounted) return;
    showFToast(
      context: context,
      title: Text(message),
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void onMapReady(MapController controller) {
    _showToast('Map ready');
  }

  @override
  void onMapMarkerTapped(Marker marker) {
    _showToast(
      'Tapped ${marker.point.latitude.toStringAsFixed(3)}, '
      '${marker.point.longitude.toStringAsFixed(3)}',
    );
  }

  @override
  void onMapMarkerClusterTapped(MarkerCluster cluster) {
    _showToast('Cluster: ${cluster.count} markers');
  }

  @override
  void onMapOverlayShown(Marker marker) {
    _showToast('Overlay shown');
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return FScaffold(
      childPad: false,
      // FOSM's built-in controls (zoom, location) use Material ink wells;
      // a transparent Material provides their required ancestor without
      // painting over the map.
      child: Material(
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: _settings,
          builder: (context, _) => Stack(
            children: [
              // Single full-screen map. The key forces a fresh map state when
              // the mode or style URL changes; latLng/zoom restore the camera.
              KeyedSubtree(
                key: ValueKey('${_settings.mode}|${_settings.styleUrl}'),
                child: listenToMap(
                  MapView(
                    controller: _mapController,
                    tileFetcher: widget.tileFetcher,
                    locationController: _simulateLocation ? _locations : null,
                    locationControlAlignment: Alignment.bottomLeft,
                    latLng: _center,
                    zoom: _zoom,
                    enableFractionalZoom: _settings.fractionalZoom,
                    fractionalZoom: _settings.fractionalZoom
                        ? _displayZoom
                        : null,
                    onFractionalZoomChanged: (zoom) =>
                        setState(() => _displayZoom = zoom),
                    minZoom: 1,
                    maxZoom: 19,
                    cameraBounds: _cameraBounds,
                    vectorStyle: _settings.mode == MapMode.vector
                        ? _vectorStyle
                        : null,
                    showZoomControls: true,
                    showScaleBar: _settings.showScaleBar,
                    animateZoom: _settings.animateZoom,
                    enableFling: _settings.enableFling,
                    enableScrollZoom: _settings.enableScrollZoom,
                    zoomAnimationStyle: _settings.zoomStyle,
                    zoomAnimationDuration: const Duration(milliseconds: 300),
                    onZoomChanged: (zoom) => setState(() => _zoom = zoom),
                    onCameraChanged: (center, zoom) {
                      setState(() {
                        _center = center;
                        _zoom = zoom;
                      });
                    },
                    markers: _markers,
                    onTap: (point) => _showToast(
                      'Map: ${point.latitude.toStringAsFixed(4)}, '
                      '${point.longitude.toStringAsFixed(4)}',
                    ),
                    onLongPress: (point) {
                      _markers.add(
                        Marker(
                          point: point,
                          alignment: Alignment.bottomCenter,
                          child: const Icon(
                            FLucideIcons.mapPin,
                            color: Color(0xFFDC2626),
                            size: 32,
                          ),
                        ),
                      );
                      _showToast('Pin added');
                    },
                    polygons: [
                      MapPolygon(
                        points: const [
                          LatLng(latitude: 47.40, longitude: 8.50),
                          LatLng(latitude: 47.40, longitude: 8.58),
                          LatLng(latitude: 47.35, longitude: 8.58),
                          LatLng(latitude: 47.35, longitude: 8.50),
                        ],
                        color: const Color(0x302196F3),
                        onTap: (_) => _showToast('Selected Zurich demo area'),
                      ),
                    ],
                    polylines: [
                      if (_routePoints != null)
                        MapPolyline(
                          points: _routePoints!,
                          onTap: (hit) => _showToast(
                            'Route: ${hit.nearestPoint.latitude.toStringAsFixed(4)}, '
                            '${hit.nearestPoint.longitude.toStringAsFixed(4)}',
                          ),
                          color: const Color(0xFF2563EB),
                          strokeWidth: 6,
                          borderColor: const Color(0xFFFFFFFF),
                          borderWidth: _routeStyle == _RouteStyle.solid
                              ? 2
                              : 1.5,
                          pattern: switch (_routeStyle) {
                            _RouteStyle.solid =>
                              const MapPolylinePattern.solid(),
                            _RouteStyle.dashed =>
                              const MapPolylinePattern.dashed(
                                dashLength: 14,
                                gapLength: 8,
                              ),
                            _RouteStyle.dotted =>
                              const MapPolylinePattern.dotted(spacing: 12),
                          },
                        ),
                    ],
                    markerClusterOptions: _settings.clustering
                        ? MarkerClusterOptions(
                            radius: 64,
                            maxZoom: 14,
                            minSize: 2,
                            zoomOnTap: true,
                            builder: (context, cluster) =>
                                MapClusterBadge(count: cluster.count),
                          )
                        : null,
                  ),
                ),
              ),

              // ── Top chrome: brand, mode tabs, settings, status, route ───
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const MapBrandChip(),
                              const Spacer(),
                              FTabs(
                                scrollable: true,
                                control: FTabControl.lifted(
                                  index: _settings.mode.index,
                                  onChange: (index) => _settings.edit(
                                    (s) => s.mode = MapMode.values[index],
                                  ),
                                ),
                                style: FTabsStyleDelta.delta(spacing: 0),
                                children: const [
                                  FTabEntry(
                                    label: Text('Raster'),
                                    child: SizedBox.shrink(),
                                  ),
                                  FTabEntry(
                                    label: Text('Vector'),
                                    child: SizedBox.shrink(),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 8),
                              MapPanel(
                                padding: const EdgeInsets.all(4),
                                child: MapToolButton(
                                  icon: FLucideIcons.slidersHorizontal,
                                  tooltip: 'Map settings',
                                  onPress: () => showMapSettingsSheet(
                                    context,
                                    settings: _settings,
                                    markers: _markers,
                                    onAddTextMarker: _addTextAtCenter,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          MapStatusChip(
                            icon: FLucideIcons.zoomIn,
                            label:
                                'Zoom '
                                '${_settings.fractionalZoom ? _displayZoom.toStringAsFixed(2) : _zoom}'
                                ' · ${_markers.length} markers',
                          ),
                          if (_routeLoading ||
                              _routeInfo != null ||
                              _routeError != null) ...[
                            const SizedBox(height: 10),
                            MapRouteCard(
                              loading: _routeLoading,
                              summary: _routeInfo,
                              error: _routeError,
                              styleIcon: switch (_routeStyle) {
                                _RouteStyle.solid => FLucideIcons.minus,
                                _RouteStyle.dashed => FLucideIcons.spline,
                                _RouteStyle.dotted => FLucideIcons.grip,
                              },
                              styleTooltip: 'Route style: ${_routeStyle.name}',
                              onCycleStyle: () => setState(() {
                                _routeStyle =
                                    _RouteStyle.values[(_routeStyle.index + 1) %
                                        _RouteStyle.values.length];
                              }),
                              onRetry: _fetchRoute,
                              onDismiss: _clearRoute,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Tool column (above the built-in zoom controls) ──────────
              Positioned(
                right: 16,
                bottom: 132,
                child: MapToolGroup(
                  children: [
                    MapToolButton(
                      icon: FLucideIcons.mapPinPlus,
                      tooltip: 'Add marker at center',
                      iconColor: colors.destructive,
                      onPress: _addPinAtCenter,
                    ),
                    MapToolButton(
                      icon: FLucideIcons.route,
                      tooltip: 'Route to Zürich HB',
                      busy: _routeLoading,
                      onPress: _routeLoading ? null : _fetchRoute,
                    ),
                    MapToolButton(
                      icon: _cameraBounds == null
                          ? FLucideIcons.scan
                          : FLucideIcons.focus,
                      tooltip:
                          'Camera bounds: ${_cameraBounds == null ? 'off' : 'on'}',
                      active: _cameraBounds != null,
                      onPress: _toggleBounds,
                    ),
                    MapToolButton(
                      icon: FLucideIcons.plane,
                      tooltip: 'Fly to Paris',
                      onPress: () => _mapController.moveTo(
                        const LatLng(latitude: 48.8566, longitude: 2.3522),
                        animate: true,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
