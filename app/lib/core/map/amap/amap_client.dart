import 'dart:convert';

import 'package:http/http.dart' as http;

import '../map_providers.dart';

/// Shared HTTP plumbing for AMap's Web Service APIs (高德 Web 服务).
///
/// All three AMap providers talk to the same host with the same envelope and
/// the same failure modes, so the request, the key check and the error mapping
/// live here once.
class AmapClient {
  AmapClient({
    required this.apiKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 12),
  }) : _http = httpClient ?? http.Client();

  /// The *Web Service* key (Web 服务 Key), not the Android/iOS SDK key.
  ///
  /// They are different credentials with different restrictions: an SDK key is
  /// bound to an app signature and will be rejected by the REST endpoints.
  final String apiKey;

  final http.Client _http;
  final Duration timeout;

  static const String _host = 'https://restapi.amap.com';

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Issues a GET and returns the decoded JSON body.
  ///
  /// AMap returns HTTP 200 for many failures and signals the problem in the
  /// body, so the status code alone is not enough — `status` and `infocode`
  /// must both be checked before the payload can be trusted.
  Future<Map<String, dynamic>> get(
    String path,
    Map<String, String> params,
  ) async {
    if (!isConfigured) {
      throw const RoutePlanningException(
        '未配置高德 Web 服务 Key',
        isConfiguration: true,
      );
    }

    final uri = Uri.parse('$_host$path').replace(
      queryParameters: {...params, 'key': apiKey, 'output': 'JSON'},
    );

    http.Response response;
    try {
      response = await _http.get(uri).timeout(timeout);
    } catch (e) {
      // Offline is the expected case on a bike, not an exceptional one.
      throw RoutePlanningException('网络不可用：${_describe(e)}');
    }

    if (response.statusCode != 200) {
      throw RoutePlanningException('高德服务返回 HTTP ${response.statusCode}');
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const RoutePlanningException('无法解析高德返回结果');
    }

    // "1" means success. "0" carries a message in `info`.
    if (body['status'] != '1') {
      final info = body['info']?.toString() ?? '未知错误';
      final infocode = body['infocode']?.toString() ?? '';
      throw RoutePlanningException(
        _describeAmapError(info, infocode),
        isConfiguration: _isConfigurationError(infocode),
      );
    }

    return body;
  }

  void close() => _http.close();

  static bool _isConfigurationError(String infocode) {
    // 10001 invalid key, 10002 service disabled, 10003 daily quota exceeded,
    // 10009/10012/10013 signature and IP-whitelist failures.
    return const {'10001', '10002', '10003', '10009', '10012', '10013'}
        .contains(infocode);
  }

  static String _describeAmapError(String info, String infocode) {
    final hint = switch (infocode) {
      '10001' => '：Key 无效，请检查设置中的高德 Key',
      '10002' => '：该 Key 未开通此服务',
      '10003' => '：今日配额已用完',
      '10009' => '：数字签名校验失败',
      '10012' => '：IP 白名单限制',
      '20800' => '：起点或终点在服务范围外',
      '20802' => '：无法规划出骑行路线',
      _ => '',
    };
    return '高德错误 $infocode$hint（$info）';
  }

  static String _describe(Object error) {
    final text = error.toString();
    // ClientException's message includes the full URL, which is noise in a
    // user-facing string.
    if (text.contains('SocketException') || text.contains('Connection')) {
      return '无法连接网络';
    }
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }
}
