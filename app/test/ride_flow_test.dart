import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/app/providers.dart';
import 'package:cycling_app/app/router.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/core/permissions/notification_permission.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:cycling_app/features/ride/presentation/ride_screen.dart';
import 'package:cycling_app/features/ride/presentation/widgets/ride_controls.dart';
import 'package:cycling_app/features/ride/presentation/widgets/location_notice.dart';
import 'package:cycling_app/features/ride/presentation/widgets/ride_status_bar.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/features/settings/data/settings_repository.dart';
import 'package:cycling_app/shared/widgets/pixel_shift.dart';
import 'package:flutter/material.dart' show NavigationBar, Size;
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
  useTestMapCache();
  late AppDatabase database;

  setUp(() => database = openTestDatabase());

  Future<FakeLocationService> pumpApp(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
  }) async {
    final location = FakeLocationService();
    // These cases are about rides, not about the one-time location notice that
    // precedes the first one — the notice has its own group below, which pumps
    // the tree without this flag.
    await markFirstRunNoticesSeen(database);
    useTallSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(database: database, location: location),
          ...extraOverrides,
        ],
        child: const CyclingApp(),
      ),
    );
    await settle(tester);
    return location;
  }

  group('starting a ride', () {
    testWidgets('the ride screen opens, counts down, then records', (
      tester,
    ) async {
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
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        find.ancestor(
          of: find.byType(RideStatusBar),
          matching: find.byType(PixelShiftScope),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byType(RideControls),
          matching: find.byType(PixelShiftScope),
        ),
        findsOneWidget,
      );

      await shutdownApp(tester, database);
    });

    testWidgets('the dashboard shows the live speed once fixes arrive', (
      tester,
    ) async {
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

    testWidgets('pausing freezes the readout and offers to resume', (
      tester,
    ) async {
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

  group('location notices', () {
    /// Boots the app *without* marking the disclosure as seen — the state a
    /// fresh install is in.
    Future<FakeLocationService> pumpFreshApp(
      WidgetTester tester, {
      bool backgroundAccess = true,
      NotificationPermission? notifications,
    }) async {
      final location = FakeLocationService(backgroundAccess: backgroundAccess);
      useTallSurface(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(
            database: database,
            location: location,
            notifications: notifications,
          ),
          child: const CyclingApp(),
        ),
      );
      await settle(tester);
      return location;
    }

    Future<String?> storedFlag(String key) =>
        SettingsRepository(database).getString(key);

    testWidgets('the disclosure comes before the system dialog, and is kept', (
      tester,
    ) async {
      final location = await pumpFreshApp(
        tester,
        notifications: FakeNotificationPermission(granted: true),
      );

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      // What Play requires before a background-location request, and what the
      // rider needs before a system sheet asks for 「始终允许」.
      expect(find.text('为什么需要「始终允许」定位'), findsOneWidget);
      expect(find.textContaining('锁屏后还要继续记录'), findsOneWidget);
      expect(find.textContaining('轨迹默认只保存在本机'), findsOneWidget);

      await tester.tap(find.text('继续'));
      await settle(tester);

      expect(find.text('准备开始'), findsOneWidget);
      expect(location.permissionRequests, [false, false]);
      expect(
        await storedFlag(LocationNoticeKeys.disclosureSeen),
        LocationNoticeKeys.seen,
        reason: '看过一次就不该再看第二次',
      );

      await shutdownApp(tester, database);
    });

    testWidgets('declining leaves the rider where they were', (tester) async {
      await pumpFreshApp(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.tap(find.text('先不开，我等会儿再骑'));
      await settle(tester);

      // Still on the home screen, and nothing was recorded.
      expect(find.text('开始骑行'), findsOneWidget);
      expect(find.text('准备开始'), findsNothing);
      expect(
        await storedFlag(LocationNoticeKeys.disclosureSeen),
        isNull,
        reason: '没同意就不算看过，下次还要解释',
      );

      await shutdownApp(tester, database);
    });

    testWidgets('a foreground-only grant is called out once', (tester) async {
      await markLocationDisclosureSeen(database);
      final location = await pumpFreshApp(
        tester,
        backgroundAccess: false,
        notifications: FakeNotificationPermission(granted: true),
      );

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      // The failure this prevents: a ride that stops the moment the phone goes
      // into a pocket, discovered at the end of the ride.
      expect(find.text('锁屏后记录可能中断'), findsOneWidget);
      expect(find.textContaining('始终允许'), findsWidgets);

      expect(location.permissionRequests, [false]);
      await tester.tap(find.text('暂时继续'));
      await settle(tester);

      expect(find.text('准备开始'), findsOneWidget);
      expect(location.permissionRequests, [false, false]);
      expect(
        await storedFlag(LocationNoticeKeys.backgroundHintSeen),
        LocationNoticeKeys.seen,
      );

      await shutdownApp(tester, database);
    });

    testWidgets(
      'background access is requested only after the rider chooses it',
      (tester) async {
        await markLocationDisclosureSeen(database);
        final location = await pumpFreshApp(
          tester,
          backgroundAccess: false,
          notifications: FakeNotificationPermission(granted: true),
        );

        await tester.tap(find.text('开始骑行'));
        await settle(tester);
        expect(location.permissionRequests, [false]);

        await tester.tap(find.text('开启始终允许'));
        await settle(tester);
        expect(location.permissionRequests, [false, true, false]);
        expect(find.text('准备开始'), findsOneWidget);

        await shutdownApp(tester, database);
      },
    );

    testWidgets('a full grant is not nagged about', (tester) async {
      await markLocationDisclosureSeen(database);
      await pumpFreshApp(
        tester,
        notifications: FakeNotificationPermission(granted: true),
      );

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      expect(find.text('锁屏后记录可能中断'), findsNothing);
      expect(find.text('准备开始'), findsOneWidget);

      await shutdownApp(tester, database);
    });
    testWidgets('the recording notification is asked for once', (tester) async {
      await markLocationDisclosureSeen(database);
      final notifications = FakeNotificationPermission();
      await pumpFreshApp(tester, notifications: notifications);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      expect(find.text('记录时显示一条通知'), findsOneWidget);
      expect(find.textContaining('唯一方式'), findsOneWidget);

      await tester.tap(find.text('允许通知'));
      await settle(tester);

      expect(notifications.requests, 1);
      expect(find.text('准备开始'), findsOneWidget);
      expect(
        await storedFlag(LocationNoticeKeys.notificationAsked),
        LocationNoticeKeys.seen,
      );

      await shutdownApp(tester, database);
    });

    testWidgets('declining the notification does not block the ride', (
      tester,
    ) async {
      await markLocationDisclosureSeen(database);
      final notifications = FakeNotificationPermission();
      await pumpFreshApp(tester, notifications: notifications);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.tap(find.text('不用通知'));
      await settle(tester);

      expect(notifications.requests, 0, reason: '说不就不，不该再弹系统对话框');
      expect(find.text('准备开始'), findsOneWidget);
      expect(
        await storedFlag(LocationNoticeKeys.notificationAsked),
        LocationNoticeKeys.seen,
        reason: '问过就算问过，不该每趟骑行都问',
      );

      await shutdownApp(tester, database);
    });

    testWidgets('an already-granted notification is not mentioned', (
      tester,
    ) async {
      await markLocationDisclosureSeen(database);
      await pumpFreshApp(
        tester,
        notifications: FakeNotificationPermission(granted: true),
      );

      await tester.tap(find.text('开始骑行'));
      await settle(tester);

      expect(find.text('记录时显示一条通知'), findsNothing);
      expect(find.text('准备开始'), findsOneWidget);

      await shutdownApp(tester, database);
    });
  });

  group('landscape', () {
    testWidgets('the dashboard relayouts sideways instead of overflowing', (
      tester,
    ) async {
      final location = await pumpApp(tester);

      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));
      location.emitRide(count: 30, speedMps: 5);
      await settle(tester);

      // Rotate. A phone on handlebars is often mounted this way, and the
      // portrait stack — hero over its supporting grid — has no room in a
      // frame 360 logical pixels tall.
      tester.view.physicalSize = const Size(2400, 1080);
      await settle(tester);

      // A RenderFlex overflow would have failed this test by now; what is
      // asserted here is that both halves of the readout survived the change.
      expect(find.text('18.0'), findsOneWidget);
      expect(find.text('距离'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);
      // The pause control moves into the right rail, beside the readout,
      // instead of taking a band under it.
      expect(
        tester.getRect(find.text('暂停')).left,
        greaterThan(tester.getRect(find.text('18.0')).right),
      );

      await shutdownApp(tester, database);
    });

    testWidgets('minimal navigation relayouts sideways too', (tester) async {
      await database.routeDao.upsertRoute(
        Route(
          id: 'route-landscape',
          name: '测试路线',
          points: const [
            GeoPoint(39.9042, 116.4074),
            GeoPoint(39.9142, 116.4274),
          ],
          distanceMeters: 1400,
          estimatedDuration: const Duration(minutes: 5),
        ),
      );
      final location = await pumpApp(tester);

      await tester.tap(find.text('路线').last);
      await settle(tester);
      await tester.tap(find.text('测试路线'));
      await settle(tester);
      await tester.tap(find.text('开始导航并记录'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));
      location.emitRide(count: 20, speedMps: 5);
      await settle(tester);

      expect(find.text('剩余'), findsOneWidget);

      tester.view.physicalSize = const Size(2400, 1080);
      await settle(tester);

      // The three bands become three columns: speed, next turn, remaining.
      // Pause sits further right, in the control rail.
      expect(find.text('剩余'), findsOneWidget);
      expect(find.text('预计到达'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);
      expect(
        tester.getRect(find.text('暂停')).left,
        greaterThan(tester.getRect(find.text('剩余')).right),
      );

      await shutdownApp(tester, database);
    });
  });

  group('permission handling', () {
    testWidgets('saved-route navigation asks before starting a session', (
      tester,
    ) async {
      await database.routeDao.upsertRoute(
        Route(
          id: 'permission-route',
          name: '权限路线',
          points: const [
            GeoPoint(39.9042, 116.4074),
            GeoPoint(39.9142, 116.4274),
          ],
          distanceMeters: 1400,
          estimatedDuration: const Duration(minutes: 5),
        ),
      );
      final location = FakeLocationService(
        permission: LocationPermissionStatus.denied,
      );
      await markFirstRunNoticesSeen(database);
      useTallSurface(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(database: database, location: location),
          child: const CyclingApp(),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('路线').last);
      await settle(tester);
      await tester.tap(find.text('权限路线'));
      await settle(tester);
      await tester.tap(find.text('开始导航并记录'));
      await settle(tester);

      expect(location.permissionRequests, [false]);
      expect(find.text('需要定位权限'), findsOneWidget);
      expect(find.text('准备开始'), findsNothing);

      await shutdownApp(tester, database);
    });

    testWidgets(
      'a denied permission is explained before the ride screen opens',
      (tester) async {
        final location = FakeLocationService(
          permission: LocationPermissionStatus.deniedForever,
        );
        // This case is about the refusal dialog, which comes after the notice.
        await markFirstRunNoticesSeen(database);
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
      },
    );

    testWidgets('a disabled location service points at the system toggle', (
      tester,
    ) async {
      final location = FakeLocationService(
        permission: LocationPermissionStatus.serviceDisabled,
      );
      await markFirstRunNoticesSeen(database);
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
    testWidgets('a failed save stays visible and can be retried', (
      tester,
    ) async {
      final repository = _FailOnceRideRepository(database);
      final location = await pumpApp(
        tester,
        extraOverrides: [rideRepositoryProvider.overrideWithValue(repository)],
      );
      await tester.tap(find.text('开始骑行'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));
      location.emitRide(count: 30, speedMps: 5);
      await settle(tester);
      final router = GoRouter.of(tester.element(find.byType(RideScreen)));

      Future<void> drainSave() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await settle(tester);
        }
      }

      await tester.tap(find.text('结束'));
      await settle(tester);
      await tester.tap(find.text('结束').last);
      await drainSave();

      expect(repository.attempts, 1);
      expect(
        router.routerDelegate.currentConfiguration.last.matchedLocation,
        AppRoutes.ride,
      );
      expect(find.text('保存失败，骑行已停止。请重试保存；不要关闭应用。'), findsOneWidget);
      expect(find.text('重试保存'), findsOneWidget);
      final checkpoint = await tester.runAsync(
        () => database.activeRideDao.loadUnfinished(),
      );
      expect(checkpoint, isNotNull);

      await tester.tap(find.text('重试保存'));
      await drainSave();
      final rides = await tester.runAsync(() => database.rideDao.getRides());
      expect(repository.attempts, 2);
      expect(rides, hasLength(1));
      expect(
        router.routeInformationProvider.value.uri.path,
        AppRoutes.rideDetailFor(rides!.single.id),
      );
      expect(
        await tester.runAsync(() => database.activeRideDao.loadUnfinished()),
        isNull,
      );
      expect(find.text('重试保存'), findsNothing);
      expect(tester.takeException(), isNull);

      await shutdownApp(tester, database);
      await location.dispose();
    });

    testWidgets('the system back gesture asks instead of leaving silently', (
      tester,
    ) async {
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

    testWidgets('the home screen shows the recording and offers the way back', (
      tester,
    ) async {
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
    testWidgets('an unfinished ride is offered on the next launch', (
      tester,
    ) async {
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

    testWidgets('finishing an interrupted ride saves it and opens history', (
      tester,
    ) async {
      await seedCheckpoint(database);
      final ride = await seedRide(database, id: 'unfinished', trackPoints: 0);

      final location = await pumpApp(
        tester,
        extraOverrides: [
          selectedMonthProvider.overrideWith((ref) => ride.startedAt.toLocal()),
        ],
      );

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

class _FailOnceRideRepository extends RideRepository {
  _FailOnceRideRepository(super.database);

  int attempts = 0;

  @override
  Future<void> saveFinishedRide(
    Ride ride, {
    List<TrackPoint> unflushed = const [],
  }) async {
    attempts++;
    if (attempts == 1) throw StateError('injected save failure');
    await super.saveFinishedRide(ride, unflushed: unflushed);
  }
}

/// Inserts the checkpoint a crash would leave behind.
Future<void> seedCheckpoint(AppDatabase database) async {
  await database.activeRideDao.save(RideCheckpointFixture.build());
}
