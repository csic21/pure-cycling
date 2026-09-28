import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/app/providers.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/elevation/elevation_provider.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/dashboard/presentation/dashboard_view.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/features/settings/data/settings_repository.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:cycling_app/shared/widgets/route_map.dart';
import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/test_harness.dart';

/// End-to-end smoke tests over the real widget tree.
///
/// Everything below the UI is covered by unit tests; these exist because none
/// of that proves the app *renders*. A provider wired to the wrong repository,
/// a screen that throws during build, a route path that does not resolve —
/// all of those compile, all of those pass the domain tests, and all of them
/// produce a white screen on a phone.
///
/// The providers, the router and the screens are real here. Only the database
/// and the location plugin are substituted, because neither exists in a test
/// binding.
void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());
  // Closing in `tearDown` would run after the binding's pending-timer check.
  // `shutdownApp` handles both, in the order that check requires.

  /// Boots the real app against the test database.
  ///
  /// A fake location service is always installed, even by tests that never
  /// start a ride. The route planner calls `currentFix()` from `initState`, and
  /// the real implementation wraps the platform call in an eight-second
  /// timeout — which, in a binding with no location plugin behind it, is still
  /// pending when the test ends and trips the "a timer is still pending"
  /// assertion. The failure surfaces in a test that never asked for a location.
  Future<FakeLocationService> pumpApp(
    WidgetTester tester, {
    FakeNotificationPermission? notifications,
    List<Override> extraOverrides = const [],
  }) async {
    final location = FakeLocationService();
    // These tests are about rides, not about the one-time notices that precede
    // the first one. Those have their own tests in `ride_flow_test.dart`.
    await markFirstRunNoticesSeen(database);
    useTallSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(
            database: database,
            location: location,
            notifications: notifications,
          ),
          ...extraOverrides,
        ],
        child: const CyclingApp(),
      ),
    );
    await settle(tester);
    return location;
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  group('startup', () {
    testWidgets('the app boots and the home screen is the ride screen', (
      tester,
    ) async {
      await pumpApp(tester);

      // The whole point of the home screen: 开始骑行 findable within a second.
      expect(find.text('开始骑行'), findsOneWidget);
      expect(find.text('今天骑车？'), findsOneWidget);
      expect(find.text('路线规划'), findsOneWidget);
      expect(find.text('导入 GPX'), findsOneWidget);

      // The month total renders as zero rather than as a placeholder that
      // never resolves.
      expect(find.text('0.00'), findsOneWidget);
      expect(find.text('最近一次'), findsNothing);

      await shutdownApp(tester, database);
    });

    testWidgets('a fresh database offers no crash recovery', (tester) async {
      await pumpApp(tester);

      // The resume sheet must not appear when there is nothing to resume — a
      // modal on every launch would be a bug in itself.
      expect(find.text('发现未完成的骑行'), findsNothing);

      await shutdownApp(tester, database);
    });
  });

  group('navigation', () {
    testWidgets('all four destinations render', (tester) async {
      await pumpApp(tester);

      await openTab(tester, '路线');
      expect(find.text('还没有保存的路线'), findsOneWidget);

      await openTab(tester, '记录');
      expect(find.text('本月还没有骑行'), findsOneWidget);

      await openTab(tester, '设置');
      expect(find.text('码表'), findsOneWidget);
      expect(find.text('OLED'), findsOneWidget);
      expect(find.text('导航'), findsOneWidget);
      expect(find.text('单位'), findsOneWidget);

      await openTab(tester, '骑行');
      expect(find.text('开始骑行'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('tapping the current tab returns to its root', (tester) async {
      await pumpApp(tester);

      await openTab(tester, '设置');
      // The tile is 页面布局; 码表布局 is the title of the screen it opens.
      await tester.tap(find.text('页面布局'));
      await settle(tester);
      expect(find.text('数据字段'), findsOneWidget);

      // Tapping the tab you are already on pops back to the top of that
      // branch, which is the only way out of a deep settings page without a
      // back gesture.
      await openTab(tester, '设置');
      expect(find.text('数据字段'), findsNothing);
      expect(find.text('码表'), findsOneWidget);

      await shutdownApp(tester, database);
    });
  });

  group('system back', () {
    /// Records the platform calls a back press produces.
    ///
    /// `SystemNavigator.pop` is the whole observable effect of "the app quit"
    /// in a widget test — there is no activity to finish. The binding makes the
    /// same call itself when nothing in the tree claims the back, so asserting
    /// on it also proves the framework did not fall back to quitting on its own
    /// when the app was supposed to stay put.
    List<String> watchForExit(WidgetTester tester) {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      return calls;
    }

    /// Presses the system back button, as Android delivers it, and reports
    /// whether the framework claimed it. `false` is what makes the platform
    /// finish the activity.
    Future<bool> pressBack(WidgetTester tester) async {
      final handled = await tester.binding.handlePopRoute();
      await settle(tester);
      return handled;
    }

    /// The location the shell is showing. The navigation bar is on every
    /// screen the shell owns and is never offstage, unlike the branches behind
    /// the `IndexedStack`.
    String location(WidgetTester tester) =>
        GoRouter.of(tester.element(find.byType(NavigationBar))).state.uri.path;

    testWidgets('back on the ride tab quits the app', (tester) async {
      await pumpApp(tester);
      final calls = watchForExit(tester);

      final handled = await pressBack(tester);

      expect(calls, contains('SystemNavigator.pop'));
      expect(handled, isTrue);

      await shutdownApp(tester, database);
    });

    testWidgets('back on the ride tab quits the app after a settings sub-page', (
      tester,
    ) async {
      await pumpApp(tester);

      // Deep in 设置, back to the ride tab, then leave. This is the state a
      // rider is most likely to be in when they are done, and it used to be
      // the one state where back did nothing at all: the settings branch stays
      // mounted (that is what keeps your place), and go_router's `PopScope` for
      // a branch on a sub-page reports `canPop: false` on the shell route for
      // the rest of the session — which the root navigator answered as
      // "handled", so the platform never got to quit.
      await openTab(tester, '设置');
      await tester.tap(find.text('单位制'));
      await settle(tester);
      await openTab(tester, '骑行');

      final calls = watchForExit(tester);
      final handled = await pressBack(tester);

      expect(calls, contains('SystemNavigator.pop'));
      expect(handled, isTrue);

      await shutdownApp(tester, database);
    });

    testWidgets('back on a secondary tab returns to the ride tab', (
      tester,
    ) async {
      await pumpApp(tester);
      final calls = watchForExit(tester);

      for (final tab in ['路线', '记录', '设置']) {
        await openTab(tester, tab);
        expect(location(tester), isNot('/'));

        await pressBack(tester);

        // The back is spent on the tab, not on the app: the rider lands on the
        // ride tab with the app still running, and a second back is what
        // leaves.
        expect(calls, isNot(contains('SystemNavigator.pop')));
        expect(location(tester), '/');
      }

      await shutdownApp(tester, database);
    });

    testWidgets('back inside a tab pops that tab', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '设置');
      await tester.tap(find.text('单位制'));
      await settle(tester);
      expect(location(tester), '/settings/units');

      final calls = watchForExit(tester);
      await pressBack(tester);

      // The branch's own navigator pops before the shell is ever consulted, so
      // owning back at the shell does not turn every sub-page into a quit.
      expect(location(tester), '/settings');
      expect(calls, isNot(contains('SystemNavigator.pop')));

      await shutdownApp(tester, database);
    });

    testWidgets('back out of the route planner returns to the ride tab', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(find.text('路线规划'));
      await settle(tester);
      expect(location(tester), '/routes/plan');

      final calls = watchForExit(tester);
      await pressBack(tester);

      expect(location(tester), '/');
      expect(calls, isNot(contains('SystemNavigator.pop')));

      // …and the next one leaves. The planner was pushed onto the ride tab's
      // own branch, so this is also the case where the shell decides while a
      // branch behind it still holds a sub-page.
      await pressBack(tester);
      expect(calls, contains('SystemNavigator.pop'));

      await shutdownApp(tester, database);
    });
  });

  group('history', () {
    testWidgets('a recorded ride reaches the list and the month total', (
      tester,
    ) async {
      await seedRide(database);
      await pumpApp(tester);

      // 23820 m is 23.82 km.
      // Shown twice: the month total and the most-recent ride row.
      expect(find.text('23.82'), findsWidgets);

      await openTab(tester, '记录');
      expect(find.text('本月还没有骑行'), findsNothing);
      expect(find.text('1:02:36'), findsWidgets);

      await shutdownApp(tester, database);
    });

    testWidgets('a ride with no trace yet still renders its statistics', (
      tester,
    ) async {
      // A ride pulled down from the cloud arrives as a summary; its trace is
      // fetched lazily. The screen has to be usable in that state.
      await seedRide(database, name: '云端恢复', trackPoints: 0);
      await pumpApp(tester);

      await openTab(tester, '记录');
      await tester.tap(find.text('云端恢复'));
      await settle(tester);

      expect(find.text('骑行详情'), findsOneWidget);
      expect(find.text('移动时间'), findsOneWidget);
      expect(find.text('导出 GPX'), findsOneWidget);
      expect(find.text('导出 FIT'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('opening a ride shows its statistics and its trace', (
      tester,
    ) async {
      await seedRide(database, name: '周末环湖');
      await pumpApp(tester);

      await openTab(tester, '记录');
      await tester.tap(find.text('周末环湖'));
      await settle(tester);

      expect(find.text('骑行详情'), findsOneWidget);
      expect(find.text('移动时间'), findsOneWidget);
      expect(find.text('平均速度'), findsOneWidget);
      expect(find.text('最大速度'), findsOneWidget);
      expect(find.text('爬升'), findsOneWidget);

      // The seeded trace reports ±2.5 m vertical accuracy, so the climb is
      // presented as a measurement rather than hedged as an estimate.
      expect(find.text('爬升（估算）'), findsNothing);

      await shutdownApp(tester, database);
    });

    testWidgets('a note can be written, and it shows on the detail screen', (
      tester,
    ) async {
      await seedRide(database, name: '周末环湖');
      await pumpApp(tester);

      await openTab(tester, '记录');
      await tester.tap(find.text('周末环湖'));
      await settle(tester);

      // The ride has no note yet, so the section is absent rather than empty.
      expect(find.text('备注'), findsNothing);

      await tester.tap(find.byTooltip('更多'));
      await settle(tester);
      await tester.tap(find.text('编辑信息'));
      await settle(tester);

      // The sheet submits both fields, so the name is prefilled rather than
      // blank — an accidental save must not erase it.
      expect(find.text('周末环湖'), findsWidgets);

      await tester.enterText(find.byType(TextField).last, '风大，注意补给');
      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(find.text('备注'), findsOneWidget);
      expect(find.text('风大，注意补给'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('an existing note is shown, and can be emptied', (
      tester,
    ) async {
      await seedRide(database, name: '通勤', notes: '链条有点响');
      await pumpApp(tester);

      await openTab(tester, '记录');
      await tester.tap(find.text('通勤'));
      await settle(tester);

      expect(find.text('链条有点响'), findsOneWidget);

      await tester.tap(find.byTooltip('更多'));
      await settle(tester);
      await tester.tap(find.text('编辑信息'));
      await settle(tester);

      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.text('保存'));
      await settle(tester);

      // Emptied means gone, not "kept because null means leave alone".
      expect(find.text('链条有点响'), findsNothing);

      await shutdownApp(tester, database);
    });

    testWidgets('a ride with no reported vertical accuracy says so', (
      tester,
    ) async {
      // Which is what a phone without a barometer looks like. The climb figure
      // is still shown, but labelled — a rider comparing rides needs to know
      // which numbers are measurements and which are estimates.
      await seedRide(database, name: '无气压计', verticalAccuracy: null);
      await pumpApp(tester);

      await openTab(tester, '记录');
      await tester.tap(find.text('无气压计'));
      await settle(tester);

      expect(find.text('爬升（估算）'), findsOneWidget);
      expect(find.text('下降（估算）'), findsOneWidget);
      expect(find.textContaining('没有提供可靠的高度数据'), findsOneWidget);

      await shutdownApp(tester, database);
    });
  });

  group('settings', () {
    testWidgets('every section opens without throwing', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '设置');

      for (final entry in const [
        ('自动暂停', '骑行'),
        ('页面布局', '码表布局'),
        ('OLED 模式', 'OLED'),
        ('导航偏好', '导航'),
        ('单位制', '单位'),
        ('传感器', '传感器'),
        ('云同步', '云同步'),
      ]) {
        await tester.tap(find.text(entry.$1));
        await settle(tester);

        expect(
          find.text(entry.$2),
          findsWidgets,
          reason: 'tapping ${entry.$1} should open ${entry.$2}',
        );

        await tester.pageBack();
        await settle(tester);
      }

      await shutdownApp(tester, database);
    });

    testWidgets('the lock-screen permission state is visible in 骑行 settings', (
      tester,
    ) async {
      final location = await pumpApp(tester);
      // The state that hurts: a working app that stops recording when the
      // phone goes into a pocket.
      location.backgroundAccess = false;

      await openTab(tester, '设置');
      await tester.tap(find.text('自动暂停'));
      await settle(tester);

      expect(find.text('锁屏继续记录'), findsOneWidget);
      expect(find.textContaining('锁屏后系统可能停止提供位置'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('a full grant reads as granted', (tester) async {
      await pumpApp(tester);

      await openTab(tester, '设置');
      await tester.tap(find.text('自动暂停'));
      await settle(tester);

      expect(find.textContaining('已授权「始终允许」定位'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('the about screen carries the version, policy and licences', (
      tester,
    ) async {
      await pumpApp(
        tester,
        extraOverrides: [
          appVersionProvider.overrideWith((ref) async => '1.2.3'),
        ],
      );

      await openTab(tester, '设置');
      await tester.tap(find.text('关于纯粹骑行'));
      await settle(tester);

      expect(find.text('版本 1.2.3'), findsOneWidget);
      expect(find.text('隐私政策'), findsOneWidget);
      expect(find.textContaining('最近更新'), findsOneWidget);
      expect(find.textContaining('只在你按下「开始骑行」之后'), findsOneWidget);
      expect(find.textContaining('地图瓦片缓存'), findsOneWidget);

      // The policy is long enough that the licences are below the fold on a
      // phone, and a `ListView` does not mount what it never shows.
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await settle(tester);
      expect(find.text('查看使用的开源组件'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('a build with no version says so instead of inventing one', (
      tester,
    ) async {
      await pumpApp(
        tester,
        extraOverrides: [appVersionProvider.overrideWith((ref) async => null)],
      );

      await openTab(tester, '设置');
      await tester.tap(find.text('关于纯粹骑行'));
      await settle(tester);

      expect(find.text('开发版本'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets(
      'a declined notification is visible and leads to the settings',
      (tester) async {
        final notifications = FakeNotificationPermission();
        await pumpApp(tester, notifications: notifications);

        await openTab(tester, '设置');
        await tester.tap(find.text('自动暂停'));
        await settle(tester);

        // Android 13+ hides the foreground-service notification without this
        // grant, and the system dialog can only be shown once — so the row is
        // the way back.
        expect(find.textContaining('未允许'), findsOneWidget);
        await tester.tap(find.text('记录通知'));
        await settle(tester);
        expect(notifications.settingsOpened, isTrue);

        await shutdownApp(tester, database);
      },
    );

    testWidgets(
      'the dashboard editor previews a page and offers three layouts',
      (tester) async {
        await pumpApp(tester);
        await openTab(tester, '设置');
        await tester.tap(find.text('页面布局'));
        await settle(tester);

        expect(find.text('1 大 + 2 小'), findsOneWidget);
        expect(find.text('1 大 + 4 小'), findsOneWidget);
        expect(find.text('2 × 3'), findsOneWidget);
        expect(find.text('数据字段'), findsOneWidget);
        expect(find.text('页面 1'), findsOneWidget);

        // The preview pane is wide and short, but the phone it previews is not:
        // the stacked portrait layout is what the rider will see on a mounted
        // phone, so that is what the preview draws. (A ratio-based layout that
        // trusted width alone would flip this pane to the landscape shape.)
        //
        // Scoped to the preview: 距离 also appears as a field-row label further
        // down the same screen.
        final preview = find.byType(DashboardView);
        final hero = tester.getRect(
          find.descendant(of: preview, matching: find.text('28.6')),
        );
        final label = tester.getRect(
          find.descendant(of: preview, matching: find.text('距离')),
        );
        expect(
          hero.center.dy,
          lessThan(label.center.dy),
          reason: '预览必须是竖屏排布：数字在上，说明在下',
        );

        await shutdownApp(tester, database);
      },
    );

    testWidgets('the OLED screen carries a live preview', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '设置');
      await tester.tap(find.text('OLED 模式'));
      await settle(tester);

      expect(find.text('Pixel Shift'), findsOneWidget);
      expect(find.text('预览'), findsOneWidget);
      // The preview renders a real dashboard, so the hero value is present.
      expect(find.text('28.6'), findsOneWidget);

      await shutdownApp(tester, database);
    });
  });

  group('route planning', () {
    testWidgets('opening the planner does not prompt; current location does', (
      tester,
    ) async {
      final location = await pumpApp(tester);
      location.permission = LocationPermissionStatus.denied;

      await tester.tap(find.text('路线规划'));
      await settle(tester);
      expect(location.permissionRequests, isEmpty);

      await tester.tap(find.byTooltip('更新当前位置'));
      await settle(tester);
      expect(location.permissionRequests, [false]);
      expect(find.text('需要定位权限'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('the planner fits a phone-height viewport', (tester) async {
      await pumpApp(tester);
      tester.view.physicalSize = const Size(1200, 2550);
      await tester.pump();

      await tester.tap(find.text('路线规划'));
      await settle(tester);

      expect(find.text('添加途经点'), findsOneWidget);
      expect(find.byType(RouteMap), findsOneWidget);
      expect(tester.takeException(), isNull);

      await shutdownApp(tester, database);
    });

    testWidgets('says plainly that no map key is configured', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('路线规划'));
      await settle(tester);

      // Without a key the app must not silently produce a straight line as if
      // it were a bike route.
      expect(
        find.textContaining('未配置高德 Key'),
        findsOneWidget,
        reason: 'the degradation has to be visible, not silent',
      );

      await shutdownApp(tester, database);
    });

    testWidgets('can pick both endpoints without place search', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('路线规划'));
      await settle(tester);

      expect(find.text('在地图上点选起点'), findsOneWidget);
      final map = find.byType(RouteMap).first;
      final center = tester.getCenter(map);
      await tester.tapAt(center);
      await settle(tester);
      expect(find.text('在地图上点选终点，点击其他位置可重新选择'), findsOneWidget);

      await tester.tapAt(center + const Offset(60, 0));
      await settle(tester);
      expect(find.text('开始导航并记录'), findsOneWidget);
      expect(find.text('只保存路线'), findsOneWidget);
      expect(find.textContaining('这是直线路径'), findsOneWidget);
      expect(find.byType(RouteMap), findsOneWidget);

      await tester.tap(find.text('重选起点'));
      await settle(tester);
      expect(find.text('在地图上点选新的起点'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.byType(RouteMap)));
      await settle(tester);
      expect(find.text('开始导航并记录'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('GPX import offers both ways in', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('导入 GPX'));
      await settle(tester);

      expect(find.text('从文件中选择'), findsOneWidget);
      expect(find.text('从剪贴板粘贴'), findsOneWidget);
      // Nothing to save until a file has been parsed.
      expect(find.text('保存为路线'), findsNothing);

      await shutdownApp(tester, database);
    });
  });

  group('route elevation', () {
    Future<void> seedRoute(AppDatabase database) =>
        database.routeDao.upsertRoute(
          Route(
            id: 'route-elevation',
            name: '有坡的路线',
            points: [
              for (var i = 0; i < 80; i++)
                GeoPoint(39.9 + i / 1000, 116.4 + i / 1000),
            ],
            distanceMeters: 12000,
            estimatedDuration: const Duration(minutes: 45),
          ),
        );

    testWidgets('a profile appears when the rider has allowed it', (
      tester,
    ) async {
      await SettingsRepository(
        database,
      ).save(const AppSettings(routeElevation: true));
      await seedRoute(database);

      await pumpApp(
        tester,
        extraOverrides: [
          elevationProviderProvider.overrideWithValue(FakeElevation()),
        ],
      );

      await openTab(tester, '路线');
      await tester.tap(find.text('有坡的路线'));
      await settle(tester);

      expect(find.text('海拔剖面'), findsOneWidget);
      // 80 samples climbing 2 m each: the accumulator counts the leg.
      expect(find.text('爬升'), findsOneWidget);
      expect(find.textContaining('Fake（测试）'), findsOneWidget);

      await shutdownApp(tester, database);
    });

    testWidgets('nothing is asked for while the setting is off', (
      tester,
    ) async {
      await seedRoute(database);

      // The real provider chain, with the setting at its default: the null
      // provider is selected, and no request can happen.
      await pumpApp(tester);

      await openTab(tester, '路线');
      await tester.tap(find.text('有坡的路线'));
      await settle(tester);

      expect(find.text('海拔剖面'), findsNothing);
      expect(
        find.textContaining('不包含海拔数据'),
        findsOneWidget,
        reason: '关掉时要说清为什么是 —，以及去哪里打开',
      );

      await shutdownApp(tester, database);
    });
  });

  group('sync', () {
    testWidgets('reports that the cloud is not configured rather than failing', (
      tester,
    ) async {
      await pumpApp(tester);
      await openTab(tester, '设置');
      await tester.tap(find.text('云同步'));
      await settle(tester);

      // No Supabase credentials are compiled into a test build. The screen has
      // to explain that, not show a login form that cannot work.
      expect(find.text('云同步未启用'), findsOneWidget);
      expect(find.textContaining('本地'), findsWidgets);

      await shutdownApp(tester, database);
    });
  });
}

/// A terrain service that answers with a steady climb.
///
/// Overridden at the provider seam, so the test exercises the sampling, the
/// accumulator and the screen without a network call.
class FakeElevation implements ElevationProvider {
  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake（测试）';

  @override
  bool get isConfigured => true;

  @override
  Future<List<double?>> heights(List<GeoPoint> points) async => [
    for (var i = 0; i < points.length; i++) 100.0 + i * 2.0,
  ];
}
