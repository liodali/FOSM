import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';

void main() {
  group('MarkerLayer clustering', () {
    const center = LatLng(latitude: 0.0, longitude: 0.0);

    MarkerManager clusteredManager() {
      final manager = MarkerManager();
      manager.addAll([
        ClusterMarker(
          point: const LatLng(latitude: 0.0, longitude: 0.0),
          child: const SizedBox(width: 20, height: 20),
        ),
        ClusterMarker(
          point: const LatLng(latitude: 0.0001, longitude: 0.0001),
          child: const SizedBox(width: 20, height: 20),
        ),
      ]);
      return manager;
    }

    Future<void> pumpAndSettle(WidgetTester tester) async {
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    Widget app({required int zoom, required MarkerManager markers}) {
      return MaterialApp(
        home: Scaffold(
          body: MapView(
            latLng: center,
            zoom: zoom,
            markers: markers,
            markerClusterOptions: const MarkerClusterOptions(radius: 64),
          ),
        ),
      );
    }

    testWidgets('renders cluster badge at low zoom', (tester) async {
      final markers = clusteredManager();
      await tester.pumpWidget(app(zoom: 7, markers: markers));
      await pumpAndSettle(tester);

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('renders individual markers at high zoom', (tester) async {
      final markers = clusteredManager();
      await tester.pumpWidget(app(zoom: 16, markers: markers));
      await pumpAndSettle(tester);

      expect(find.text('2'), findsNothing);
    });

    testWidgets('tapping cluster invokes callback', (tester) async {
      final markers = clusteredManager();
      MarkerCluster? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              latLng: center,
              zoom: 7,
              markers: markers,
              markerClusterOptions: MarkerClusterOptions(
                radius: 64,
                zoomOnTap: false,
                onTap: (cluster) => tapped = cluster,
                builder: (context, cluster) => Container(
                  key: Key('cluster-${cluster.count}'),
                  width: 40,
                  height: 40,
                  color: Colors.green,
                  alignment: Alignment.center,
                  child: Text('${cluster.count}'),
                ),
              ),
            ),
          ),
        ),
      );
      await pumpAndSettle(tester);

      await tap(tester, find.byKey(const Key('cluster-2')));

      expect(tapped, isNotNull);
      expect(tapped!.count, 2);
    });

    testWidgets('cluster tap dispatches notification', (tester) async {
      final markers = clusteredManager();
      MarkerCluster? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<MapNotification>(
              onNotification: (notification) {
                if (notification is MapMarkerClusterTapNotification) {
                  tapped = notification.cluster;
                }
                return true;
              },
              child: MapView(
                latLng: center,
                zoom: 7,
                markers: markers,
                markerClusterOptions: MarkerClusterOptions(
                  radius: 64,
                  zoomOnTap: false,
                  builder: (context, cluster) => Container(
                    key: Key('cluster-${cluster.count}'),
                    width: 40,
                    height: 40,
                    color: Colors.green,
                    alignment: Alignment.center,
                    child: Text('${cluster.count}'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await pumpAndSettle(tester);

      await tap(tester, find.byKey(const Key('cluster-2')));

      expect(tapped, isNotNull);
      expect(tapped!.count, 2);
    });

    testWidgets('plain marker remains visible beside clusters', (tester) async {
      final markers = MarkerManager()
        ..add(
          Marker(
            point: const LatLng(latitude: 0.0002, longitude: 0.0002),
            child: Container(
              width: 20,
              height: 20,
              color: Colors.blue,
              key: const Key('plain-marker'),
            ),
          ),
        )
        ..addAll([
          ClusterMarker(
            point: const LatLng(latitude: 0.0, longitude: 0.0),
            child: const SizedBox(width: 20, height: 20),
          ),
          ClusterMarker(
            point: const LatLng(latitude: 0.0001, longitude: 0.0001),
            child: const SizedBox(width: 20, height: 20),
          ),
        ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              latLng: center,
              zoom: 7,
              markers: markers,
              markerClusterOptions: const MarkerClusterOptions(radius: 64),
            ),
          ),
        ),
      );
      await pumpAndSettle(tester);

      expect(find.byKey(const Key('plain-marker')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });
}
