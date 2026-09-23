import 'dart:math' as math;

import '../utils/geo.dart';

/// Conversion between WGS-84 and GCJ-02.
///
/// This is not optional plumbing for a China-focused app. GPS chips and the
/// platform location APIs report WGS-84. AMap — and every Chinese map service,
/// by law — publishes tiles and returns routes in GCJ-02, a deliberately
/// offset datum. Draw a WGS-84 track on GCJ-02 tiles without converting and
/// the line sits 50–500 m from the road it was recorded on, which for a
/// navigation app is the difference between working and not.
///
/// The rule this codebase follows: **WGS-84 everywhere internally** — the
/// database, the ride engine, GPX, Supabase. Conversion happens only at the
/// AMap boundary, in both directions, and nowhere else.
///
/// The offset is applied by an obfuscated polynomial that is only defined
/// inside Chinese territory; outside it, both datums coincide and the
/// functions return their input unchanged.
abstract final class CoordTransform {
  /// Krasovsky 1940 semi-major axis, the ellipsoid GCJ-02 is defined on.
  static const double _a = 6378245.0;

  /// Krasovsky 1940 first eccentricity squared.
  static const double _ee = 0.00669342162296594323;

  static const double _pi = math.pi;

  /// Whether a point lies outside the region where GCJ-02 applies.
  ///
  /// The published bounding box also excludes Hong Kong, Macau and Taiwan,
  /// which use their own datums in practice.
  static bool outOfChina(double lat, double lng) {
    return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
  }

  /// WGS-84 (GPS) to GCJ-02 (Chinese map services).
  static GeoPoint wgs84ToGcj02(GeoPoint point) =>
      wgs84ToGcj02Raw(point.lat, point.lng);

  static GeoPoint wgs84ToGcj02Raw(double lat, double lng) {
    if (outOfChina(lat, lng)) return GeoPoint(lat, lng);

    var dLat = _transformLat(lng - 105.0, lat - 35.0);
    var dLng = _transformLng(lng - 105.0, lat - 35.0);

    final radLat = lat / 180.0 * _pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);

    dLat = (dLat * 180.0) /
        ((_a * (1 - _ee)) / (magic * sqrtMagic) * _pi);
    dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * _pi);

    return GeoPoint(lat + dLat, lng + dLng);
  }

  /// GCJ-02 to WGS-84.
  ///
  /// GCJ-02 has no closed-form inverse, so this iterates: guess, re-apply the
  /// forward transform, and correct by the residual. Three rounds converge to
  /// well under a centimetre, which is far below GPS noise.
  static GeoPoint gcj02ToWgs84(GeoPoint point) {
    if (outOfChina(point.lat, point.lng)) return point;

    var lat = point.lat;
    var lng = point.lng;

    for (var i = 0; i < 3; i++) {
      final forward = wgs84ToGcj02Raw(lat, lng);
      lat += point.lat - forward.lat;
      lng += point.lng - forward.lng;
    }

    return GeoPoint(lat, lng);
  }

  static List<GeoPoint> wgs84ToGcj02List(List<GeoPoint> points) {
    // Nothing to do for a route entirely outside China — worth checking once
    // rather than per point for a 10,000-point polyline.
    if (points.isEmpty || outOfChina(points.first.lat, points.first.lng)) {
      return points;
    }
    return points.map(wgs84ToGcj02).toList(growable: false);
  }

  static List<GeoPoint> gcj02ToWgs84List(List<GeoPoint> points) {
    if (points.isEmpty || outOfChina(points.first.lat, points.first.lng)) {
      return points;
    }
    return points.map(gcj02ToWgs84).toList(growable: false);
  }

  static double _transformLat(double x, double y) {
    var ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * _pi) +
            20.0 * math.sin(2.0 * x * _pi)) *
        2.0 /
        3.0;
    ret += (20.0 * math.sin(y * _pi) + 40.0 * math.sin(y / 3.0 * _pi)) *
        2.0 /
        3.0;
    ret += (160.0 * math.sin(y / 12.0 * _pi) +
            320 * math.sin(y * _pi / 30.0)) *
        2.0 /
        3.0;
    return ret;
  }

  static double _transformLng(double x, double y) {
    var ret = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret += (20.0 * math.sin(6.0 * x * _pi) +
            20.0 * math.sin(2.0 * x * _pi)) *
        2.0 /
        3.0;
    ret += (20.0 * math.sin(x * _pi) + 40.0 * math.sin(x / 3.0 * _pi)) *
        2.0 /
        3.0;
    ret += (150.0 * math.sin(x / 12.0 * _pi) +
            300.0 * math.sin(x / 30.0 * _pi)) *
        2.0 /
        3.0;
    return ret;
  }
}
