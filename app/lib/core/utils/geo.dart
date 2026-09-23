import 'dart:math' as math;

/// Mean Earth radius in meters (IUGG).
const double earthRadiusMeters = 6371008.8;

double _toRadians(double degrees) => degrees * math.pi / 180.0;

double _toDegrees(double radians) => radians * 180.0 / math.pi;

/// Great-circle distance between two WGS84 coordinates, in meters.
///
/// Haversine is accurate to well under a meter at the scales a bike ride
/// covers, and — unlike the equirectangular approximation — stays stable at
/// high latitudes.
double haversineMeters(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final phi1 = _toRadians(lat1);
  final phi2 = _toRadians(lat2);
  final dPhi = phi2 - phi1;
  final dLambda = _toRadians(lon2 - lon1);

  final sinHalfPhi = math.sin(dPhi / 2);
  final sinHalfLambda = math.sin(dLambda / 2);

  final a = sinHalfPhi * sinHalfPhi +
      math.cos(phi1) * math.cos(phi2) * sinHalfLambda * sinHalfLambda;
  // clamp guards against a > 1 from floating point error on antipodal points.
  final c = 2 * math.asin(math.sqrt(math.min(1.0, a)));
  return earthRadiusMeters * c;
}

/// Initial bearing from point 1 to point 2, in degrees clockwise from north.
double initialBearingDegrees(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final phi1 = _toRadians(lat1);
  final phi2 = _toRadians(lat2);
  final dLambda = _toRadians(lon2 - lon1);

  final y = math.sin(dLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  final theta = math.atan2(y, x);
  return normalizeBearing(_toDegrees(theta));
}

/// Normalizes any bearing into the `[0, 360)` range.
double normalizeBearing(double degrees) {
  final v = degrees % 360.0;
  return v < 0 ? v + 360.0 : v;
}

/// Absolute smallest signed difference between two bearings, in degrees.
///
/// Result is in `[0, 180]`, always positive — used for turn detection where
/// only the magnitude of the heading change matters.
double bearingDelta(double from, double to) {
  final diff = (normalizeBearing(to) - normalizeBearing(from)).abs() % 360.0;
  return diff > 180.0 ? 360.0 - diff : diff;
}

/// Signed turn angle in `(-180, 180]`. Positive is a right turn.
double signedTurnAngle(double fromBearing, double toBearing) {
  var diff = normalizeBearing(toBearing) - normalizeBearing(fromBearing);
  while (diff <= -180.0) {
    diff += 360.0;
  }
  while (diff > 180.0) {
    diff -= 360.0;
  }
  return diff;
}

/// Shortest distance in meters from [point] to the segment `a`–`b`.
///
/// The segment is treated as a straight line in a local equirectangular
/// projection centered on the point, which is accurate for the segment lengths
/// found on a road network (tens to hundreds of meters).
double distanceToSegmentMeters(
  double pointLat,
  double pointLng,
  double aLat,
  double aLng,
  double bLat,
  double bLng,
) {
  final latRef = _toRadians(pointLat);
  final metersPerDegLat = 111132.92;
  final metersPerDegLng = 111319.49 * math.cos(latRef);

  double px = (pointLng - aLng) * metersPerDegLng;
  double py = (pointLat - aLat) * metersPerDegLat;
  final bx = (bLng - aLng) * metersPerDegLng;
  final by = (bLat - aLat) * metersPerDegLat;

  final lenSq = bx * bx + by * by;
  if (lenSq <= 0.0) {
    return math.sqrt(px * px + py * py);
  }

  var t = (px * bx + py * by) / lenSq;
  t = t.clamp(0.0, 1.0);

  px -= t * bx;
  py -= t * by;
  return math.sqrt(px * px + py * py);
}

/// Point on segment `a`–`b` nearest to [point], expressed as the fraction
/// `t` in `[0, 1]` along the segment.
double projectionFactorOnSegment(
  double pointLat,
  double pointLng,
  double aLat,
  double aLng,
  double bLat,
  double bLng,
) {
  final latRef = _toRadians(pointLat);
  final metersPerDegLat = 111132.92;
  final metersPerDegLng = 111319.49 * math.cos(latRef);

  final bx = (bLng - aLng) * metersPerDegLng;
  final by = (bLat - aLat) * metersPerDegLat;
  final lenSq = bx * bx + by * by;
  if (lenSq <= 0.0) {
    return 0.0;
  }
  final px = (pointLng - aLng) * metersPerDegLng;
  final py = (pointLat - aLat) * metersPerDegLat;
  return ((px * bx + py * by) / lenSq).clamp(0.0, 1.0);
}

/// Interpolates linearly between two coordinates. `t` is clamped to `[0, 1]`.
({double lat, double lng}) interpolate(
  double lat1,
  double lng1,
  double lat2,
  double lng2,
  double t,
) {
  final tc = t.clamp(0.0, 1.0);
  return (
    lat: lat1 + (lat2 - lat1) * tc,
    lng: lng1 + (lng2 - lng1) * tc,
  );
}

/// A geographic coordinate pair.
///
/// Deliberately a plain value type rather than a `latlong2` dependency so the
/// domain layer stays free of map-package types.
class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() =>
      'GeoPoint(${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)})';
}

/// Length in meters of a polyline described by [points].
double polylineLengthMeters(List<GeoPoint> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += haversineMeters(
      points[i - 1].lat,
      points[i - 1].lng,
      points[i].lat,
      points[i].lng,
    );
  }
  return total;
}

/// Geographic bounding box.
class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south;
  final double west;
  final double north;
  final double east;

  static GeoBounds? of(List<GeoPoint> points) {
    if (points.isEmpty) return null;
    var south = points.first.lat;
    var north = points.first.lat;
    var west = points.first.lng;
    var east = points.first.lng;
    for (final p in points.skip(1)) {
      if (p.lat < south) south = p.lat;
      if (p.lat > north) north = p.lat;
      if (p.lng < west) west = p.lng;
      if (p.lng > east) east = p.lng;
    }
    return GeoBounds(south: south, west: west, north: north, east: east);
  }

  GeoPoint get center =>
      GeoPoint((south + north) / 2, (west + east) / 2);

  /// Rough span in meters, used to pad map views without a projection library.
  double get diagonalMeters => haversineMeters(south, west, north, east);
}
