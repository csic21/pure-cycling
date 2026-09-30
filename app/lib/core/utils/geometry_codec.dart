import 'dart:convert';

import '../../features/routes/domain/route.dart';
import 'geo.dart';

/// Serialization for route geometry and instructions.
///
/// Geometry is stored as a JSON array of `[lat, lng]` pairs rounded to five
/// decimals (~1.1 m at the equator) — below the noise floor of consumer GPS,
/// and roughly a third the size of the full double representation.
///
/// A 100 km route sampled every 10 m is ~10k pairs: about 160 KB of text, which
/// SQLite handles without complaint and which never needs to be parsed on the
/// ride-critical path.

const int _geometryPrecision = 5;
final double _geometryScale = _pow10(_geometryPrecision);

double _pow10(int n) {
  var v = 1.0;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

String encodeGeometry(List<GeoPoint> points) {
  final buf = StringBuffer('[');
  for (var i = 0; i < points.length; i++) {
    if (i > 0) buf.write(',');
    final lat = (points[i].lat * _geometryScale).round() / _geometryScale;
    final lng = (points[i].lng * _geometryScale).round() / _geometryScale;
    buf
      ..write('[')
      ..write(lat)
      ..write(',')
      ..write(lng)
      ..write(']');
  }
  buf.write(']');
  return buf.toString();
}

List<GeoPoint> decodeGeometry(String raw) {
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <GeoPoint>[];
    for (final entry in decoded) {
      if (entry is List && entry.length >= 2) {
        final lat = (entry[0] as num).toDouble();
        final lng = (entry[1] as num).toDouble();
        out.add(GeoPoint(lat, lng));
      }
    }
    return out;
  } on FormatException {
    return const [];
  }
}

String encodeInstructions(List<RouteInstruction> instructions) =>
    jsonEncode(instructions.map((i) => i.toJson()).toList());

List<RouteInstruction> decodeInstructions(String raw) {
  if (raw.isEmpty || raw == '[]') return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <RouteInstruction>[];
    for (final entry in decoded) {
      if (entry is Map<String, dynamic>) {
        out.add(RouteInstruction.fromJson(entry));
      }
    }
    return out;
  } on FormatException {
    return const [];
  }
}

/// Encodes a track as WKT `LINESTRING` for the PostGIS `route_geometry`
/// column.
///
/// Track points are never uploaded individually (spec §23): the cloud stores
/// the summary row plus this single geometry, and the full-resolution trace
/// lives in Storage as GPX. That keeps a three-hour ride to one row instead of
/// ten thousand.
///
/// [simplifyToleranceMeters] removes points that lie close to the straight
/// line between their neighbours — GPS noise that adds nothing to the shape
/// but a lot to the payload.
String trackToLineStringWkt(
  List<GeoPoint> points, {
  double simplifyToleranceMeters = 2.0,
}) {
  final coords = simplifyPolyline(points, simplifyToleranceMeters);
  final buf = StringBuffer('LINESTRING(');
  for (var i = 0; i < coords.length; i++) {
    if (i > 0) buf.write(',');
    buf
      ..write(coords[i].lng.toStringAsFixed(6))
      ..write(' ')
      ..write(coords[i].lat.toStringAsFixed(6));
  }
  buf.write(')');
  return buf.toString();
}

/// Drops points that sit within [toleranceMeters] of the chord between the
/// points that are kept.
///
/// Ramer–Douglas–Peucker. Endpoints are always kept. A non-positive tolerance
/// returns [points] unchanged.
List<GeoPoint> simplifyPolyline(List<GeoPoint> points, double toleranceMeters) {
  if (points.length <= 2 || toleranceMeters <= 0) return points;

  // Ramer–Douglas–Peucker: keep the endpoints and any point that deviates
  // from the chord by more than the tolerance.
  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;
  _rdp(points, 0, points.length - 1, toleranceMeters, keep);

  final out = <GeoPoint>[];
  for (var i = 0; i < points.length; i++) {
    if (keep[i]) out.add(points[i]);
  }
  return out;
}

/// Display simplification: keep the shape, but stop at [maxVertices].
///
/// [minToleranceMeters] runs first, so a straight noisy trace collapses even
/// when it is already under the cap. Anything still over the cap is thinned
/// by raising the tolerance until it fits. Endpoints are preserved.
List<GeoPoint> simplifyForDisplay(
  List<GeoPoint> points, {
  int maxVertices = 480,
  double minToleranceMeters = 4,
}) {
  if (points.length <= 2) return points;
  final cap = maxVertices < 2 ? 2 : maxVertices;
  final floor = minToleranceMeters < 0 ? 0.0 : minToleranceMeters;
  final first = simplifyPolyline(points, floor);
  if (first.length <= cap) return first;

  final box = GeoBounds.of(points);
  var low = floor;
  var high = box == null ? floor + 1 : box.diagonalMeters;
  if (high <= low) high = low + 1;

  var best = first;
  for (var i = 0; i < 14; i++) {
    final mid = (low + high) / 2;
    final attempt = simplifyPolyline(points, mid);
    if (attempt.length > cap) {
      low = mid;
    } else {
      best = attempt;
      high = mid;
    }
  }
  if (best.length <= cap) return best;
  return [points.first, points.last];
}

void _rdp(
  List<GeoPoint> pts,
  int start,
  int end,
  double tolerance,
  List<bool> keep,
) {
  if (end <= start + 1) return;

  var maxDist = 0.0;
  var index = -1;
  for (var i = start + 1; i < end; i++) {
    final d = distanceToSegmentMeters(
      pts[i].lat,
      pts[i].lng,
      pts[start].lat,
      pts[start].lng,
      pts[end].lat,
      pts[end].lng,
    );
    if (d > maxDist) {
      maxDist = d;
      index = i;
    }
  }

  if (maxDist > tolerance && index > 0) {
    keep[index] = true;
    _rdp(pts, start, index, tolerance, keep);
    _rdp(pts, index, end, tolerance, keep);
  }
}
