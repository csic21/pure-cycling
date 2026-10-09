import 'dart:async';

import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/app/providers.dart';
import 'package:cycling_app/app/router.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/updates/github_release_checker.dart';
import 'package:cycling_app/core/updates/update_coordinator.dart';
import 'package:cycling_app/core/updates/update_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/test_harness.dart';

void main() {
  useTestMapCache();
  late AppDatabase database;
  late Completer<AppRelease?> response;
  late AppUpdateCoordinator coordinator;
  var checks = 0;
  final release = AppRelease(
    version: '0.1.18',
    tag: 'v0.1.18',
    notes: '',
    pageUrl: Uri.parse(
      'https://github.com/csic21/pure-cycling/releases/tag/v0.1.18',
    ),
    androidApkUrl: Uri.parse(
      'https://github.com/csic21/pure-cycling/releases/download/v0.1.18/app.apk',
    ),
  );
  setUp(() {
    database = openTestDatabase();
    response = Completer<AppRelease?>();
    checks = 0;
    coordinator = AppUpdateCoordinator(
      loadRelease: (_) {
        checks++;
        return response.future;
      },
    );
  });

  Future<ProviderContainer> startCheck(WidgetTester tester) async {
    await markFirstRunNoticesSeen(database);
    useTallSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(database: database, location: FakeLocationService()),
          appUpdateCoordinatorProvider.overrideWithValue(coordinator),
        ],
        child: const CyclingApp(),
      ),
    );
    await settle(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CyclingApp)),
    );
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(checks, 1);
    return container;
  }

  Future<void> dismissAndShutdown(WidgetTester tester) async {
    expect(find.text('发现新版本 0.1.18'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await settle(tester);
    await shutdownApp(tester, database);
  }

  testWidgets(
    'host defers late response while recording and resumes after stop',
    (tester) async {
      final container = await startCheck(tester);
      final started = container.read(rideSessionProvider.notifier).start();
      await settle(tester);
      expect(await started, isTrue);
      expect(container.read(rideSessionProvider).ride.isRecording, isTrue);
      response.complete(release);
      await settle(tester);
      expect(find.text('发现新版本 0.1.18'), findsNothing);
      final stopped = container.read(rideSessionProvider.notifier).stop();
      await settle(tester);
      await stopped;
      expect(checks, 1);
      await dismissAndShutdown(tester);
    },
  );

  testWidgets(
    'host defers late response in background and resumes in foreground',
    (tester) async {
      await startCheck(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      response.complete(release);
      await settle(tester);
      expect(find.text('发现新版本 0.1.18'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await settle(tester);
      expect(checks, 1);
      await dismissAndShutdown(tester);
    },
  );

  testWidgets('host defers on a newer route and resumes on a safe tab', (
    tester,
  ) async {
    await startCheck(tester);
    final router = GoRouter.of(tester.element(find.text('今天骑车？')));
    router.go(AppRoutes.routePlan);
    await settle(tester);
    response.complete(release);
    await settle(tester);
    expect(find.text('发现新版本 0.1.18'), findsNothing);
    router.go(AppRoutes.home);
    await settle(tester);
    expect(checks, 1);
    await dismissAndShutdown(tester);
  });
  for (final rootNavigator in [false, true]) {
    testWidgets(
      'same-tab modal dismissal wakes deferred update (root=$rootNavigator)',
      (tester) async {
        await startCheck(tester);
        final context = tester.element(find.text('今天骑车？'));
        unawaited(
          showModalBottomSheet<void>(
            context: context,
            useRootNavigator: rootNavigator,
            builder: (sheetContext) => TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('关闭测试提示'),
            ),
          ),
        );
        await settle(tester);
        response.complete(release);
        await settle(tester);
        expect(find.text('发现新版本 0.1.18'), findsNothing);
        await tester.tap(find.text('关闭测试提示'));
        await settle(tester);
        expect(checks, 1);
        await dismissAndShutdown(tester);
      },
    );
  }
}
