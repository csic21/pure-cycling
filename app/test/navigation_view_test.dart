import 'package:cycling_app/core/map/map_providers.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/core/utils/units.dart';
import 'package:cycling_app/features/navigation/domain/navigation_state.dart';
import 'package:cycling_app/features/navigation/presentation/navigation_view.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/shared/widgets/route_map.dart';
import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'the riding map names the road and the way back to the computer',
    (tester) async {
      const instruction = RouteInstruction(
        index: 0,
        maneuver: Maneuver.left,
        text: '左转进入人民大道',
        distanceMeters: 240,
        durationSeconds: 40,
        startPolylineIndex: 0,
        endPolylineIndex: 1,
        roadName: '人民大道',
      );
      final points = [
        const GeoPoint(31.23, 121.47),
        const GeoPoint(31.24, 121.47),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 640,
              child: MapNavigationView(
                navigation: const NavigationSnapshot(
                  routeId: 'r',
                  routeName: '测试',
                  distanceToNextTurnMeters: 240,
                  currentInstruction: instruction,
                ),
                route: Route(id: 'r', name: '测试', points: points),
                tileSource: MapTileSource.osm,
                trackPoints: const [],
                position: points.first,
                bearing: 12,
                formatter: const UnitFormatter(UnitSystem.metric),
                onDismiss: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('人民大道'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
      expect(find.text('左转'), findsNothing);
      expect(find.text('码表'), findsOneWidget);
      expect(find.byIcon(Icons.map_outlined), findsNothing);
      expect(tester.takeException(), isNull);

      final road = tester.getRect(find.text('人民大道'));
      final map = tester.getRect(find.byType(RouteMap));
      expect(road.bottom, lessThan(map.top));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets('a sideways riding map keeps the turn beside the road', (
    tester,
  ) async {
    const instruction = RouteInstruction(
      index: 0,
      maneuver: Maneuver.left,
      text: '左转进入人民大道',
      distanceMeters: 240,
      durationSeconds: 40,
      startPolylineIndex: 0,
      endPolylineIndex: 1,
      roadName: '人民大道',
    );
    final points = [
      const GeoPoint(31.23, 121.47),
      const GeoPoint(31.24, 121.47),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 840,
            height: 320,
            child: MapNavigationView(
              navigation: const NavigationSnapshot(
                routeId: 'r',
                routeName: '测试',
                distanceToNextTurnMeters: 240,
                currentInstruction: instruction,
              ),
              route: Route(id: 'r', name: '测试', points: points),
              tileSource: MapTileSource.osm,
              trackPoints: const [],
              position: points.first,
              bearing: 12,
              formatter: const UnitFormatter(UnitSystem.metric),
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final road = tester.getRect(find.text('人民大道'));
    final map = tester.getRect(find.byType(RouteMap));
    expect(road.right, lessThan(map.left));
    expect(road.center.dy, greaterThan(map.top));
    expect(road.center.dy, lessThan(map.bottom));
    expect(map.height, greaterThan(280));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
