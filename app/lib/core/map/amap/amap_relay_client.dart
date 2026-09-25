import 'dart:convert';

import 'package:http/http.dart' as http;

import '../map_providers.dart';
import 'amap_errors.dart';
import 'amap_route_client.dart';

/// Talks to our own routing relay instead of the vendor.
///
/// The relay holds the AMap key (see `supabase/functions/route`); this client
/// holds nothing but the endpoint and the rider's session. It speaks the same
/// AMap envelope as [AmapClient], so the provider above it — and all of its
/// parsing — cannot tell the two apart.
///
/// ## What it refuses
///
/// Only the bicycling endpoint. The relay is not a general gateway, and
/// neither is this: forwarding an arbitrary path would turn a key-custody
/// measure into a key-leak-with-extra-steps.
class AmapRelayClient implements AmapRouteClient {
  AmapRelayClient({
    required this.endpoint,
    required String? Function() accessToken,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 12),
  })  : _accessToken = accessToken,
        _http = httpClient ?? http.Client();

  /// The relay function's URL, e.g.
  /// `https://xxxx.supabase.co/functions/v1/route`.
  final String endpoint;

  /// Read per request, not captured: supabase_flutter refreshes the session in
  /// place, and a token captured at construction is one refresh away from
  /// being expired.
  final String? Function() _accessToken;

  final http.Client _http;
  final Duration timeout;

  @override
  bool get isConfigured =>
      endpoint.trim().isNotEmpty && _accessToken() != null;

  @override
  Future<Map<String, dynamic>> get(
    String path,
    Map<String, String> params,
  ) async {
    if (path != '/v5/direction/bicycling') {
      throw const RoutePlanningException('中转只提供骑行路线规划');
    }

    final token = _accessToken();
    if (token == null) {
      throw const RoutePlanningException(
        '需要登录后使用在线路线规划（匿名账号也可以）',
        isConfiguration: true,
      );
    }

    final response = await _post(token, params).timeout(timeout);

    // The relay reuses AMap's envelope for its own refusals, so a 401 or 429
    // carries a readable `info` rather than an HTTP status alone.
    if (response.statusCode != 200) {
      final info = _infoOf(response);
      throw RoutePlanningException(
        info ?? '在线路线规划失败（HTTP ${response.statusCode}）',
        isConfiguration: response.statusCode == 401,
      );
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const RoutePlanningException('无法解析路线规划返回结果');
    }

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

  Future<http.Response> _post(String token, Map<String, String> params) async {
    final origin = params['origin'] ?? '';
    final destination = params['destination'] ?? '';
    final alternatives = int.tryParse(params['alternative_route'] ?? '1') ?? 1;

    try {
      return await _http.post(
        Uri.parse(endpoint),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'origin': origin,
          'destination': destination,
          'alternatives': alternatives.clamp(1, 3),
        }),
      );
    } on RoutePlanningException {
      rethrow;
    } catch (e) {
      // Offline is the expected case on a bike, not an exceptional one.
      throw RoutePlanningException('网络不可用：$e');
    }
  }

  /// The relay's refusal message, when the body is one.
  static String? _infoOf(http.Response response) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map<String, dynamic>) {
        final info = body['info']?.toString();
        if (info != null && info.isNotEmpty) return info;
      }
    } catch (_) {
      // Not JSON; fall through to the status-code message.
    }
    return null;
  }
}
