import 'dart:convert';

import 'package:http/http.dart' as http;

/// Asks the server to delete the signed-in account.
///
/// The call is the easy part; what matters is that it cannot report success
/// when the account is still there. Anything other than a 200 with
/// `deleted: true` throws, and the UI therefore never tells a rider their
/// account is gone when it is not.
class AccountDeletionClient {
  AccountDeletionClient({
    required this.endpoint,
    required String? Function() accessToken,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  })  : _accessToken = accessToken,
        _http = httpClient ?? http.Client();

  /// The `delete-account` function's URL.
  final String endpoint;

  /// Read per request: the session refreshes in place.
  final String? Function() _accessToken;

  final http.Client _http;

  /// Longer than a routing call: the server deletes files, rows and the
  /// account itself before it answers.
  final Duration timeout;

  bool get isConfigured =>
      endpoint.trim().isNotEmpty && _accessToken() != null;

  /// Returns how many GPX files the server removed, or throws.
  Future<int> deleteAccount() async {
    final token = _accessToken();
    if (token == null) {
      throw const AccountDeletionException('需要登录后才能删除账号');
    }

    http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(timeout);
    } catch (_) {
      // Same rule as the routing relay: the rider gets a sentence, not a type
      // name. The call is authenticated and short, so a failure here is almost
      // always "no network" or "the token has expired".
      throw const AccountDeletionException('网络不可用，请检查连接后重试');
    }

    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // A non-JSON body is handled below by the status check.
    }

    if (response.statusCode != 200 || body?['deleted'] != true) {
      throw AccountDeletionException(
        body?['error']?.toString() ?? '删除账号失败（HTTP ${response.statusCode}）',
      );
    }

    return (body?['files'] as num?)?.toInt() ?? 0;
  }
}

/// A failed account deletion, with a message a rider can act on.
class AccountDeletionException implements Exception {
  const AccountDeletionException(this.message);

  final String message;

  @override
  String toString() => message;
}
