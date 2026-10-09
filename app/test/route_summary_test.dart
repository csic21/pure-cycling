import 'package:cycling_app/app/providers.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/features/routes/presentation/routes_screen.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('summary query ignores geometry/instructions and tombstones', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final now = DateTime.utc(2026, 10, 9);
    for (final id in ['old', 'new', 'favorite', 'deleted']) {
      await db.routeDao.upsertRoute(
        Route(
          id: id,
          name: id,
          points: const [GeoPoint(31, 121), GeoPoint(31.01, 121.01)],
          distanceMeters: 1200,
          estimatedDuration: const Duration(minutes: 4),
          elevationGainMeters: 12,
          favorite: id == 'favorite',
          updatedAt: id == 'old' ? now.subtract(const Duration(days: 1)) : now,
          deletedAt: id == 'deleted' ? now : null,
        ),
      );
    }
    // A full Route cannot decode these payloads. Metadata must still load:
    // selecting/decoding a route then trimming it is not a summary query.
    await db
        .update(db.savedRoutes)
        .write(
          const SavedRoutesCompanion(
            geometryJson: Value('invalid geometry'),
            instructionsJson: Value('invalid instructions'),
          ),
        );
    final summaries = await db.routeDao.watchRouteSummaries().first;
    expect(summaries.map((r) => r.id), ['favorite', 'new', 'old']);
    expect(summaries.first.distanceMeters, 1200);
    expect(summaries.first.estimatedDuration, const Duration(minutes: 4));
    expect(summaries.first.elevationGainMeters, 12);
    expect(summaries.first.favorite, isTrue);
  });

  testWidgets(
    'route list lazily builds rows and navigates with the summary id',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/routes',
        routes: [
          GoRoute(path: '/routes', builder: (_, _) => const RoutesScreen()),
          GoRoute(
            path: '/routes/:id',
            builder: (_, state) =>
                Scaffold(body: Text('detail ${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      final rows = [
        for (var i = 0; i < 1000; i++)
          RouteSummary(
            id: 'route-$i',
            name: '路线 $i',
            distanceMeters: 1000,
            estimatedDuration: const Duration(minutes: 3),
            favorite: i < 2,
          ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSettingsProvider.overrideWithValue(const AppSettings()),
            savedRoutesProvider.overrideWith((ref) => Stream.value(rows)),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('全部路线'), findsOneWidget);
      expect(find.text('路线 0'), findsOneWidget);
      expect(find.text('路线 999'), findsNothing);
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await tester.tap(find.text('路线 0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('detail route-0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
