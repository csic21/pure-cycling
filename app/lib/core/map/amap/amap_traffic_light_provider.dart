import '../../utils/geo.dart';
import '../map_providers.dart';

/// Traffic light countdown backed by AMap.
///
/// **Not implemented, deliberately.** Spec §11 is explicit that this is an
/// enhancement rather than a V1 dependency, and that the following must be
/// confirmed before it is built on:
///
/// ```text
/// 平台支持情况 / iOS / Android 支持情况 / 授权方式
/// 商务费用 / 普通自行车是否可用 / 数据覆盖城市
/// ```
///
/// The capability in AMap's product line is exposed through the *two-wheeler
/// navigation SDK* — the on-device 电动自行车 / 巡航 red-light countdown — not
/// through the Web Service REST API this app's routing uses. Consuming it means
/// a licensed SDK, a per-app key, and an Android/iOS integration, none of which
/// is a code change that can be made on the strength of a public endpoint.
///
/// Reporting "unavailable" honestly is the point. A provider that returned an
/// empty list would look identical to "no light ahead", and a rider would
/// reasonably conclude the feature worked.
class AmapTrafficLightProvider implements TrafficLightProvider {
  const AmapTrafficLightProvider();

  @override
  String get id => 'amap';

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason =>
      '高德红绿灯倒计时通过两轮车导航 SDK 提供，需要单独授权与接入，'
      '当前版本未启用。';

  @override
  Future<List<TrafficLightInfo>> lightsAhead({
    required GeoPoint position,
    required double headingDegrees,
    double withinMeters = 300,
  }) async {
    // The seam is real: when the SDK is licensed, this method gets a body and
    // nothing above it changes.
    return const [];
  }
}
