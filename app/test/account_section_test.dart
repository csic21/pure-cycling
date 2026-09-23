import 'package:cycling_app/features/auth/data/auth_repository.dart';
import 'package:cycling_app/features/settings/presentation/widgets/account_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_harness.dart';

/// The account section on the sync screen.
///
/// Rendered directly rather than through the sync screen, because that screen
/// only shows it when Supabase is configured — and `isConfigured` is a
/// compile-time constant, so a test build can never have credentials. Left
/// inline, this section would be unreachable from any test.
///
/// Worth the extraction because of what it covers: the login screen tells the
/// rider an anonymous account 「可以随时绑定邮箱」, and for a while there was no
/// way to do it. A promise in the UI that the app cannot keep is worse than no
/// promise, and nothing else in the suite would have noticed.
void main() {
  /// Renders the section and runs [body] against it, then tears down.
  ///
  /// The assertions have to run *inside* this, not after it. Teardown replaces
  /// the tree with an empty widget, so an assertion that ran afterwards would
  /// be looking at nothing — and would report "the UI is missing" rather than
  /// "the test looked too late".
  Future<void> render(
    WidgetTester tester,
    AuthUser? user,
    Future<void> Function() body,
  ) async {
    final database = openTestDatabase();
    useTallSurface(tester);

    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(database: database),
        child: MaterialApp(
          home: Scaffold(
            body: ListView(children: [AccountSection(user: user)]),
          ),
        ),
      ),
    );
    await settle(tester);

    try {
      await body();
    } finally {
      await shutdownApp(tester, database);
    }
  }

  group('no account', () {
    testWidgets('offers a way to sign in, and says what it is for',
        (tester) async {
      await render(tester, null, () async {
        expect(find.text('登录以启用云同步'), findsOneWidget);
        expect(find.textContaining('新手机上恢复'), findsOneWidget);
        // Nothing to sign out of, and no account to label.
        expect(find.text('退出登录'), findsNothing);
        expect(find.text('绑定邮箱'), findsNothing);
      });
    });
  });

  group('anonymous account', () {
    const anonymous = AuthUser(id: 'u1', isAnonymous: true);

    testWidgets('says the account cannot be recovered, and offers to fix it',
        (tester) async {
      await render(tester, anonymous, () async {
        expect(find.text('匿名账号'), findsOneWidget);
        expect(
          find.textContaining('换手机后无法找回'),
          findsOneWidget,
          reason: 'the consequence has to be stated, not implied',
        );
        expect(find.text('绑定邮箱'), findsOneWidget);
      });
    });

    testWidgets('the footnote explains the rides are safe either way',
        (tester) async {
      await render(tester, anonymous, () async {
        // A rider reading 「无法找回」 needs to know it is the *account* that is
        // at risk, not the rides already on the server.
        expect(find.textContaining('同样会上传到云端'), findsOneWidget);
        expect(find.textContaining('只有绑定邮箱之后'), findsOneWidget);
      });
    });

    testWidgets('the attach dialog asks for an address and a password',
        (tester) async {
      await render(tester, anonymous, () async {
        await tester.tap(find.text('绑定邮箱'));
        await settle(tester);

        expect(find.text('设置密码'), findsOneWidget);
        expect(find.text('至少 6 位'), findsOneWidget);
        expect(find.text('取消'), findsOneWidget);
        expect(find.text('绑定'), findsOneWidget);
        // Reassurance that binding does not move anything.
        expect(find.textContaining('已同步的骑行不会受影响'), findsOneWidget);
      });
    });

    testWidgets('an empty address is rejected before any request is made',
        (tester) async {
      await render(tester, anonymous, () async {
        await tester.tap(find.text('绑定邮箱'));
        await settle(tester);
        await tester.tap(find.text('绑定'));
        await settle(tester);

        // Nothing is configured in a test build, so a request would have come
        // back with the configuration message. Seeing the validation message
        // instead proves the guard runs first — a rider who mistyped should
        // not be told their Supabase key is missing.
        expect(find.textContaining('密码至少 6 位'), findsOneWidget);
      });
    });
  });

  group('named account', () {
    const named = AuthUser(id: 'u1', email: 'rider@example.com');

    testWidgets('shows the address and offers to sign out', (tester) async {
      await render(tester, named, () async {
        expect(find.text('rider@example.com'), findsOneWidget);
        expect(find.text('已登录'), findsOneWidget);
        expect(find.text('退出登录'), findsOneWidget);
        expect(find.textContaining('不会删除任何本地记录'), findsOneWidget);
      });
    });

    testWidgets('does not offer to attach an address it already has',
        (tester) async {
      await render(tester, named, () async {
        expect(
          find.text('绑定邮箱'),
          findsNothing,
          reason: 'a prompt to attach an email to an account that has one '
              'reads as a bug',
        );
      });
    });

    testWidgets('signing out asks first, and says what is kept',
        (tester) async {
      await render(tester, named, () async {
        await tester.tap(find.text('退出登录'));
        await settle(tester);

        expect(find.text('退出登录？'), findsOneWidget);
        expect(find.textContaining('本地记录会全部保留'), findsOneWidget);
      });
    });
  });
}
