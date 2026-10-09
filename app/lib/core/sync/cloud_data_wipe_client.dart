import 'dart:convert';

import 'package:http/http.dart' as http;

/// Asks the server to wipe the signed-in account's cloud data.
///
/// The call is the easy part; what matters is that it cannot report success
/// while any cloud data remains. Anything other than a 200 with
/// `wiped: true` throws, preserving local metadata for a safe retry.
class CloudDataWipeClient {
  CloudDataWipeClient({
    required this.endpoint,
    required String? Function() accessToken,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _accessToken = accessToken,
       _http = httpClient ?? http.Client();

  /// The `wipe-cloud-data` function's URL.
  final String endpoint;

  /// Read per request: the session refreshes in place.
  final String? Function() _accessToken;

  final http.Client _http;

  void close() => _http.close();

  /// The server fences writes, deletes files and rows, and verifies the
  /// authoritative object inventory before answering.
  final Duration timeout;

  bool get isConfigured => endpoint.trim().isNotEmpty && _accessToken() != null;

  /// Returns how many GPX files the server removed, or throws.
  Future<int> wipe() async {
    final token = _accessToken();
    if (token == null) {
      throw const CloudDataWipeException('需要登录后才能删除云端数据');
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
      throw const CloudDataWipeException('网络不可用，请检查连接后重试');
    }

    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // A non-JSON body is handled below by the status check.
    }

    if (response.statusCode != 200 || body?['wiped'] != true) {
      throw CloudDataWipeException(
        body?['error']?.toString() ?? '删除云端数据失败（HTTP ${response.statusCode}）',
      );
    }

    return (body?['files'] as num?)?.toInt() ?? 0;
  }
}

/// A failed cloud wipe, with a message a rider can act on.
class CloudDataWipeException implements Exception {
  const CloudDataWipeException(this.message);

  final String message;

  @override
  String toString() => message;
}
