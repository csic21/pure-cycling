import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../core/database/dao/ride_dao.dart';
import '../../../core/database/database.dart';
import '../../../core/fit/fit_codec.dart';
import '../../../core/gpx/gpx_codec.dart';
import '../../../core/sync/sync_status.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/geometry_codec.dart';
import '../domain/ride.dart';
import '../domain/track_point.dart';

/// Reads and writes rides, and owns the side work that hangs off a completed
/// ride: geometry, GPX, and the sync outbox entry.
///
/// The side work is done *after* the ride row is committed and is allowed to
/// fail — a ride whose GPX could not be written is still a ride, and the
/// export can be regenerated from the stored trace at any time.
class RideRepository {
  RideRepository(this._db);

  final AppDatabase _db;

  RideDao get _rides => _db.rideDao;

  // ---- Reads ----

  Stream<List<Ride>> watchRides({int limit = 200}) =>
      _rides.watchRides(limit: limit);

  Stream<RideSummary> watchMonthSummary(DateTime month) =>
      _rides.watchMonthSummary(month);

  Stream<Ride?> watchMostRecent() => _rides.watchMostRecentRide();

  Stream<Ride?> watchRide(String id) => _rides.watchRide(id);

  Future<Ride?> getRide(String id) => _rides.getRide(id);

  Future<List<Ride>> getRides({int limit = 200}) =>
      _rides.getRides(limit: limit);

  Stream<List<TrackPoint>> watchTrackPoints(String rideId) =>
      _rides.watchTrackPoints(rideId);

  Future<List<TrackPoint>> trackPoints(String rideId) =>
      _rides.getTrackPoints(rideId);

  Future<List<GeoPoint>> trackGeometry(String rideId) =>
      _rides.getTrackGeometry(rideId);

  Future<int> trackPointCount(String rideId) =>
      _rides.trackPointCount(rideId);

  // ---- Writes ----

  /// Records that a ride has begun.
  ///
  /// The row exists from the first moment of recording rather than from the
  /// end, and that ordering is load-bearing: `track_points` carries a foreign
  /// key to `local_rides`, and with `PRAGMA foreign_keys = ON` a point written
  /// before its parent is rejected outright. The batching writer swallowed
  /// that rejection, so a ride would save its summary and lose its entire
  /// trace — the map, the GPX and the elevation profile would all be empty,
  /// with nothing anywhere to say why.
  ///
  /// It is also what makes an interrupted ride visible: a row exists for the
  /// whole time the ride does.
  Future<void> beginRide({
    required String id,
    required DateTime startedAt,
  }) async {
    await _rides.upsertRide(
      Ride(
        id: id,
        startedAt: startedAt,
        syncStatus: SyncStatus.localOnly,
      ),
    );
  }

  /// Persists a finished ride and everything derived from it.
  ///
  /// [unflushed] carries the points still sitting in the recorder's write
  /// buffer. They are inserted first so that the geometry and the GPX below
  /// are built from the *complete* trace, read back from the database, rather
  /// than from whichever fragment happened to be in memory.
  ///
  /// Ordering mirrors spec §27: the local commit happens first and
  /// unconditionally, then the derived artefacts, then the outbox entry.
  /// Nothing here can reach the network, so nothing here can fail because of
  /// it.
  Future<void> saveFinishedRide(
    Ride ride, {
    List<TrackPoint> unflushed = const [],
  }) async {
    await _rides.upsertRide(ride);

    if (unflushed.isNotEmpty) {
      await _rides.insertTrackPoints(unflushed);
    }

    final trace = await _rides.getTrackPoints(ride.id);

    // PostGIS geometry — one LineString instead of N rows (spec §23).
    if (trace.length >= 2) {
      await _rides.buildRouteGeometryWkt(ride.id);
    }

    // The GPX is written in the background, not awaited.
    //
    // It is derived from the trace, which is already committed, and both the
    // export action and the sync upload regenerate it on demand when the file
    // is missing. Awaiting it would make the rider watch a two-megabyte flash
    // write before the app would admit their ride was saved — the one step on
    // this path that can block on the file system, for no benefit.
    unawaited(_writeGpxInBackground(ride));

    await _db.syncQueueDao.enqueue(
      SyncEntityType.ride,
      ride.id,
      SyncOperation.upsert,
    );
    await _rides.setSyncStatus(ride.id, SyncStatus.pendingUpload);
  }

  Future<void> updateMetadata(
    String id, {
    String? name,
    String? notes,
    String? bikeId,
  }) async {
    await _rides.updateRideMetadata(id, name: name, notes: notes, bikeId: bikeId);
    // Only these three fields are editable after a ride (spec §28), which is
    // what keeps the merge with the cloud trivial — there is never a
    // statistic to reconcile.
    await _db.syncQueueDao.enqueue(
      SyncEntityType.ride,
      id,
      SyncOperation.upsert,
    );
    await _rides.setSyncStatus(id, SyncStatus.pendingUpload);
  }

  /// Erases a ride the rider abandoned before finishing.
  ///
  /// Distinct from [deleteRide]: that tombstones a real ride so the deletion
  /// propagates, this removes a row that only ever existed because recording
  /// had to have something to attach track points to.
  Future<void> purgeAbandonedRide(String id) => _rides.purgeAbandonedRide(id);

  Future<void> deleteRide(String id) async {
    await _rides.softDeleteRide(id);
    await _db.syncQueueDao.enqueue(
      SyncEntityType.ride,
      id,
      SyncOperation.delete,
    );
  }

  // ---- Cloud reconciliation ----

  /// Inserts a ride that exists only in the cloud.
  ///
  /// Used on a new device, where the summary arrives immediately but the track
  /// points do not — those live in Storage and are fetched on demand by
  /// `SyncService.hydrateTrace` when the rider actually opens the ride.
  Future<void> insertRemoteRide(Ride ride) async {
    // The row must not carry a pending status: it came *from* the cloud, and
    // marking it for upload would push back what was just pulled.
    await _rides.upsertRide(ride.copyWith(syncStatus: SyncStatus.synced));
    await _rides.setSyncStatus(ride.id, SyncStatus.synced);
  }

  /// Takes the cloud's descriptive fields without touching recorded metrics.
  ///
  /// Distance, time and climb on this device came off a GPS receiver. They are
  /// not something to overwrite from a summary row, even when the cloud copy
  /// is newer.
  Future<void> applyRemoteMetadata(
    String id, {
    String? name,
    String? gpxPath,
  }) async {
    await _rides.updateRideMetadata(id, name: name);
    if (gpxPath != null) {
      await _rides.setGpxPath(id, gpxPath);
    }
    await _rides.setSyncStatus(id, SyncStatus.synced);
  }

  /// Applies a delete that arrived from the cloud.
  Future<void> applyRemoteDelete(String id) async {
    await _rides.softDeleteRide(id);
    await _rides.setSyncStatus(id, SyncStatus.synced);
  }

  /// Bulk-inserts track points recovered from a GPX file.
  Future<void> importTrackPoints(String rideId, List<TrackPoint> points) async {
    if (points.isEmpty) return;
    await _rides.insertTrackPoints(points);
    if (points.length >= 2) {
      await _rides.buildRouteGeometryWkt(rideId);
    }
  }

  /// Records the outcome of an upload attempt.
  Future<void> setSyncStatus(String id, SyncStatus status) =>
      _rides.setSyncStatus(id, status);

  /// Records where the ride's GPX ended up in Storage.
  Future<void> setGpxPath(String id, String path) =>
      _rides.setGpxPath(id, path);

  // ---- GPX ----

  /// Writes the ride's GPX to the app documents directory and returns the
  /// absolute path.
  Future<String> writeGpxFile(Ride ride, List<TrackPoint> trace) async {
    final dir = await _exportsDirectory();
    final file = File('${dir.path}/${_safeFileName(ride)}.gpx');
    await file.writeAsString(
      GpxCodec.encode(ride, trace),
      flush: true,
    );
    return file.path;
  }

  /// Writes the GPX to disk and records where it went, off the critical path.
  Future<void> _writeGpxInBackground(Ride ride) async {
    try {
      final trace = await _rides.getTrackPoints(ride.id);
      final path = await writeGpxFile(ride, trace);
      await _rides.setGpxPath(ride.id, path);
    } catch (_) {
      // Regenerable; the export and upload paths both rebuild it on demand.
    }
  }

  /// Re-generates the GPX from the stored trace. Used by the export action and
  /// by any ride whose file went missing.
  Future<File> exportGpx(Ride ride) async {
    final trace = await trackPoints(ride.id);
    final path = await writeGpxFile(ride, trace);
    await _rides.setGpxPath(ride.id, path);
    return File(path);
  }

  // ---- FIT ----

  /// Writes the ride's FIT to the app documents directory and returns the
  /// absolute path.
  ///
  /// Not persisted on the ride row: unlike the GPX, nothing uploads this file,
  /// so the path would be a column with no reader. It is regenerated from the
  /// trace every time the rider exports it, which is also what keeps it
  /// correct after a rename.
  Future<String> writeFitFile(Ride ride, List<TrackPoint> trace) async {
    final dir = await _exportsDirectory();
    final file = File('${dir.path}/${_safeFileName(ride)}.fit');
    await file.writeAsBytes(
      FitCodec.encode(ride, trace),
      flush: true,
    );
    return file.path;
  }

  /// Re-generates the FIT from the stored trace, for the export action.
  Future<File> exportFit(Ride ride) async {
    final trace = await trackPoints(ride.id);
    final path = await writeFitFile(ride, trace);
    return File(path);
  }

  Future<Directory> _exportsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/exports');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _safeFileName(Ride ride) {
    final local = ride.startedAt.toLocal();
    final stamp = '${local.year}${local.month.toString().padLeft(2, '0')}'
        '${local.day.toString().padLeft(2, '0')}-'
        '${local.hour.toString().padLeft(2, '0')}'
        '${local.minute.toString().padLeft(2, '0')}';
    final title = (ride.name ?? '').replaceAll(RegExp(r'[^\w一-龥-]'), '');
    return title.isEmpty ? stamp : '${stamp}_$title';
  }

  /// Builds the WKT line without persisting it, for the upload payload.
  Future<String?> buildGeometryWkt(String rideId) async {
    final ride = await getRide(rideId);
    if (ride?.routeGeometryWkt != null) return ride!.routeGeometryWkt;
    return _rides.buildRouteGeometryWkt(rideId);
  }

  /// Convenience for the export flow: the trace as a WKT-encoded line.
  static String lineStringWkt(List<GeoPoint> points) =>
      trackToLineStringWkt(points);
}
