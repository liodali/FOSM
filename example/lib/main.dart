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

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _zoom = 7;
  bool _animateZoom = true; // Toggle for zoom animation

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FOSM Map')),
      body: Stack(
        children: [
          // Map fills the entire body
          MapView(
            latLng: const LatLng(
              latitude: 47.4358055,
              longitude: 8.4737324,
            ),
            zoom: 7,
            minZoom: 1,
            maxZoom: 19,
            showZoomControls: true,
            animateZoom: _animateZoom, // Control animation
            zoomAnimationDuration: const Duration(milliseconds: 300),
            onZoomChanged: (zoom) {
              setState(() => _zoom = zoom);
            },
          ),

          // Zoom level indicator (top-left)
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  const Icon(Icons.animation, size: 18, color: Colors.black87),
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
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
