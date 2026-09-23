import 'package:drift/drift.dart';

import '../../../features/ride/domain/ride_engine.dart';
import '../database.dart';

part 'active_ride_dao.g.dart';

/// Crash-recovery checkpoints for the in-progress ride.
///
/// One row, rewritten every few seconds. Cheap enough to write at 0.2 Hz for
/// hours, and the difference between "the app crashed" and "I lost my
/// century ride".
@DriftAccessor(tables: [ActiveRideCheckpoints])
class ActiveRideDao extends DatabaseAccessor<AppDatabase>
    with _$ActiveRideDaoMixin {
  ActiveRideDao(super.db);

  Future<void> save(RideCheckpoint checkpoint) async {
    await into(activeRideCheckpoints).insertOnConflictUpdate(
      ActiveRideCheckpointsCompanion.insert(
        rideId: checkpoint.rideId,
        status: checkpoint.status,
        startedAt: checkpoint.startedAt.toUtc(),
        elapsedSeconds: Value(checkpoint.elapsed.inSeconds),
        movingSeconds: Value(checkpoint.moving.inSeconds),
        distanceMeters: Value(checkpoint.distanceMeters),
        maxSpeedMps: Value(checkpoint.maxSpeedMps),
        elevationGainMeters: Value(checkpoint.elevationGainMeters),
        elevationLossMeters: Value(checkpoint.elevationLossMeters),
        lastLat: Value(checkpoint.lastLat),
        lastLng: Value(checkpoint.lastLng),
        lastAltitude: Value(checkpoint.lastAltitude),
        lastSequence: Value(checkpoint.lastSequence),
        smoothedAltitudeMeters: Value(checkpoint.smoothedAltitudeMeters),
        smoothedSpeedMps: Value(checkpoint.smoothedSpeedMps),
        anchorLat: Value(checkpoint.anchorLat),
        anchorLng: Value(checkpoint.anchorLng),
        anchorTimestampMs: Value(checkpoint.anchorTimestampMs),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  /// The checkpoint to offer resuming, if the previous run died mid-ride.
  ///
  /// A checkpoint written by a clean `stop()` is deleted, so anything found
  /// here is by definition an interrupted ride.
  Future<RideCheckpoint?> loadUnfinished() async {
    final row = await select(activeRideCheckpoints).getSingleOrNull();
    if (row == null) return null;

    final status = RideStatus.values.firstWhere(
      (s) => s.name == row.status,
      orElse: () => RideStatus.riding,
    );
    // Nothing was ever recorded — a crash during the initial GPS fix. Not
    // worth offering to resume.
    if (row.lastSequence <= 0) return null;

    return RideCheckpoint(
      rideId: row.rideId,
      // A checkpoint written as the process was dying may say `finishing`;
      // resuming it as a ride in progress is the only useful interpretation.
      status: (status == RideStatus.finished || status == RideStatus.finishing)
          ? RideStatus.riding.name
          : status.name,
      startedAt: row.startedAt.toUtc(),
      elapsed: Duration(seconds: row.elapsedSeconds),
      moving: Duration(seconds: row.movingSeconds),
      distanceMeters: row.distanceMeters,
      maxSpeedMps: row.maxSpeedMps,
      elevationGainMeters: row.elevationGainMeters,
      elevationLossMeters: row.elevationLossMeters,
      lastLat: row.lastLat,
      lastLng: row.lastLng,
      lastAltitude: row.lastAltitude,
      lastSequence: row.lastSequence,
      smoothedAltitudeMeters: row.smoothedAltitudeMeters,
      smoothedSpeedMps: row.smoothedSpeedMps,
      anchorLat: row.anchorLat,
      anchorLng: row.anchorLng,
      anchorTimestampMs: row.anchorTimestampMs,
    );
  }

  Future<void> clear() async {
    await delete(activeRideCheckpoints).go();
  }

  Stream<bool> watchHasUnfinished() =>
      select(activeRideCheckpoints).watch().map((rows) => rows.isNotEmpty);
}
