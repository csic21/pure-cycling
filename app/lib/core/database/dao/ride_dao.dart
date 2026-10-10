import 'package:drift/drift.dart';

import '../../../features/ride/domain/ride.dart';
import '../../../features/ride/domain/track_point.dart';
import '../../utils/geo.dart';
import '../../utils/geometry_codec.dart';
import '../database.dart';
import '../mappers.dart';

part 'ride_dao.g.dart';

/// Reads and writes rides and their track points.
@DriftAccessor(tables: [LocalRides, TrackPoints])
class RideDao extends DatabaseAccessor<AppDatabase> with _$RideDaoMixin {
  RideDao(super.db);

  // ---- Rides ----

  /// Newest first, tombstones excluded.
  Stream<List<Ride>> watchRides({int limit = 200}) {
    final query = select(localRides)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
      ..limit(limit);
    return query.watch().map((rows) => rows.map((r) => r.toDomain()).toList());
  }

  Future<List<Ride>> getRides({int limit = 200}) {
    final query = select(localRides)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
      ..limit(limit);
    return query.get().then((rows) => rows.map((r) => r.toDomain()).toList());
  }

  Stream<Ride?> watchRide(String id) {
    final query = select(localRides)..where((t) => t.id.equals(id));
    return query.watchSingleOrNull().map((row) => row?.toDomain());
  }

  Future<Ride?> getRide(String id) async {
    final query = select(localRides)..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row?.toDomain();
  }

  /// Rides whose start falls within `[from, to)`, newest first.
  Future<List<Ride>> getRidesBetween(DateTime from, DateTime to) {
    final query = select(localRides)
      ..where(
        (t) =>
            t.deletedAt.isNull() &
            t.startedAt.isBiggerOrEqualValue(from.toUtc()) &
            t.startedAt.isSmallerThanValue(to.toUtc()),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]);
    return query.get().then((rows) => rows.map((r) => r.toDomain()).toList());
  }

  Stream<List<Ride>> watchRidesBetween(DateTime from, DateTime to) {
    final query = select(localRides)
      ..where(
        (t) =>
            t.deletedAt.isNull() &
            t.startedAt.isBiggerOrEqualValue(from.toUtc()) &
            t.startedAt.isSmallerThanValue(to.toUtc()),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]);
    return query.watch().map((rows) => rows.map((r) => r.toDomain()).toList());
  }

  Future<void> upsertRide(Ride ride) async {
    final existing = await getRide(ride.id);
    // Finishing/recovering a ride must retain the owner captured at its start,
    // including null. A login during a ride is not a transfer decision.
    final owner = existing == null
        ? (ride.ownerUserId ?? attachedDatabase.resolveOwner())
        : existing.ownerUserId;
    await into(localRides).insertOnConflictUpdate(
      rideToCompanion(ride).copyWith(ownerUserId: Value(owner)),
    );
  }

  Future<DateTime> _nextEditTime(String id) async {
    final previous = (await getRide(id))?.updatedAt;
    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    );
    return previous != null && !now.isAfter(previous)
        ? previous.add(const Duration(seconds: 1))
        : now;
  }

  /// Applies a partial edit (name, notes, bike) without touching metrics.
  ///
  /// After a ride ends its recorded numbers are effectively immutable
  /// (spec §28); only the descriptive fields may change, which keeps the sync
  /// merge trivial.
  Future<void> updateRideMetadata(
    String id, {
    String? name,
    String? notes,
    String? bikeId,
  }) async {
    final editedAt = await _nextEditTime(id);
    await (update(localRides)..where((t) => t.id.equals(id))).write(
      LocalRidesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        notes: notes == null ? const Value.absent() : Value(notes),
        bikeId: bikeId == null ? const Value.absent() : Value(bikeId),
        updatedAt: Value(editedAt),
      ),
    );
  }

  /// Writes the rider-editable description of a ride, exactly as given.
  ///
  /// Deliberately not [updateRideMetadata], which reads `null` as "leave this
  /// field alone". That contract makes 「把备注删掉」impossible to express —
  /// and the edit sheet, which always submits both fields, means `null` here
  /// really is the value.
  Future<void> setRideDescription(
    String id, {
    String? name,
    String? notes,
    DateTime? updatedAt,
  }) async {
    await (update(localRides)..where((t) => t.id.equals(id))).write(
      LocalRidesCompanion(
        name: Value(name),
        notes: Value(notes),
        updatedAt: Value(updatedAt?.toUtc() ?? await _nextEditTime(id)),
      ),
    );
  }

  /// Sync bookkeeping is not a content edit. Changing updatedAt here makes
  /// an acknowledged upload appear newer than the cloud and queues it again.
  Future<void> setSyncStatus(String id, SyncStatus status) async {
    await (update(localRides)..where((t) => t.id.equals(id))).write(
      LocalRidesCompanion(syncStatus: Value(status.id)),
    );
  }

  Future<void> setGpxPath(String id, String path) async {
    await (update(localRides)..where((t) => t.id.equals(id))).write(
      LocalRidesCompanion(gpxPath: Value(path)),
    );
  }

  /// Records that the cloud no longer holds a copy of anything.
  ///
  /// `gpx_path` is cleared because it addresses a Storage object that has just
  /// been removed — a path pointing at a 404 is worse than no path. The sync
  /// queue is *not* touched here; re-queueing is the caller's decision.
  Future<void> markCloudCopyGone({String? ownerUserId}) async {
    await (update(localRides)..where((t) => ownerUserId == null
        ? t.ownerUserId.isNull() : t.ownerUserId.equals(ownerUserId))).write(
      LocalRidesCompanion(
        syncStatus: Value(SyncStatus.localOnly.id),
        gpxPath: const Value(null),
      ),
    );
  }

  /// Soft-deletes a ride and its trace.
  ///
  /// The row survives so the tombstone can travel; the track points do not,
  /// because they are megabytes and carry no information a delete needs.
  Future<void> softDeleteRide(
    String id, {
    DateTime? deletedAt,
    DateTime? updatedAt,
  }) async {
    final now = updatedAt?.toUtc() ?? await _nextEditTime(id);
    await transaction(() async {
      await (update(localRides)..where((t) => t.id.equals(id))).write(
        LocalRidesCompanion(
          deletedAt: Value(deletedAt?.toUtc() ?? now),
          name: const Value(null), notes: const Value(null), bikeId: const Value(null),
          startLat: const Value(null), startLng: const Value(null),
          endLat: const Value(null), endLng: const Value(null),
          routeGeometryWkt: const Value(null),
          gpxPath: const Value(null), fitPath: const Value(null),
          syncStatus: Value(SyncStatus.pendingUpload.id),
          updatedAt: Value(updatedAt?.toUtc() ?? now),
        ),
      );
      await (delete(trackPoints)..where((t) => t.rideId.equals(id))).go();
    });
  }

  /// Removes a ride that was never finished.
  ///
  /// A hard delete, not a tombstone. The cloud has never seen this ride, so
  /// there is nothing to tell it about — a tombstone would queue a delete for
  /// a row that does not exist. The trace goes with it, by cascade.
  Future<void> purgeAbandonedRide(String id) async {
    await (delete(localRides)..where((t) => t.id.equals(id))).go();
  }

  // ---- Track points ----

  /// Bulk insert. Called periodically during a ride and once at the end.
  Future<void> insertTrackPoints(List<TrackPoint> points) async {
    if (points.isEmpty) return;
    await batch((b) {
      b.insertAll(trackPoints, points.map(trackPointToCompanion).toList());
    });
  }

  Future<List<TrackPoint>> getTrackPoints(String rideId) async {
    final query = select(trackPoints)
      ..where((t) => t.rideId.equals(rideId))
      ..orderBy([(t) => OrderingTerm.asc(t.sequence)]);
    final rows = await query.get();
    return rows.map((r) => r.toDomain()).toList();
  }

  /// Streams the trace so the live map and the detail screen can draw a
  /// growing line without re-querying.
  Stream<List<TrackPoint>> watchTrackPoints(String rideId) {
    final query = select(trackPoints)
      ..where((t) => t.rideId.equals(rideId))
      ..orderBy([(t) => OrderingTerm.asc(t.sequence)]);
    return query.watch().map((rows) => rows.map((r) => r.toDomain()).toList());
  }

  Future<int> trackPointCount(String rideId) async {
    final count = trackPoints.id.count();
    final query = selectOnly(trackPoints)
      ..addColumns([count])
      ..where(trackPoints.rideId.equals(rideId));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<TrackPoint?> lastTrackPoint(String rideId) async {
    final query = select(trackPoints)
      ..where((t) => t.rideId.equals(rideId))
      ..orderBy([(t) => OrderingTerm.desc(t.sequence)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.toDomain();
  }

  /// The trace as coordinates, for map rendering.
  Future<List<GeoPoint>> getTrackGeometry(String rideId) async {
    final points = await getTrackPoints(rideId);
    return points.map((p) => p.geo).toList(growable: false);
  }

  /// Builds and persists the WKT line for cloud upload (spec §23).
  Future<String?> buildRouteGeometryWkt(String rideId) async {
    final points = await getTrackPoints(rideId);
    if (points.length < 2) return null;
    final wkt = trackToLineStringWkt(points.map((p) => p.geo).toList());
    await (update(localRides)..where((t) => t.id.equals(rideId))).write(
      LocalRidesCompanion(routeGeometryWkt: Value(wkt)),
    );
    return wkt;
  }

  // ---- Aggregates ----

  /// Local-time month boundaries, converted to the UTC instants the column
  /// stores.
  ///
  /// This matters: a ride logged at 00:30 on the 1st in UTC+8 is 16:30 on the
  /// last day of the previous month in UTC, and a rider who sees it land in the
  /// wrong month's total will not trust any other number in the app.
  static ({DateTime start, DateTime end}) monthBounds(DateTime month) {
    return (
      start: DateTime(month.year, month.month).toUtc(),
      end: DateTime(month.year, month.month + 1).toUtc(),
    );
  }

  /// Total distance and ride count for the month containing [month].
  Future<RideSummary> monthSummary(DateTime month) async {
    final b = monthBounds(month);
    final rides = await getRidesBetween(b.start, b.end);
    return RideSummary.from(rides);
  }

  Stream<RideSummary> watchMonthSummary(DateTime month) {
    final b = monthBounds(month);
    return watchRidesBetween(b.start, b.end).map(RideSummary.from);
  }

  Future<Ride?> mostRecentRide() async {
    final query = select(localRides)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.toDomain();
  }

  Stream<Ride?> watchMostRecentRide() {
    final query = select(localRides)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
      ..limit(1);
    return query.watchSingleOrNull().map((row) => row?.toDomain());
  }

  /// Rides needing upload, oldest first so the queue drains in order.
  Future<List<Ride>> ridesAwaitingSync({int limit = 20}) async {
    final query = select(localRides)
      ..where(
        (t) => t.syncStatus.isIn([
          SyncStatus.pendingUpload.id,
          SyncStatus.syncFailed.id,
        ]),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.startedAt)])
      ..limit(limit);
    final rows = await query.get();
    return rows.map((r) => r.toDomain()).toList();
  }
}
