import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/app/router.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/features/ride/presentation/ride_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/test_harness.dart';

/// The recording flow, end to end through the real widget tree.
///
/// This is the test the fake location service exists for. Everything it covers
/// has unit tests underneath — the engine, the filter, the distance
/// accumulator, the recorder's persistence — but none of those prove the
/// pieces are connected. A `RideRecorder` that never subscribes to the
/// location stream passes every unit test in the project and records nothing.
void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());

  Future<FakeLocationService> pumpApp(WidgetTester tester) async {
    final location = FakeLocationService();
    useTallSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(database: database, location: location),
        child: const CyclingApp(),
      ),
    );
    await settle(tester);
    return location;
  }

  group('starting a ride', () {
    testWidgets('the ride screen opens, counts down, then records',
        (tester) async {
      final location = await pumpApp(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      // The engine enters `preparing` and the countdown takes over the screen.
      // The GPS readout is part of the countdown on purpose: the three seconds
      // are otherwise dead time, and they are exactly the window in which a
      // fix is being acquired.
      expect(find.text('准备开始'), findsOneWidget);
      expect(find.text('正在获取定位…'), findsOneWidget);
      expect(find.text('立即开始'), findsOneWidget);

      // The recorder subscribed to the location stream during start-up. If it
      // had not, every fix below would go nowhere.
      expect(
        location.streamOpened,
        isTrue,
        reason: 'the recorder must subscribe to the fix stream',
      );

      // A fix arrives, then the countdown expires.
      location.emitRide(count: 1, speedMps: 5);
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);

      // Recording: the dashboard is up and the controls are the gloved-thumb
      // sized ones the spec asks for.
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('结束'), findsOneWidget);
      expect(find.text('准备开始'), findsNothing);

      await shutdownApp(tester, database);
    });

    testWidgets('the dashboard shows the live speed once fixes arrive',
        (tester) async {
      final location = await pumpApp(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));

      // 5 m/s is 18 km/h. Enough fixes to clear the distance gate and let the
      // smoothed speed settle.
      location.emitRide(count: 30, speedMps: 5);
      await settle(tester);

      // 5 m/s is 18.0 km/h.
      expect(find.text('18.0'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('pausing freezes the readout and offers to resume',
        (tester) async {
      final location = await pumpApp(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));

      location.emitRide(count: 30, speedMps: 5);
      await settle(tester);

      await tester.tap(find.text('暂停'));
      await settle(tester);

      expect(find.text('继续'), findsOneWidget);
      expect(find.text('暂停'), findsNothing);

      await tester.tap(find.text('继续'));
      await settle(tester);

      expect(find.text('暂停'), findsOneWidget);

      await shutdownApp(tester, database);
    });

  });

  group('permission handling', () {
    testWidgets('a denied permission is explained before the ride screen opens',
        (tester) async {
      final location = FakeLocationService(
        permission: LocationPermissionStatus.deniedForever,
      );
      useTallSurface(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(database: database, location: location),
          child: const CyclingApp(),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      // The rider is told why, and offered the one action that can fix it,
      // rather than being left on a screen that looks inert.
      expect(find.text('定位权限已被拒绝'), findsOneWidget);
      expect(find.textContaining('系统设置'), findsOneWidget);
      expect(find.text('打开设置'), findsOneWidget);

      // 打开设置 opens the system settings page, which is the only action
      // that can fix a permanently denied permission.
      await tester.tap(find.text('打开设置'));
      await settle(tester);
      expect(location.appSettingsOpened, isTrue);

      await shutdownApp(tester, database);
    });

    testWidgets('a disabled location service points at the system toggle',
        (tester) async {
      final location = FakeLocationService(
        permission: LocationPermissionStatus.serviceDisabled,
      );
      useTallSurface(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(database: database, location: location),
          child: const CyclingApp(),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      expect(find.text('系统定位服务未开启'), findsOneWidget);

      await shutdownApp(tester, database);
    });
  });

  group('leaving a ride in progress', () {
    testWidgets('the system back gesture asks instead of leaving silently',
        (tester) async {
      final location = await pumpApp(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));
      location.emitRide(count: 30, speedMps: 5);
      await settle(tester);
      expect(find.text('暂停'), findsOneWidget);

      // Android's back gesture. It used to pop the ride screen without a word:
      // the ride kept recording, the home screen said 开始骑行, and the only
      // hint was a button that was lying.
      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.text('结束并保存'), findsOneWidget);
      expect(find.text('放弃这次骑行'), findsOneWidget);

      // 继续骑行 really continues: the sheet is not a disguised stop.
      await tester.tap(find.text('继续骑行'));
      await settle(tester);
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('结束'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('the home screen shows the recording and offers the way back',
        (tester) async {
      final location = await pumpApp(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));
      location.emitRide(count: 30, speedMps: 5);
      await settle(tester);

      // Programmatic navigation is the remaining way out of the ride screen —
      // a deep link, or a future screen calling `go`. The home screen has to
      // tell the truth about the ride that is still running.
      final context = tester.element(find.byType(RideScreen));
      GoRouter.of(context).go(AppRoutes.home);
      await settle(tester);

      expect(find.text('正在记录'), findsOneWidget);
      expect(find.text('返回骑行'), findsOneWidget);
      expect(
        find.text('开始骑行'),
        findsNothing,
        reason: 'offering a second start would tear down the running engine',
      );

      await tester.tap(find.text('返回骑行'));
      await settle(tester);

      expect(find.text('暂停'), findsOneWidget);

      // Exactly one ride row exists: the one still recording. A second tap on
      // 开始骑行 would have produced a second one.
      final rides = await tester.runAsync(() => database.rideDao.getRides());
      expect(rides, hasLength(1));

      await shutdownApp(tester, database);
    });
  });

  group('crash recovery', () {
    testWidgets('an unfinished ride is offered on the next launch',
        (tester) async {
      // What a crash leaves behind: a checkpoint row and a partial trace.
      await seedCheckpoint(database);
      await seedRide(database, id: 'unfinished', trackPoints: 0);

      await pumpApp(tester);

      // The sheet leads with the numbers already recorded, because the first
      // thing a rider wants to know is whether their ride survived.
      expect(find.text('发现未完成的骑行'), findsOneWidget);
      expect(find.text('继续这次骑行'), findsOneWidget);
      expect(find.text('结束并保存'), findsOneWidget);
      expect(find.textContaining('已记录的数据都在'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('finishing an interrupted ride saves it and opens history',
        (tester) async {
      await seedCheckpoint(database);
      await seedRide(database, id: 'unfinished', trackPoints: 0);

      final location = await pumpApp(tester);

      await tester.tap(find.text('结束并保存'));

      // Stopping runs a chain of awaited writes — flush the trace, clear the
      // checkpoint, cancel the location subscription, commit the ride, re-read
      // it. That chain is real asynchronous work, and `runAsync` is the only
      // way to let it drain inside a widget test: the fake-async zone schedules
      // timers and flushes microtasks, but it does not advance the event loop
      // the database and the file system actually complete on.
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await settle(tester);
      }

      // The rider lands in history with the ride they nearly lost.
      expect(find.text('本月还没有骑行'), findsNothing);

      final saved = await tester.runAsync(() => database.rideDao.getRides());
      expect(saved, isNotEmpty);

      await location.dispose();
      await shutdownApp(tester, database);
    });
  });
}

/// Inserts the checkpoint a crash would leave behind.
Future<void> seedCheckpoint(AppDatabase database) async {
  await database.activeRideDao.save(
    RideCheckpointFixture.build(),
  );
}
