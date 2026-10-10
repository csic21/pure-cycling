import '../../../core/sync/sync_status.dart';
import '../../../core/utils/geo.dart';

export '../../../core/sync/sync_status.dart' show SyncStatus;

/// Aggregated metrics for a ride.
///
/// This is the contract the dashboard renders and the database stores. It is
/// deliberately a plain value object so it can be produced incrementally by
/// [RideEngine] while riding and reconstructed from the database later without
/// either side knowing about the other.
class RideStats {
  const RideStats({
    this.distanceMeters = 0,
    this.elapsed = Duration.zero,
    this.moving = Duration.zero,
    this.currentSpeedMps = 0,
    this.avgSpeedMps = 0,
    this.maxSpeedMps = 0,
    this.altitudeMeters = 0,
    this.elevationGainMeters = 0,
    this.elevationLossMeters = 0,
    this.gradePercent = 0,
    this.heartRate,
    this.avgHeartRate,
    this.cadence,
    this.avgCadence,
    this.power,
    this.avgPower,
  });

  /// The all-zero stats of a ride that has not started recording yet.
  static const RideStats empty = RideStats();

  final double distanceMeters;
  final Duration elapsed;
  final Duration moving;

  final double currentSpeedMps;
  final double avgSpeedMps;
  final double maxSpeedMps;

  final double altitudeMeters;
  final double elevationGainMeters;
  final double elevationLossMeters;

  /// Current gradient in percent. Positive is uphill.
  final double gradePercent;

  final int? heartRate;
  final int? avgHeartRate;
  final int? cadence;
  final int? avgCadence;
  final int? power;
  final int? avgPower;

  /// Average over moving time, not elapsed — otherwise every red light would
  /// drag the number down.
  static double computeAvgSpeed(double distanceMeters, Duration moving) {
    final seconds = moving.inMilliseconds / 1000.0;
    if (seconds <= 0.5) return 0;
    return distanceMeters / seconds;
  }

  RideStats copyWith({
    double? distanceMeters,
    Duration? elapsed,
    Duration? moving,
    double? currentSpeedMps,
    double? avgSpeedMps,
    double? maxSpeedMps,
    double? altitudeMeters,
    double? elevationGainMeters,
    double? elevationLossMeters,
    double? gradePercent,
    int? heartRate,
    int? avgHeartRate,
    int? cadence,
    int? avgCadence,
    int? power,
    int? avgPower,
  }) {
    return RideStats(
      distanceMeters: distanceMeters ?? this.distanceMeters,
      elapsed: elapsed ?? this.elapsed,
      moving: moving ?? this.moving,
      currentSpeedMps: currentSpeedMps ?? this.currentSpeedMps,
      avgSpeedMps: avgSpeedMps ?? this.avgSpeedMps,
      maxSpeedMps: maxSpeedMps ?? this.maxSpeedMps,
      altitudeMeters: altitudeMeters ?? this.altitudeMeters,
      elevationGainMeters: elevationGainMeters ?? this.elevationGainMeters,
      elevationLossMeters: elevationLossMeters ?? this.elevationLossMeters,
      gradePercent: gradePercent ?? this.gradePercent,
      heartRate: heartRate ?? this.heartRate,
      avgHeartRate: avgHeartRate ?? this.avgHeartRate,
      cadence: cadence ?? this.cadence,
      avgCadence: avgCadence ?? this.avgCadence,
      power: power ?? this.power,
      avgPower: avgPower ?? this.avgPower,
    );
  }
}

/// A completed (or in-progress) ride record.
class Ride {
  const Ride({
    required this.id,
    this.ownerUserId,
    required this.startedAt,
    this.endedAt,
    this.name,
    this.stats = RideStats.empty,
    this.startPoint,
    this.endPoint,
    this.gpxPath,
    this.fitPath,
    this.routeGeometryWkt,
    this.syncStatus = SyncStatus.localOnly,
    this.syncVersion = 1,
    this.notes,
    this.bikeId,
    this.deletedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? ownerUserId;
  final String? name;
  final DateTime startedAt;
  final DateTime? endedAt;

  final RideStats stats;

  final GeoPoint? startPoint;
  final GeoPoint? endPoint;

  /// Path within Supabase Storage, e.g. `rides/<uid>/<rideId>/original.gpx`.
  final String? gpxPath;
  final String? fitPath;

  /// WKT `LINESTRING(...)`, built at ride end for the PostGIS column.
  ///
  /// Track points are never uploaded one row per point; the cloud gets the
  /// summary plus this line, and the full trace lives in Storage as GPX.
  final String? routeGeometryWkt;

  final SyncStatus syncStatus;
  final int syncVersion;

  final String? notes;
  final String? bikeId;

  /// Tombstone. A deleted ride stays in SQLite so a stale offline device
  /// cannot resurrect it on the next sync.
  final DateTime? deletedAt;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isDeleted => deletedAt != null;

  Duration get elapsed => stats.elapsed;
  Duration get moving => stats.moving;
  double get distanceMeters => stats.distanceMeters;

  /// Display name, falling back to a date-based one.
  String displayName(String fallback) =>
      (name != null && name!.trim().isNotEmpty) ? name!.trim() : fallback;

  Ride copyWith({
    String? ownerUserId,
    String? name,
    DateTime? endedAt,
    RideStats? stats,
    GeoPoint? startPoint,
    GeoPoint? endPoint,
    String? gpxPath,
    String? fitPath,
    String? routeGeometryWkt,
    SyncStatus? syncStatus,
    int? syncVersion,
    String? notes,
    String? bikeId,
    DateTime? deletedAt,
    DateTime? updatedAt,
  }) {
    return Ride(
      id: id,
      ownerUserId: ownerUserId ?? this.ownerUserId,
      name: name ?? this.name,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      stats: stats ?? this.stats,
      startPoint: startPoint ?? this.startPoint,
      endPoint: endPoint ?? this.endPoint,
      gpxPath: gpxPath ?? this.gpxPath,
      fitPath: fitPath ?? this.fitPath,
      routeGeometryWkt: routeGeometryWkt ?? this.routeGeometryWkt,
      syncStatus: syncStatus ?? this.syncStatus,
      syncVersion: syncVersion ?? this.syncVersion,
      notes: notes ?? this.notes,
      bikeId: bikeId ?? this.bikeId,
      deletedAt: deletedAt ?? this.deletedAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Aggregate over a set of rides — the month summary on the history screen.
class RideSummary {
  const RideSummary({
    this.rideCount = 0,
    this.distanceMeters = 0,
    this.moving = Duration.zero,
    this.elevationGainMeters = 0,
  });

  final int rideCount;
  final double distanceMeters;
  final Duration moving;
  final double elevationGainMeters;

  static RideSummary from(Iterable<Ride> rides) {
    var count = 0;
    var distance = 0.0;
    var moving = Duration.zero;
    var gain = 0.0;
    for (final r in rides) {
      count++;
      distance += r.stats.distanceMeters;
      moving += r.stats.moving;
      gain += r.stats.elevationGainMeters;
    }
    return RideSummary(
      rideCount: count,
      distanceMeters: distance,
      moving: moving,
      elevationGainMeters: gain,
    );
  }
}
