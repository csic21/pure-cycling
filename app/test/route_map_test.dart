import 'package:cycling_app/core/map/map_providers.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/shared/widgets/route_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a position tick keeps the map tappable', (tester) async {
    final track = <GeoPoint>[
      for (var i = 0; i < 40; i++) GeoPoint(31.2 + i * 0.001, 121.47),
    ];
    GeoPoint? tapped;

    Widget map(GeoPoint position, double? bearing) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 320,
            child: RouteMap(
              tileSource: MapTileSource.osm,
              trackPoints: track,
              position: position,
              bearing: bearing,
              onMapTap: (point) => tapped = point,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(map(track.first, null));
    await tester.pump();

    // Same trace list, new fix. This is what the ride screen does every second.
    track.add(GeoPoint(31.2 + 40 * 0.001, 121.47));
    await tester.pumpWidget(map(track.last, 90));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(RouteMap));
    // A single tap is confirmed only after the double-tap window (250 ms).
    await tester.pump(const Duration(milliseconds: 300));
    expect(tapped, isNotNull);
    expect(find.byIcon(Icons.navigation), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('panning the riding map suspends follow until recenter', (
    tester,
  ) async {
    const rider = GeoPoint(31.23, 121.47);
    final route = <GeoPoint>[
      for (var i = 0; i < 8; i++) GeoPoint(31.23 + i * 0.002, 121.47),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 320,
            child: RouteMap(
              tileSource: MapTileSource.osm,
              routePoints: route,
              position: rider,
              bearing: 20,
              followRider: true,
              routeSnap: rider,
              routeProgressMeters: 0,
              destination: route.last,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.navigation), findsNothing);
    expect(find.byIcon(Icons.place), findsNothing);
    expect(find.byTooltip('回到当前位置'), findsNothing);

    await tester.drag(find.byType(RouteMap), const Offset(-70, -30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byTooltip('回到当前位置'), findsOneWidget);
    await tester.tap(find.byTooltip('回到当前位置'));
    await tester.pump();
    expect(find.byTooltip('回到当前位置'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
