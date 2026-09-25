import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  group('startup', () {
    testWidgets('the app boots and the home screen is the ride screen',
        (tester) async {
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

  group('history', () {
    testWidgets('a recorded ride reaches the list and the month total',
        (tester) async {
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

    testWidgets('a ride with no trace yet still renders its statistics',
        (tester) async {
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

    testWidgets('opening a ride shows its statistics and its trace',
        (tester) async {
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

    testWidgets('a note can be written, and it shows on the detail screen',
        (tester) async {
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

    testWidgets('an existing note is shown, and can be emptied', (tester) async {
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

    testWidgets('a ride with no reported vertical accuracy says so',
        (tester) async {
      // Which is what a phone without a barometer looks like. The climb figure
      // is still shown, but labelled — a rider comparing rides needs to know
      // which numbers are measurements and which are estimates.
      await seedRide(
        database,
        name: '无气压计',
        verticalAccuracy: null,
      );
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

    testWidgets('the dashboard editor previews a page and offers three layouts',
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

      await shutdownApp(tester, database);
    });

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

  group('sync', () {
    testWidgets('reports that the cloud is not configured rather than failing',
        (tester) async {
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
