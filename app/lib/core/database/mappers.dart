import 'package:drift/drift.dart';

import '../../features/ride/domain/ride.dart';
import '../../features/ride/domain/track_point.dart';
import '../../features/routes/domain/route.dart';
import '../utils/geo.dart';
import '../utils/geometry_codec.dart';
import 'database.dart';

/// Translation between drift row classes and domain models.
///
/// Keeping this in one file means the domain never imports drift, and the
/// tables can be reshaped without hunting for conversion logic across
/// repositories.

extension LocalRideRowMapper on LocalRide {
  Ride toDomain() => Ride(
        id: id,
        ownerUserId: ownerUserId,
        name: name,
        startedAt: startedAt.toUtc(),
        endedAt: endedAt?.toUtc(),
        stats: RideStats(
          distanceMeters: distanceMeters,
          elapsed: Duration(seconds: elapsedSeconds),
          moving: Duration(seconds: movingSeconds),
          avgSpeedMps: avgSpeedMps ?? 0,
          maxSpeedMps: maxSpeedMps ?? 0,
          elevationGainMeters: elevationGainMeters ?? 0,
          elevationLossMeters: elevationLossMeters ?? 0,
        ),
        startPoint: (startLat != null && startLng != null)
            ? GeoPoint(startLat!, startLng!)
            : null,
        endPoint:
            (endLat != null && endLng != null) ? GeoPoint(endLat!, endLng!) : null,
        routeGeometryWkt: routeGeometryWkt,
        gpxPath: gpxPath,
        fitPath: fitPath,
        syncStatus: SyncStatus.fromId(syncStatus),
        syncVersion: syncVersion,
        notes: notes,
        bikeId: bikeId,
        deletedAt: deletedAt?.toUtc(),
        createdAt: createdAt.toUtc(),
        updatedAt: updatedAt.toUtc(),
      );
}

/// Builds the companion for inserting or fully replacing a ride row.
LocalRidesCompanion rideToCompanion(Ride ride) {
  final now = DateTime.now().toUtc();
  return LocalRidesCompanion(
    id: Value(ride.id),
    ownerUserId: Value(ride.ownerUserId),
    name: Value(ride.name),
    startedAt: Value(ride.startedAt.toUtc()),
    endedAt: Value(ride.endedAt?.toUtc()),
    elapsedSeconds: Value(ride.stats.elapsed.inSeconds),
    movingSeconds: Value(ride.stats.moving.inSeconds),
    distanceMeters: Value(ride.stats.distanceMeters),
    avgSpeedMps: Value(ride.stats.avgSpeedMps),
    maxSpeedMps: Value(ride.stats.maxSpeedMps),
    elevationGainMeters: Value(ride.stats.elevationGainMeters),
    elevationLossMeters: Value(ride.stats.elevationLossMeters),
    startLat: Value(ride.startPoint?.lat),
    startLng: Value(ride.startPoint?.lng),
    endLat: Value(ride.endPoint?.lat),
    endLng: Value(ride.endPoint?.lng),
    routeGeometryWkt: Value(ride.routeGeometryWkt),
    gpxPath: Value(ride.gpxPath),
    fitPath: Value(ride.fitPath),
    syncStatus: Value(ride.syncStatus.id),
    syncVersion: Value(ride.syncVersion),
    notes: Value(ride.notes),
    bikeId: Value(ride.bikeId),
    deletedAt: Value(ride.deletedAt?.toUtc()),
    createdAt: Value(ride.createdAt?.toUtc() ?? now),
    updatedAt: Value(ride.updatedAt?.toUtc() ?? now),
  );
}

extension TrackPointRowMapper on TrackPointRow {
  TrackPoint toDomain() => TrackPoint(
        rideId: rideId,
        sequence: sequence,
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true),
        lat: lat,
        lng: lng,
        altitude: altitude,
        speed: speed,
        bearing: bearing,
        horizontalAccuracy: horizontalAccuracy,
        verticalAccuracy: verticalAccuracy,
        heartRate: heartRate,
        cadence: cadence,
        power: power,
      );
}

/// Companion for a single track point. `id` is left unset so SQLite assigns
/// the autoincrement value.
TrackPointsCompanion trackPointToCompanion(TrackPoint point) =>
    TrackPointsCompanion(
      rideId: Value(point.rideId),
      sequence: Value(point.sequence),
      timestampMs: Value(point.timestamp.toUtc().millisecondsSinceEpoch),
      lat: Value(point.lat),
      lng: Value(point.lng),
      altitude: Value(point.altitude),
      speed: Value(point.speed),
      bearing: Value(point.bearing),
      horizontalAccuracy: Value(point.horizontalAccuracy),
      verticalAccuracy: Value(point.verticalAccuracy),
      heartRate: Value(point.heartRate),
      cadence: Value(point.cadence),
      power: Value(point.power),
    );

extension SavedRouteRowMapper on SavedRouteRow {
  Route toDomain() => Route(
        id: id,
        ownerUserId: ownerUserId,
        name: name,
        points: decodeGeometry(geometryJson),
        instructions: decodeInstructions(instructionsJson),
        distanceMeters: distanceMeters,
        estimatedDuration: Duration(seconds: estimatedSeconds),
        elevationGainMeters: elevationGainMeters,
        provider: provider,
        providerRouteId: providerRouteId,
        favorite: favorite,
        createdAt: createdAt.toUtc(),
        updatedAt: updatedAt.toUtc(),
        deletedAt: deletedAt?.toUtc(),
        syncStatus: SyncStatus.fromId(syncStatus),
      );
}

SavedRoutesCompanion routeToCompanion(Route route) {
  final now = DateTime.now().toUtc();
  return SavedRoutesCompanion(
    id: Value(route.id),
    ownerUserId: Value(route.ownerUserId),
    name: Value(route.name),
    distanceMeters: Value(route.distanceMeters),
    estimatedSeconds: Value(route.estimatedDuration.inSeconds),
    elevationGainMeters: Value(route.elevationGainMeters),
    geometryJson: Value(encodeGeometry(route.points)),
    instructionsJson: Value(encodeInstructions(route.instructions)),
    provider: Value(route.provider),
    providerRouteId: Value(route.providerRouteId),
    favorite: Value(route.favorite),
    syncStatus: Value(
      (route.syncStatus is SyncStatus)
          ? (route.syncStatus as SyncStatus).id
          : SyncStatus.localOnly.id,
    ),
    createdAt: Value(route.createdAt?.toUtc() ?? now),
    updatedAt: Value(route.updatedAt?.toUtc() ?? now),
    deletedAt: Value(route.deletedAt?.toUtc()),
  );
}
