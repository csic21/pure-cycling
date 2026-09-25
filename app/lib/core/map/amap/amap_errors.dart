/// AMap's error envelope, translated once for every client that speaks it.
///
/// The envelope is the same whether the request went to the vendor or through
/// the relay, so the wording a rider sees does not depend on which one is in
/// play.
abstract final class AmapErrors {
  /// Error codes that mean "this key or this account cannot use the service",
  /// as opposed to a transient failure. The UI sends these to settings.
  ///
  /// 10001 invalid key, 10002 service disabled, 10003 quota exceeded,
  /// 10009/10012/10013 signature and IP-whitelist failures. `relay_401` is our
  /// own: the relay needs a session.
  static bool isConfiguration(String infocode) => const {
        '10001',
        '10002',
        '10003',
        '10009',
        '10012',
        '10013',
        'relay_401',
      }.contains(infocode);

  static String describe(String info, String infocode) {
    final hint = switch (infocode) {
      '10001' => '：Key 无效，请检查设置中的高德 Key',
      '10002' => '：该 Key 未开通此服务',
      '10003' => '：今日配额已用完',
      '10009' => '：数字签名校验失败',
      '10012' => '：IP 白名单限制',
      '20800' => '：起点或终点在服务范围外',
      '20802' => '：无法规划出骑行路线',
      'relay_400' => '：请求格式不正确',
      'relay_401' => '：需要登录后使用在线路线规划',
      'relay_429' => '：今日在线路线规划次数已用完',
      'relay_503' => '：服务端没有配置高德 Key',
      _ => '',
    };
    return '高德错误 $infocode$hint（$info）';
  }
}
