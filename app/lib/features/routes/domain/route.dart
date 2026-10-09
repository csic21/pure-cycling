import '../../../core/sync/sync_status.dart';
import '../../../core/utils/geo.dart';

/// Turn type for a navigation instruction.
///
/// Providers normalize their own vocabulary into this enum so the navigation
/// UI never has to parse provider-specific strings — and so swapping the map
/// vendor does not touch the pages.
enum Maneuver {
  straight('直行', 'straight'),
  slightLeft('稍向左', 'slight_left'),
  left('左转', 'left'),
  sharpLeft('向左急转', 'sharp_left'),
  slightRight('稍向右', 'slight_right'),
  right('右转', 'right'),
  sharpRight('向右急转', 'sharp_right'),
  uturn('调头', 'uturn'),
  roundabout('环岛', 'roundabout'),
  merge('汇入', 'merge'),
  fork('岔路', 'fork'),
  ramp('匝道', 'ramp'),
  ferry('轮渡', 'ferry'),
  waypoint('途经点', 'waypoint'),
  arrive('到达终点', 'arrive'),
  depart('出发', 'depart'),
  unknown('继续直行', 'unknown');

  const Maneuver(this.label, this.id);

  /// Short Chinese label shown under the arrow, per the spec's minimal-nav
  /// mock-up.
  final String label;
  final String id;

  static Maneuver fromId(String? id) => Maneuver.values.firstWhere(
        (m) => m.id == id,
        orElse: () => Maneuver.unknown,
      );

  static Maneuver fromAmapAction(String? action) {
    if (action == null || action.isEmpty) return Maneuver.straight;
    // AMap returns a numeric action code in v3/v5 directions responses.
    return switch (action) {
      'straight' || '直行' => Maneuver.straight,
      'left' || '左转' => Maneuver.left,
      'right' || '右转' => Maneuver.right,
      'left_front' || '左前方' => Maneuver.slightLeft,
      'right_front' || '右前方' => Maneuver.slightRight,
      'left_back' || '左后方' => Maneuver.sharpLeft,
      'right_back' || '右后方' => Maneuver.sharpRight,
      'uturn' || '调头' => Maneuver.uturn,
      'roundabout' || '环岛' => Maneuver.roundabout,
      'merge' || '汇入' => Maneuver.merge,
      'fork' || '岔路' => Maneuver.fork,
      'ramp' || '匝道' => Maneuver.ramp,
      'ferry' || '轮渡' => Maneuver.ferry,
      'waypoint' || '途经' => Maneuver.waypoint,
      'arrive' || '到达' => Maneuver.arrive,
      'depart' || '出发' => Maneuver.depart,
      _ => Maneuver.unknown,
    };
  }

  /// Whether this maneuver warrants briefly showing the map, per §8.2
  /// (complex junctions, roundabouts, consecutive turns).
  bool get isComplex =>
      this == Maneuver.roundabout ||
      this == Maneuver.fork ||
      this == Maneuver.merge ||
      this == Maneuver.ramp ||
      this == Maneuver.uturn ||
      this == Maneuver.sharpLeft ||
      this == Maneuver.sharpRight;
}

/// One leg of a planned route: a maneuver plus the polyline it applies to.
class RouteInstruction {
  const RouteInstruction({
    required this.index,
    required this.maneuver,
    required this.text,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.startPolylineIndex,
    required this.endPolylineIndex,
    this.roadName,
  });

  final int index;
  final Maneuver maneuver;

  /// Provider-supplied human text, e.g. 「沿人民大道骑行 1.2 公里」.
  final String text;

  /// Length of the leg this instruction covers.
  final double distanceMeters;
  final double durationSeconds;

  /// Index range into the route's polyline that this instruction covers.
  /// Used to locate the instruction on the map and to compute distance-to-turn
  /// by walking the geometry rather than trusting provider distances.
  final int startPolylineIndex;
  final int endPolylineIndex;

  final String? roadName;

  Map<String, dynamic> toJson() => {
        'index': index,
        'maneuver': maneuver.id,
        'text': text,
        'distance': distanceMeters,
        'duration': durationSeconds,
        'start': startPolylineIndex,
        'end': endPolylineIndex,
        if (roadName != null) 'road': roadName,
      };

  static RouteInstruction fromJson(Map<String, dynamic> json) =>
      RouteInstruction(
        index: (json['index'] as num?)?.toInt() ?? 0,
        maneuver: Maneuver.fromId(json['maneuver'] as String?),
        text: json['text'] as String? ?? '',
        distanceMeters: (json['distance'] as num?)?.toDouble() ?? 0,
        durationSeconds: (json['duration'] as num?)?.toDouble() ?? 0,
        startPolylineIndex: (json['start'] as num?)?.toInt() ?? 0,
        endPolylineIndex: (json['end'] as num?)?.toInt() ?? 0,
        roadName: json['road'] as String?,
      );
}

/// Metadata for a saved-route row. Geometry and turn instructions are loaded
/// only by the detail/navigation path, never to build the routes list.
class RouteSummary {
  const RouteSummary({
    required this.id,
    required this.name,
    required this.distanceMeters,
    required this.estimatedDuration,
    this.elevationGainMeters,
    this.favorite = false,
  });

  final String id;
  final String name;
  final double distanceMeters;
  final Duration estimatedDuration;
  final double? elevationGainMeters;
  final bool favorite;
}

/// A route the user planned, imported, or is navigating.
class Route {
  const Route({
    required this.id,
    required this.name,
    required this.points,
    this.instructions = const [],
    this.distanceMeters = 0,
    this.estimatedDuration = Duration.zero,
    this.elevationGainMeters,
    this.provider = 'local',
    this.providerRouteId,
    this.favorite = false,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
    this.syncStatus,
  });

  final String id;
  final String name;

  /// Full geometry, in order.
  final List<GeoPoint> points;
  final List<RouteInstruction> instructions;

  final double distanceMeters;
  final Duration estimatedDuration;

  /// Null when the provider does not supply elevation.
  ///
  /// AMap's cycling planner returns no altitude at all. Reporting that as
  /// `0 m` would be a claim, not a placeholder, so the absence is modelled
  /// explicitly and the UI shows `—`.
  final double? elevationGainMeters;

  /// Which [RouteProvider] produced this. Recorded so a route can be
  /// re-planned or attributed without guessing.
  final String provider;
  final String? providerRouteId;

  /// Starred by the rider.
  ///
  /// A local organising preference, not shared state: it is deliberately not
  /// queued for upload, because which of your own routes you starred is not
  /// something another device needs to be told.
  final bool favorite;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  final SyncStatus? syncStatus;

  bool get isDeleted => deletedAt != null;

  GeoPoint? get start => points.isEmpty ? null : points.first;
  GeoPoint? get end => points.isEmpty ? null : points.last;

  /// Average moving speed the provider assumed, used for ETA before the rider
  /// has any history of their own.
  double get assumedSpeedMps {
    final s = estimatedDuration.inMilliseconds / 1000.0;
    if (s <= 0) return 0;
    return distanceMeters / s;
  }

  Route copyWith({
    String? name,
    List<GeoPoint>? points,
    List<RouteInstruction>? instructions,
    double? distanceMeters,
    Duration? estimatedDuration,
    double? elevationGainMeters,
    String? provider,
    String? providerRouteId,
    bool? favorite,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return Route(
      id: id,
      name: name ?? this.name,
      points: points ?? this.points,
      instructions: instructions ?? this.instructions,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      elevationGainMeters: elevationGainMeters ?? this.elevationGainMeters,
      provider: provider ?? this.provider,
      providerRouteId: providerRouteId ?? this.providerRouteId,
      favorite: favorite ?? this.favorite,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      syncStatus: syncStatus,
    );
  }
}

/// A place returned by POI search or reverse geocoding.
class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.point,
    this.address,
    this.distanceMeters,
    this.id,
  });

  final String name;
  final GeoPoint point;
  final String? address;
  final double? distanceMeters;
  final String? id;

  String get subtitle => address ?? '';
}
