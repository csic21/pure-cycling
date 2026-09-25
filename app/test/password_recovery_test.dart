import 'package:cycling_app/app/app.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/features/auth/data/auth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/test_harness.dart';

/// The half of password reset that happens inside the app.
///
/// The link proves the rider owns the address and signs them in; it does not
/// change the password. Before this flow existed the app treated the recovery
/// session as a finished reset: the rider saw a signed-in account and the old
/// password still opened it. That is a security bug wearing the costume of a
/// success state, and this file is what keeps it fixed.
void main() {
  late AppDatabase database;
  late FakeAuthRepository auth;

  setUp(() {
    database = openTestDatabase();
    auth = FakeAuthRepository();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final location = FakeLocationService();
    useTallSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          database: database,
          location: location,
          auth: auth,
        ),
        child: const CyclingApp(),
      ),
    );
    await settle(tester);
  }

  Future<void> shutdown(WidgetTester tester) async {
    await shutdownApp(tester, database);
    await auth.dispose();
  }

  group('opening a reset link', () {
    testWidgets('routes to the new-password screen instead of staying signed in',
        (tester) async {
      await pumpApp(tester);
      expect(find.text('设置新密码'), findsNothing);

      auth.emitPasswordRecovery();
      await settle(tester);

      expect(find.text('设置新密码'), findsOneWidget);
      expect(find.text('保存新密码'), findsOneWidget);
      expect(
        find.textContaining('旧密码仍然可以使用'),
        findsOneWidget,
        reason: 'the rider has to know the reset is not finished yet',
      );

      await shutdown(tester);
    });

    testWidgets('saving a new password changes it and goes back to the app',
        (tester) async {
      await pumpApp(tester);
      auth.emitPasswordRecovery();
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'newpass123');
      await tester.enterText(find.byType(TextField).last, 'newpass123');
      await tester.tap(find.text('保存新密码'));
      await settle(tester);

      expect(auth.savedPasswords, ['newpass123']);
      expect(find.text('开始骑行'), findsOneWidget);
      expect(find.text('设置新密码'), findsNothing);

      await shutdown(tester);
    });

    testWidgets('mismatched entries are rejected before anything is sent',
        (tester) async {
      await pumpApp(tester);
      auth.emitPasswordRecovery();
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'newpass123');
      await tester.enterText(find.byType(TextField).last, 'newpass124');
      await tester.tap(find.text('保存新密码'));
      await settle(tester);

      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(auth.savedPasswords, isEmpty);

      await shutdown(tester);
    });

    testWidgets('a short password is rejected with the server wording',
        (tester) async {
      await pumpApp(tester);
      auth.emitPasswordRecovery();
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'abc');
      await tester.enterText(find.byType(TextField).last, 'abc');
      await tester.tap(find.text('保存新密码'));
      await settle(tester);

      expect(find.text('密码太短，至少需要 6 位'), findsOneWidget);
      expect(auth.savedPasswords, isEmpty);

      await shutdown(tester);
    });

    testWidgets('a server refusal is shown and the screen stays put',
        (tester) async {
      auth.nextFailure = const AuthFailure('该邮箱已被注册，请直接登录，或换一个邮箱');
      await pumpApp(tester);
      auth.emitPasswordRecovery();
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'newpass123');
      await tester.enterText(find.byType(TextField).last, 'newpass123');
      await tester.tap(find.text('保存新密码'));
      await settle(tester);

      expect(find.text('该邮箱已被注册，请直接登录，或换一个邮箱'), findsOneWidget);
      expect(find.text('设置新密码'), findsOneWidget);

      await shutdown(tester);
    });

    testWidgets('稍后再说 leaves without changing anything', (tester) async {
      await pumpApp(tester);
      auth.emitPasswordRecovery();
      await settle(tester);

      await tester.tap(find.text('稍后再说'));
      await settle(tester);

      expect(auth.savedPasswords, isEmpty);
      expect(find.text('开始骑行'), findsOneWidget);

      await shutdown(tester);
    });
  });

  group('without a cloud configured', () {
    test('updatePassword explains the configuration instead of failing raw',
        () async {
      // The real repository, not the fake: this is the path a build with no
      // Supabase credentials takes, and it must say so rather than throw
      // something a rider cannot act on.
      final real = AuthRepository();
      await expectLater(
        real.updatePassword('newpass123'),
        throwsA(
          isA<AuthFailure>().having((e) => e.isConfiguration, 'isConfiguration', true),
        ),
      );
    });
  });
}
