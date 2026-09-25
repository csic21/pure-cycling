import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/geo.dart';

/// Terrain height for a list of coordinates.
///
/// The one thing a planned route cannot have without help: a bicycle route
/// comes from a routing service that knows roads, not relief. AMap's cycling
/// planner returns no altitude at all, which is why a route's climb shows
/// `—` — an absence, not a zero.
///
/// Implementations are chosen at runtime (see `providers.dart`) and off by
/// default, because asking one means sending the route's coordinates to
/// somebody else's server. That is a decision the rider makes, not one the app
/// makes for them.
abstract interface class ElevationProvider {
  /// Stable id, for tests and for the settings screen.
  String get id;

  /// What to credit in the UI.
  String get displayName;

  /// False when the build is not allowed to use it.
  bool get isConfigured;

  /// Heights in metres, one per input point, `null` where the source has no
  /// data. Empty when the whole request failed.
  Future<List<double?>> heights(List<GeoPoint> points);
}

/// A provider that never answers.
///
/// The default: no coordinate leaves the device for an elevation figure, and
/// the route screens keep saying `—` with the reason they always gave.
class NullElevationProvider implements ElevationProvider {
  const NullElevationProvider();

  @override
  String get id => 'none';

  @override
  String get displayName => '未启用';

  @override
  bool get isConfigured => false;

  @override
  Future<List<double?>> heights(List<GeoPoint> points) async => const [];
}

/// The public SRTM/NED service run by OpenTopoData.
///
/// Chosen because it needs no key: an opt-in feature for a self-hosted or
/// development build should not require the rider to sign up for a terrain
/// API. Its documented limits are respected here — 100 locations per request
/// and one request per second — and a distribution that wanted this for many
/// riders would put it behind the same kind of relay the routing key has,
/// because a public service's fair-use ceiling is per-caller, not per-user.
///
/// The dataset is 30 m SRTM: hills and passes are right, a bridge or a cutting
/// is not — the ground under it is what the satellite saw.
class OpenTopoDataElevationProvider implements ElevationProvider {
  OpenTopoDataElevationProvider({
    http.Client? client,
    this.dataset = 'srtm30m',
    Duration? timeout,
  })  : _http = client ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 12);

  final http.Client _http;
  final String dataset;
  final Duration _timeout;

  /// Documented maximum per request; the sampler keeps to it.
  static const int maxLocationsPerRequest = 100;

  @override
  String get id => 'opentopodata';

  @override
  String get displayName => 'OpenTopoData（SRTM 30m）';

  @override
  bool get isConfigured => true;

  @override
  Future<List<double?>> heights(List<GeoPoint> points) async {
    if (points.isEmpty) return const [];
    if (points.length > maxLocationsPerRequest) {
      throw ArgumentError(
        'OpenTopoData accepts at most $maxLocationsPerRequest locations per '
        'request; sample the route first (see `sampleRoutePoints`).',
      );
    }

    final uri = Uri.https('api.opentopodata.org', '/v1/$dataset', {
      // lat,lng per location, pipe-separated, in the order asked.
      'locations': points
          .map((p) => '${p.lat.toStringAsFixed(5)},${p.lng.toStringAsFixed(5)}')
          .join('|'),
    });

    final response = await _http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw ElevationProviderException(
        '高程服务返回 HTTP ${response.statusCode}',
      );
    }

    return parseHeights(response.body);
  }

  /// Parses the documented envelope, keeping one slot per input point.
  ///
  /// Nulls are kept rather than dropped: the caller pairs heights with
  /// positions, and a dropped point would shift every height after it onto the
  /// wrong place on the route.
  static List<double?> parseHeights(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const ElevationProviderException('无法解析高程服务返回结果');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ElevationProviderException('无法解析高程服务返回结果');
    }

    final status = decoded['status']?.toString();
    if (status != null && status.toUpperCase() != 'OK') {
      final message = decoded['error']?.toString() ?? status;
      throw ElevationProviderException('高程服务拒绝了请求：$message');
    }

    final results = decoded['results'];
    if (results is! List) {
      throw const ElevationProviderException('高程服务没有返回结果');
    }

    return [
      for (final entry in results)
        if (entry is Map<String, dynamic> &&
            entry['elevation'] is num &&
            (entry['elevation'] as num).isFinite)
          (entry['elevation'] as num).toDouble()
        else
          null,
    ];
  }
}

class ElevationProviderException implements Exception {
  const ElevationProviderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Evenly spaced samples of [points], at most [max], endpoints kept.
///
/// A route can be thousands of coordinates and the elevation service takes a
/// hundred, so something has to choose. Even spacing along the *index* — not
/// along the distance — is the honest simple choice: route geometry is
/// already denser where the road bends, which is where relief changes anyway.
///
/// The first and last points are always included: a profile that starts
/// somewhere in the middle of the route is a lie about where the climb is.
List<GeoPoint> sampleRoutePoints(List<GeoPoint> points, {int max = 100}) {
  if (max < 2) throw ArgumentError('max must be at least 2');
  if (points.length <= max) return List<GeoPoint>.of(points);

  final out = <GeoPoint>[];
  final step = (points.length - 1) / (max - 1);
  for (var i = 0; i < max; i++) {
    out.add(points[(i * step).round().clamp(0, points.length - 1)]);
  }
  return out;
}
