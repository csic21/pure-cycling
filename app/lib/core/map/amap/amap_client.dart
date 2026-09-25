import 'dart:convert';

import 'package:http/http.dart' as http;

import '../map_providers.dart';
import 'amap_errors.dart';
import 'amap_route_client.dart';

/// Shared HTTP plumbing for AMap's Web Service APIs (高德 Web 服务).
///
/// All three AMap providers talk to the same host with the same envelope and
/// the same failure modes, so the request, the key check and the error mapping
/// live here once.
class AmapClient implements AmapRouteClient {
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

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Issues a GET and returns the decoded JSON body.
  ///
  /// AMap returns HTTP 200 for many failures and signals the problem in the
  /// body, so the status code alone is not enough — `status` and `infocode`
  /// must both be checked before the payload can be trusted.
  @override
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
        AmapErrors.describe(info, infocode),
        isConfiguration: AmapErrors.isConfiguration(infocode),
      );
    }

    return body;
  }

  void close() => _http.close();

  static String _describe(Object error) {
    final text = error.toString();
    // The underlying exception is deliberately not interpolated: a rider who
    // is out of signal should read 「无法连接网络」, not a Dart type name and a
    // URL. The kind of failure — timeout versus no route — is worth keeping
    // distinct because the rider's next move differs.
    if (text.contains('TimeoutException')) return '请求超时';
    if (text.contains('SocketException') || text.contains('Connection')) {
      return '无法连接网络';
    }
    return '网络请求失败';
  }
}
