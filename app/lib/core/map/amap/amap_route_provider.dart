import '../../../features/routes/domain/route.dart';
import '../../utils/geo.dart';
import '../../utils/ids.dart';
import '../coord_transform.dart';
import '../map_providers.dart';
import 'amap_route_client.dart';

/// Cycling route planning via AMap's 路径规划 2.0 (`/v5/direction/bicycling`).
///
/// ## Where the request goes
///
/// It does not know. [AmapRouteClient] is either the vendor called with the
/// rider's own key, or our relay called with the rider's session — the parsing
/// below, including the datum conversion, is identical either way.
///
/// ## Datum
///
/// AMap speaks GCJ-02 on both ends of this API. The conversion is done here,
/// in this file, and nowhere else:
///
/// * **Outbound** — the rider's WGS-84 position and destination are shifted to
///   GCJ-02 before the request, so AMap snaps to the road the rider is actually
///   on rather than to one 300 m to the side.
/// * **Inbound** — the returned polyline is shifted back, so everything the
///   rest of the app sees — the route model, the navigation engine, the
///   database, the GPX — is WGS-84, consistent with the recorded track.
///
/// ## What this provider cannot do
///
/// AMap's cycling planner exposes no lane-preference or traffic-light-avoidance
/// parameters (spec §10). [RoutePreference] values beyond `recommended` are
/// declared unsupported on the enum and the UI marks them as such rather than
/// sending a request that would silently ignore them.
class AmapRouteProvider implements RouteProvider {
  AmapRouteProvider({
    required this.client,
    this.alternatives = 1,
  });

  final AmapRouteClient client;

  /// How many alternative paths to request. V1 shows one; the parameter is
  /// plumbed because showing alternatives is a routing-UI change, not a
  /// provider change.
  final int alternatives;

  @override
  String get id => 'amap';

  @override
  String get displayName => '高德骑行';

  @override
  bool get isConfigured => client.isConfigured;

  @override
  bool get isDegraded => false;

  @override
  MapDatum get datum => MapDatum.gcj02;

  @override
  Future<Route> planRoute({
    required GeoPoint origin,
    required GeoPoint destination,
    List<GeoPoint> waypoints = const [],
    RoutePreference preference = RoutePreference.recommended,
  }) async {
    // AMap's cycling endpoint takes exactly one origin and one destination.
    // Waypoints are honoured by planning a sequence of legs and stitching
    // them, which also gives per-leg instructions the endpoint would not.
    final stops = <GeoPoint>[origin, ...waypoints, destination];

    if (stops.length == 2) {
      return _planLeg(
        origin: origin,
        destination: destination,
        waypoint: null,
        preference: preference,
      );
    }

    return _planMultiLeg(stops: stops, preference: preference);
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

    // Deliberately *not* trying to rejoin the original route mid-way. Once a
    // rider has deviated, the honest thing is to route them to where they
    // were going from where they now are — rejoining logic that guesses at
    // an intended point on the old line is how navigation apps send people
    // back up a hill they just came down.
    final rerouted = await _planLeg(
      origin: from,
      destination: destination,
      waypoint: null,
      preference: RoutePreference.recommended,
    );

    return rerouted.copyWith(
      name: original.name,
      // Keep the identity so an in-progress navigation session keeps its
      // route id, and the save action overwrites rather than duplicating.
      providerRouteId: rerouted.providerRouteId,
    );
  }

  Future<Route> _planLeg({
    required GeoPoint origin,
    required GeoPoint destination,
    GeoPoint? waypoint,
    required RoutePreference preference,
  }) async {
    final gcjOrigin = CoordTransform.wgs84ToGcj02(origin);
    final gcjDestination = CoordTransform.wgs84ToGcj02(destination);

    final body = await client.get('/v5/direction/bicycling', {
      'origin': _format(gcjOrigin),
      'destination': _format(gcjDestination),
      // Without show_fields the v5 response omits the polyline entirely and
      // there is nothing to draw or navigate along.
      'show_fields': 'cost,polyline,navi',
      'alternative_route': alternatives.clamp(1, 3).toString(),
    });

    final paths = _pathsOf(body);
    if (paths.isEmpty) {
      throw const RoutePlanningException('高德没有返回可用的骑行路线');
    }

    return _buildRoute(
      paths.first,
      origin: origin,
      destination: destination,
    );
  }

  Future<Route> _planMultiLeg({
    required List<GeoPoint> stops,
    required RoutePreference preference,
  }) async {
    final legs = <Route>[];
    for (var i = 0; i < stops.length - 1; i++) {
      legs.add(
        await _planLeg(
          origin: stops[i],
          destination: stops[i + 1],
          preference: preference,
        ),
      );
    }

    // Stitch: concatenate geometry (dropping the duplicated joint point) and
    // re-index the instructions into the merged polyline.
    final points = <GeoPoint>[];
    final instructions = <RouteInstruction>[];
    var totalDistance = 0.0;
    var totalDuration = Duration.zero;

    for (final leg in legs) {
      final offset = points.isEmpty ? 0 : points.length - 1;
      if (points.isEmpty) {
        points.addAll(leg.points);
      } else if (leg.points.isNotEmpty) {
        points.addAll(leg.points.skip(1));
      }

      for (final instruction in leg.instructions) {
        instructions.add(
          RouteInstruction(
            index: instructions.length,
            maneuver: instruction.maneuver,
            text: instruction.text,
            distanceMeters: instruction.distanceMeters,
            durationSeconds: instruction.durationSeconds,
            startPolylineIndex: instruction.startPolylineIndex + offset,
            endPolylineIndex: instruction.endPolylineIndex + offset,
            roadName: instruction.roadName,
          ),
        );
      }

      totalDistance += leg.distanceMeters;
      totalDuration += leg.estimatedDuration;
    }

    return Route(
      id: generateId(),
      name: '骑行路线',
      points: points,
      instructions: instructions,
      distanceMeters: totalDistance,
      estimatedDuration: totalDuration,
      provider: id,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Route _buildRoute(
    Map<String, dynamic> path, {
    required GeoPoint origin,
    required GeoPoint destination,
  }) {
    final points = <GeoPoint>[];
    final instructions = <RouteInstruction>[];

    var cumulativeStepDistance = 0.0;

    for (final step in _stepsOf(path)) {
      final startIndex = points.isEmpty ? 0 : points.length - 1;

      final stepPoints = _parsePolyline(step['polyline']?.toString());
      if (points.isEmpty) {
        points.addAll(stepPoints);
      } else if (stepPoints.isNotEmpty) {
        // The last point of the previous step is the first of this one;
        // keeping both would put a zero-length segment in the geometry and
        // make the turn banner fire a metre early.
        points.addAll(stepPoints.skip(1));
      }

      final endIndex = points.isEmpty ? 0 : points.length - 1;

      final stepDistance =
          _toDouble(step['step_distance']) ?? _polylineLength(stepPoints);
      cumulativeStepDistance += stepDistance;

      final instructionText = step['instruction']?.toString() ?? '';
      final roadName = step['road_name']?.toString();

      instructions.add(
        RouteInstruction(
          index: instructions.length,
          maneuver: _maneuverFor(instructionText, step),
          text: instructionText.isEmpty
              ? (roadName?.isNotEmpty == true ? '沿$roadName骑行' : '继续骑行')
              : instructionText,
          distanceMeters: stepDistance,
          durationSeconds: _stepDuration(step),
          startPolylineIndex: startIndex,
          endPolylineIndex: endIndex,
          roadName: (roadName != null && roadName.isNotEmpty) ? roadName : null,
        ),
      );
    }

    if (points.isEmpty) {
      throw const RoutePlanningException('高德返回的路线没有几何数据');
    }

    final apiDistance = _toDouble(path['distance']);
    final apiDuration = _toDouble(path['duration']);

    return Route(
      id: generateId(),
      name: '骑行路线',
      points: points,
      instructions: instructions,
      // Prefer the service's distance: it is measured along the road network,
      // while our polyline is simplified. Fall back to the geometry when the
      // field is absent.
      distanceMeters: apiDistance ?? _polylineLength(points),
      estimatedDuration: Duration(
        seconds: (apiDuration ?? cumulativeStepDistance / 4.2).round(),
      ),
      // AMap returns no altitude for cycling. Null, not zero.
      elevationGainMeters: null,
      provider: id,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  /// Alternative paths in a response, each a JSON object.
  ///
  /// Narrowed to `Map<String, dynamic>` here rather than at every use site:
  /// the response is untyped JSON, and letting a `List<dynamic>` reach the
  /// route builder turns a malformed response into a runtime cast error deep
  /// inside the parsing rather than a clean skip at the boundary.
  static List<Map<String, dynamic>> _pathsOf(Map<String, dynamic> body) {
    final route = body['route'];
    if (route is! Map<String, dynamic>) return const [];

    final paths = route['paths'];
    if (paths is! List) return const [];

    return paths.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  static List<Map<String, dynamic>> _stepsOf(Map<String, dynamic> path) {
    final steps = path['steps'];
    if (steps is! List) return const [];
    return steps.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  static double _stepDuration(Map<String, dynamic> step) {
    final navi = step['navi'];
    if (navi is Map<String, dynamic>) {
      final d = _toDouble(navi['duration']);
      if (d != null) return d;
    }
    final cost = step['cost'];
    if (cost is Map<String, dynamic>) {
      final d = _toDouble(cost['duration']);
      if (d != null) return d;
    }
    return 0;
  }

  /// Parses AMap's `"lng,lat;lng,lat"` polyline and converts it to WGS-84.
  static List<GeoPoint> _parsePolyline(String? raw) {
    if (raw == null || raw.isEmpty) return const [];

    final out = <GeoPoint>[];
    for (final pair in raw.split(';')) {
      final comma = pair.indexOf(',');
      if (comma <= 0) continue;
      final lng = double.tryParse(pair.substring(0, comma));
      final lat = double.tryParse(pair.substring(comma + 1));
      if (lng == null || lat == null) continue;
      if (lat.abs() > 90 || lng.abs() > 180) continue;
      // AMap returns GCJ-02. Everything downstream is WGS-84.
      out.add(CoordTransform.gcj02ToWgs84(GeoPoint(lat, lng)));
    }
    return out;
  }

  /// Maps a step to a maneuver.
  ///
  /// Keyword matching on the Chinese instruction text rather than the numeric
  /// `action` code: AMap's numeric codes have changed between v3 and v5 and
  /// are not documented consistently, while the instruction strings are
  /// stable and human-authored. `action` is used only as a tie-breaker.
  static Maneuver _maneuverFor(String text, Map<String, dynamic> step) {
    if (text.contains('环岛') || text.contains('环道')) return Maneuver.roundabout;
    if (text.contains('调头') || text.contains('掉头')) return Maneuver.uturn;
    if (text.contains('左前方') || text.contains('左前')) return Maneuver.slightLeft;
    if (text.contains('右前方') || text.contains('右前')) return Maneuver.slightRight;
    if (text.contains('左后方') || text.contains('左后')) return Maneuver.sharpLeft;
    if (text.contains('右后方') || text.contains('右后')) return Maneuver.sharpRight;
    if (text.contains('左转') || text.contains('向左')) return Maneuver.left;
    if (text.contains('右转') || text.contains('向右')) return Maneuver.right;
    if (text.contains('到达目的地') || text.contains('抵达终点')) {
      return Maneuver.arrive;
    }
    if (text.contains('出发')) return Maneuver.depart;
    if (text.contains('岔路') || text.contains('路口')) return Maneuver.fork;
    if (text.contains('直行') || text.contains('沿')) return Maneuver.straight;

    final action = step['action']?.toString();
    return Maneuver.fromAmapAction(action);
  }

  static double? _toDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static double _polylineLength(List<GeoPoint> points) =>
      polylineLengthMeters(points);

  /// `lng,lat` — AMap's ordering, the reverse of the rest of this codebase.
  static String _format(GeoPoint p) =>
      '${p.lng.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}';
}
