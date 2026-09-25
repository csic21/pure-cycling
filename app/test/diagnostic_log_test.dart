import 'dart:io';

import 'package:cycling_app/core/diagnostics/diagnostic_log.dart';
import 'package:cycling_app/core/diagnostics/error_reporting.dart';
import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/app/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_harness.dart';

/// The app has no crash-reporting SDK, so this file *is* the support story:
/// when something goes wrong, the record has to exist, has to be findable, and
/// must never be the thing that makes a bad situation worse.
void main() {
  late Directory tempDir;
  late DiagnosticLog log;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('purecycling_log_test');
    log = DiagnosticLog(directory: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('the log', () {
    test('records the source, the error and the stack', () async {
      await log.error(
        'flutter',
        StateError('boom'),
        StackTrace.fromString('#0  main (app.dart:1)'),
      );

      final content = await log.read();
      expect(content, contains('[flutter]'));
      expect(content, contains('Bad state: boom'));
      expect(content, contains('app.dart:1'));
      expect(await log.sizeBytes(), greaterThan(0));
    });

    test('appends rather than replacing', () async {
      await log.error('zone', 'first failure', null);
      await log.error('platform', 'second failure', null);

      final content = await log.read();
      expect(content, contains('first failure'));
      expect(content, contains('second failure'));
    });

    test('drops the oldest entries instead of growing without bound', () async {
      final small = DiagnosticLog(directory: tempDir, maxBytes: 4096);

      for (var i = 0; i < 200; i++) {
        await small.error('zone', 'failure number $i', null);
      }

      final size = await small.sizeBytes();
      expect(size, lessThanOrEqualTo(4096));

      // The newest entry survives; the oldest does not. A log that keeps the
      // beginning and loses the end would be useless for the one case it
      // exists for.
      final content = await small.read();
      expect(content, contains('failure number 199'));
      expect(content, isNot(contains('failure number 0\n')));
    });

    test('never throws when it cannot write', () async {
      // A directory path that cannot be created, because a file is in the way.
      final blocker = File('${tempDir.path}/not-a-directory')
        ..writeAsStringSync('x');
      final broken = DiagnosticLog(
        directory: Directory('${blocker.path}/diagnostics'),
      );

      // None of these may throw: the log is a convenience, and an app that
      // cannot write it is still a working app.
      await broken.init();
      await broken.error('zone', 'anything', null);
      expect(await broken.read(), '');
      expect(await broken.sizeBytes(), 0);
      await broken.clear();
    });

    test('clear() forgets everything', () async {
      await log.error('zone', 'boom', null);
      await log.clear();

      expect(await log.read(), isEmpty);
      expect(await log.sizeBytes(), 0);
    });
  });

  group('the fatal error screen', () {
    testWidgets('renders without a MaterialApp and promises the ride is safe',
        (tester) async {
      // ErrorWidget.builder runs where the tree has already failed, so this
      // widget gets no Theme, no Directionality and no Localizations from
      // above. It must stand on its own.
      await tester.pumpWidget(
        buildFatalErrorView(
          FlutterErrorDetails(exception: StateError('widget blew up')),
        ),
      );

      expect(find.text('界面出错了'), findsOneWidget);
      expect(find.textContaining('骑行记录不受影响'), findsOneWidget);
      expect(find.textContaining('诊断日志'), findsOneWidget);
      expect(find.textContaining('Bad state: widget blew up'), findsOneWidget);
    });
  });

  group('the diagnostics screen', () {
    // The screen is tested against an in-memory log, not the real one: real
    // file IO never completes inside a widget test's fake-async zone, and a
    // widget whose future never resolves looks like a hung screen. The file
    // system itself is covered by the plain tests above.
    late FakeDiagnosticLog fakeLog;

    setUp(() => fakeLog = FakeDiagnosticLog());

    testWidgets('says there is nothing to export before anything fails',
        (tester) async {
      final database = openTestDatabase();
      useTallSurface(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...testOverrides(database: database),
            diagnosticLogProvider.overrideWithValue(fakeLog),
          ],
          child: const CyclingApp(),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('设置').last);
      await settle(tester);
      await tester.tap(find.text('诊断日志'));
      await settle(tester);

      expect(find.text('还没有记录'), findsOneWidget);
      // Nothing to export, so the button is inert rather than producing an
      // empty file the rider then has to explain.
      final export = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '导出日志'),
      );
      expect(export.onPressed, isNull);

      await shutdownApp(tester, database);
    });

    testWidgets('shows the size and clears the log', (tester) async {
      // 2 KB, so the assertion is about a real reading rather than about a
      // rounding artefact.
      fakeLog.content = 'x' * 2048;

      final database = openTestDatabase();
      useTallSurface(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...testOverrides(database: database),
            diagnosticLogProvider.overrideWithValue(fakeLog),
          ],
          child: const CyclingApp(),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('设置').last);
      await settle(tester);
      await tester.tap(find.text('诊断日志'));
      await settle(tester);

      expect(find.text('2.0 KB'), findsOneWidget);

      await tester.tap(find.text('清空日志'));
      await settle(tester);
      await tester.tap(find.text('清空'));
      await settle(tester);

      expect(find.text('还没有记录'), findsOneWidget);
      expect(fakeLog.content, isEmpty);

      await shutdownApp(tester, database);
    });
  });
}

/// A log that lives in memory, for the screen tests.
class FakeDiagnosticLog extends DiagnosticLog {
  String content = '';

  @override
  Future<void> init() async {}

  @override
  Future<void> error(String source, Object error, StackTrace? stack) async {
    content = '$content[$source] $error\n';
  }

  @override
  Future<String> read() async => content;

  @override
  Future<int> sizeBytes() async => content.length;

  @override
  Future<void> clear() async => content = '';
}
