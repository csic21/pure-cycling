import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/app/providers.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_diagnostic_log.dart';
import 'support/test_harness.dart';

/// What the rider sees when something breaks, and where the details go.
///
/// Before this, ten call sites interpolated the exception into the message:
/// a database failure read 「读取失败：SqliteException(11): ...」 and the one
/// thing support needed was the only thing not recorded anywhere. The split
/// these tests lock in is: the screen says what to do, the log keeps the
/// evidence.
void main() {
  late FakeDiagnosticLog log;

  setUp(() => log = FakeDiagnosticLog());

  /// Returns the database: `shutdownApp` has to run inside the test body, not
  /// in a tear-down, or the binding's pending-timer check fires first (see
  /// `test_harness.shutdownApp`).
  Future<AppDatabase> pumpAppWithFailingHistory(WidgetTester tester) async {
    final database = openTestDatabase();
    final location = FakeLocationService();
    useTallSurface(tester);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(database: database, location: location),
          diagnosticLogProvider.overrideWithValue(log),
          // The history list is the simplest screen with a full-screen error
          // branch, and a provider override is the only way to make it fail on
          // purpose — an in-memory SQLite database does not break.
          ridesProvider.overrideWith(
            (ref) => Stream<List<Ride>>.error(
              StateError('disk image is malformed'),
            ),
          ),
        ],
        child: const CyclingApp(),
      ),
    );
    await settle(tester);

    await tester.tap(find.text('记录').last);
    await settle(tester);

    return database;
  }

  testWidgets('a database failure is explained, not dumped on the screen',
      (tester) async {
    final database = await pumpAppWithFailingHistory(tester);

    expect(find.text('读取记录失败'), findsOneWidget);
    expect(find.textContaining('重启应用通常可以恢复'), findsOneWidget);
    expect(
      find.textContaining('disk image is malformed'),
      findsNothing,
      reason: '异常原文是给日志的，不是给骑手的',
    );

    // And there is a way forward rather than a dead end.
    expect(find.text('重试'), findsOneWidget);

    await shutdownApp(tester, database);
  });

  testWidgets('the details are kept where they can be exported',
      (tester) async {
    final database = await pumpAppWithFailingHistory(tester);

    expect(log.content, contains('[history.read]'));
    expect(log.content, contains('disk image is malformed'));

    await shutdownApp(tester, database);
  });

  testWidgets('tapping 重试 asks for the data again instead of giving up',
      (tester) async {
    final database = await pumpAppWithFailingHistory(tester);
    final before = log.content.length;

    await tester.tap(find.text('重试'));
    await settle(tester);

    // The override fails every time, so the notice stays — and the second
    // attempt is recorded too, which is what makes a retry loop diagnosable.
    expect(find.text('读取记录失败'), findsOneWidget);
    expect(log.content.length, greaterThan(before));

    await shutdownApp(tester, database);
  });
}
