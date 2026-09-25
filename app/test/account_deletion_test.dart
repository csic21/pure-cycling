import 'dart:convert';

import 'package:cycling_app/core/sync/account_deletion_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The client half of account deletion.
///
/// The failure that matters is reporting success: a rider who is told their
/// account is gone, and it is not, has lost the ability to try again. So every
/// non-200, and every 200 that does not say `deleted: true`, throws.
void main() {
  AccountDeletionClient build(
    MockClient http, {
    String endpoint = 'https://project.test/functions/v1/delete-account',
    String? token = 'session-token',
  }) =>
      AccountDeletionClient(
        endpoint: endpoint,
        accessToken: () => token,
        httpClient: http,
      );

  test('carries the session and reports what was cleaned up', () async {
    late http.Request seen;
    final client = build(
      MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({'deleted': true, 'files': 3}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    expect(client.isConfigured, isTrue);
    expect(await client.deleteAccount(), 3);
    expect(seen.method, 'POST');
    expect(seen.headers['Authorization'], 'Bearer session-token');
    // The endpoint deletes the caller's own account; there is no parameter
    // that could name somebody else.
    expect(seen.body, '{}');
  });

  test('without a session it refuses instead of asking the server', () async {
    var called = false;
    final client = build(
      MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
      token: null,
    );

    expect(client.isConfigured, isFalse);
    await expectLater(
      client.deleteAccount(),
      throwsA(isA<AccountDeletionException>()
          .having((e) => e.message, 'message', contains('登录'))),
    );
    expect(called, isFalse);
  });

  test('a 200 that does not confirm deletion is a failure', () async {
    final client = build(
      MockClient((_) async => http.Response(
            jsonEncode({'deleted': false}),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

    await expectLater(
      client.deleteAccount(),
      throwsA(isA<AccountDeletionException>()),
    );
  });

  test('the server\'s own words survive to the rider', () async {
    final client = build(
      MockClient((_) async => http.Response(
            jsonEncode({'error': '删除账号失败，请稍后再试'}),
            502,
            headers: {'content-type': 'application/json'},
          )),
    );

    await expectLater(
      client.deleteAccount(),
      throwsA(isA<AccountDeletionException>()
          .having((e) => e.message, 'message', contains('请稍后再试'))),
    );
  });

  test('a body that is not JSON still fails with the status', () async {
    final client = build(
      MockClient((_) async => http.Response('<html>502</html>', 502)),
    );

    await expectLater(
      client.deleteAccount(),
      throwsA(isA<AccountDeletionException>()
          .having((e) => e.message, 'message', contains('502'))),
    );
  });

  test('an unreachable endpoint is a message, not a crash', () async {
    final client = build(
      MockClient((_) async => throw http.ClientException('socket closed')),
    );

    await expectLater(
      client.deleteAccount(),
      throwsA(isA<AccountDeletionException>()
          .having((e) => e.message, 'message', contains('网络不可用'))),
    );
  });
}
