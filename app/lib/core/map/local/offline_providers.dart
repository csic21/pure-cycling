import '../../../features/routes/domain/route.dart';
import '../../utils/geo.dart';
import '../../utils/ids.dart';
import '../map_providers.dart';

/// Straight-line routing, used when no map key is configured.
///
/// This exists so the app is fully usable — record, dashboard, history, GPX,
/// navigation UI — without a paid map key. The spec's own development order
/// (spec §40) puts the map last for exactly this reason: everything before it
/// must not depend on it.
///
/// A straight line is *not* a bike route and the UI says so plainly. What it
/// does provide is a real geometry with real turns, so the navigation engine,
/// the off-route detector and the reroute path can all be exercised and tested
/// without any external service.
class OfflineRouteProvider implements RouteProvider {
  const OfflineRouteProvider({this.averageSpeedMps = 4.2});

  /// ~15 km/h, a reasonable city cycling pace for estimating arrival.
  final double averageSpeedMps;

  @override
  String get id => 'offline';

  @override
  String get displayName => '直线（离线）';

  @override
  bool get isConfigured => true;

  /// Always. This provider's whole purpose is to answer when no real routing
  /// service is available, and its answers are straight lines — which is why
  /// the UI has to say so rather than presenting them as bike routes.
  @override
  bool get isDegraded => true;

  @override
  MapDatum get datum => MapDatum.wgs84;

  @override
  Future<Route> planRoute({
    required GeoPoint origin,
    required GeoPoint destination,
    List<GeoPoint> waypoints = const [],
    RoutePreference preference = RoutePreference.recommended,
  }) async {
    final stops = <GeoPoint>[origin, ...waypoints, destination];

    final points = <GeoPoint>[];
    final instructions = <RouteInstruction>[];

    for (var i = 0; i < stops.length - 1; i++) {
      final from = stops[i];
      final to = stops[i + 1];
      final startIndex = points.isEmpty ? 0 : points.length - 1;

      final leg = _interpolate(from, to, const Duration(seconds: 90));
      if (points.isEmpty) {
        points.addAll(leg);
      } else {
        points.addAll(leg.skip(1));
      }

      final endIndex = points.length - 1;
      final legDistance = polylineLengthMeters(leg);
      final isLast = i == stops.length - 2;

      instructions.add(
        RouteInstruction(
          index: instructions.length,
          maneuver: Maneuver.straight,
          text: isLast ? '直行至终点' : '直行至途经点',
          distanceMeters: legDistance,
          durationSeconds: legDistance / averageSpeedMps,
          startPolylineIndex: startIndex,
          endPolylineIndex: endIndex,
        ),
      );
    }

    final total = polylineLengthMeters(points);

    return Route(
      id: generateId(),
      name: '直线路线',
      points: points,
      instructions: instructions,
      distanceMeters: total,
      estimatedDuration:
          Duration(seconds: (total / averageSpeedMps).round()),
      elevationGainMeters: null,
      provider: id,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Route> rerouteFrom({
    required GeoPoint from,
    required Route original,
  }) async {
    final destination = original.end;
    if (destination == null) {
      throw const RoutePlanningException('原路线没有终点，无法重新规划');
    }
    final rerouted = await planRoute(origin: from, destination: destination);
    return Route(
      id: original.id,
      name: original.name,
      points: rerouted.points,
      instructions: rerouted.instructions,
      distanceMeters: rerouted.distanceMeters,
      estimatedDuration: rerouted.estimatedDuration,
      provider: rerouted.provider,
      createdAt: original.createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  /// Samples a straight line between two points.
  ///
  /// The spacing is derived from the leg's length and the assumed speed so
  /// that points land roughly [interval] apart in time. A dense, uniformly
  /// spaced line matters here: the navigation engine walks the polyline to
  /// find where the rider is, and five points across 8 km would make the
  /// off-route and turn-distance calculations meaningless.
  static List<GeoPoint> _interpolate(
    GeoPoint from,
    GeoPoint to,
    Duration interval,
  ) {
    final total = haversineMeters(from.lat, from.lng, to.lat, to.lng);
    if (total < 1) return [from, to];

    // ~4.2 m/s assumed, so 90 s of travel is ~380 m per sample.
    final stepMeters = 4.2 * interval.inSeconds;
    final segments = (total / stepMeters).ceil().clamp(2, 400);

    final points = <GeoPoint>[];
    for (var i = 0; i <= segments; i++) {
      final t = i / segments;
      points.add(
        GeoPoint(
          from.lat + (to.lat - from.lat) * t,
          from.lng + (to.lng - from.lng) * t,
        ),
      );
    }
    return points;
  }
}

/// Place search that returns nothing, for the no-key configuration.
///
/// The UI disables the search field when [isConfigured] is false, so this is
/// a safety net rather than a user-visible path.
class NullPlaceProvider implements PlaceProvider {
  const NullPlaceProvider();

  @override
  String get id => 'none';

  @override
  String get displayName => '未配置';

  @override
  bool get isConfigured => false;

  @override
  Future<List<PlaceSuggestion>> search(
    String query, {
    GeoPoint? near,
    int limit = 10,
  }) async =>
      const [];

  @override
  Future<PlaceSuggestion?> reverseGeocode(GeoPoint point) async => null;
}
