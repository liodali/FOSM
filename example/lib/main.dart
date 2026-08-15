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

class MyHomePage extends StatelessWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FOSM Map')),
      body: const MapView(
        latLng: LatLng(
          latitude: 47.4358055,
          longitude: 8.4737324,
        ),
        zoom: 7,
      ),
    );
  }
}
