import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:drift/drift.dart';

import '../../../core/database/dao/ride_dao.dart';
import '../../../core/database/database.dart';
import '../../../core/fit/fit_codec.dart';
import '../../../core/gpx/gpx_codec.dart';
import '../../../core/sync/sync_status.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/ids.dart';
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
  RideRepository(this._db, {Future<Directory> Function()? documentsDirectory})
      : _documentsDirectory = documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;
  static final _exportStates = Expando<Map<String, _RideExportState>>();
  _RideExportState _exportState(String id) =>
      (_exportStates[_db] ??= {}).putIfAbsent(id, _RideExportState.new);

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

  Future<int> trackPointCount(String rideId) => _rides.trackPointCount(rideId);

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
      Ride(id: id, startedAt: startedAt, syncStatus: SyncStatus.localOnly),
    );
  }

  /// Persists a finished ride and everything derived from it.
  ///
  /// [unflushed] carries the points still sitting in the recorder's write
  /// buffer. They are inserted first so that the geometry and the GPX below
  /// are built from the *complete* trace, read back from the database, rather
  /// than from whichever fragment happened to be in memory.
  ///
  /// The local record, outbox and recovery removal commit together, followed
  /// by regenerable derived artefacts.
  /// Nothing here can reach the network, so nothing here can fail because of
  /// it.
  Future<void> saveFinishedRide(
    Ride ride, {
    List<TrackPoint> unflushed = const [],
    bool writeExport = true,
  }) async {
    await _db.transaction(() async {
      await _rides.upsertRide(ride);
      if (unflushed.isNotEmpty) {
        await _rides.insertTrackPoints(unflushed);
      }
      // The upload payload reads this column directly. Keep its construction
      // inside the commit so a write failure cannot enqueue an incomplete ride.
      await _rides.buildRouteGeometryWkt(ride.id);
      await _db.syncQueueDao.enqueue(
        SyncEntityType.ride,
        ride.id,
        SyncOperation.upsert,
      );
      await _rides.setSyncStatus(ride.id, SyncStatus.pendingUpload);
      // Recovery is removed only with the durable ride and its outbox entry.
      // An exception at any step rolls all of these changes back together.
      await (_db.delete(
        _db.activeRideCheckpoints,
      )..where((t) => t.rideId.equals(ride.id))).go();
    });

    // The GPX is written in the background, not awaited.
    //
    // It is derived from the trace, which is already committed, and both the
    // export action and the sync upload regenerate it on demand when the file
    // is missing. Awaiting it would make the rider watch a two-megabyte flash
    // write before the app would admit their ride was saved — the one step on
    // this path that can block on the file system, for no benefit.
    if (writeExport) unawaited(_writeGpxInBackground(ride));
  }

  /// Saves the rider's description of a finished ride: the two fields the
  /// edit sheet always sends in full.
  ///
  /// `null` clears. That is the difference from [updateMetadata], and the
  /// reason this exists: an empty name and an absent name are the same letter
  /// to the rider, and a field they cannot empty is a field that is write-once.
  Future<void> updateDescription(
    String id, {
    required String? name,
    required String? notes,
  }) async {
    await _db.transaction(() async {
      await _rides.setRideDescription(id, name: name, notes: notes);
      // These are the only fields editable after a ride (spec §28), which is
      // what keeps the merge with the cloud trivial — there is never a statistic
      // to reconcile.
      await _db.syncQueueDao.enqueue(
        SyncEntityType.ride,
        id,
        SyncOperation.upsert,
      );
      await _rides.setSyncStatus(id, SyncStatus.pendingUpload);
    });
  }

  Future<void> updateMetadata(
    String id, {
    String? name,
    String? notes,
    String? bikeId,
  }) async {
    await _db.transaction(() async {
      await _rides.updateRideMetadata(
        id,
        name: name,
        notes: notes,
        bikeId: bikeId,
      );
      // Only these three fields are editable after a ride (spec §28), which is
      // what keeps the merge with the cloud trivial — there is never a
      // statistic to reconcile.
      await _db.syncQueueDao.enqueue(
        SyncEntityType.ride,
        id,
        SyncOperation.upsert,
      );
      await _rides.setSyncStatus(id, SyncStatus.pendingUpload);
    });
  }

  /// Erases a ride the rider abandoned before finishing.
  ///
  /// Distinct from [deleteRide]: that tombstones a real ride so the deletion
  /// propagates, this removes a row that only ever existed because recording
  /// had to have something to attach track points to.
  Future<void> purgeAbandonedRide(String id) => _rides.purgeAbandonedRide(id);

  Future<void> deleteRide(String id) async {
    final state = _exportState(id);
    state.generation++;
    final old = await _rides.getRide(id);
    await _db.transaction(() async {
      await _rides.softDeleteRide(id);
      await _db.syncQueueDao.enqueue(
        SyncEntityType.ride,
        id,
        SyncOperation.delete,
      );
    });
    await _removeRideExports(id, old);
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
  ///
  /// Writes through [RideDao.setRideDescription] rather than
  /// [updateDescription]: the latter enqueues an upload, and a pull that
  /// immediately pushes back is a sync loop with extra steps.
  Future<void> applyRemoteMetadata(
    String id, {
    required String? name,
    required String? notes,
    required DateTime updatedAt,
    String? gpxPath,
    bool restoreLive = false,
  }) async {
    await _rides.setRideDescription(
      id,
      name: name,
      notes: notes,
      updatedAt: updatedAt,
    );
    await (_db.update(_db.localRides)..where((t) => t.id.equals(id))).write(
      LocalRidesCompanion(
        gpxPath: Value(gpxPath),
        deletedAt: restoreLive ? const Value(null) : const Value.absent(),
      ),
    );
    await _rides.setSyncStatus(id, SyncStatus.synced);
  }

  /// Applies a delete that arrived from the cloud.
  Future<void> applyRemoteDelete(
    String id, {
    DateTime? deletedAt,
    DateTime? updatedAt,
  }) async {
    final state = _exportState(id);
    state.generation++;
    final old = await _rides.getRide(id);
    await _rides.softDeleteRide(id, deletedAt: deletedAt, updatedAt: updatedAt);
    await _rides.setSyncStatus(id, SyncStatus.synced);
    await _removeRideExports(id, old);
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
    return _writeOwnedExport(ride, 'gpx', () => utf8.encode(GpxCodec.encode(ride, trace)));
  }

  /// Writes a regenerable local GPX off the critical path. Local filenames
  /// never replace the cloud object reference in the ride row.
  Future<void> _writeGpxInBackground(Ride ride) async {
    try {
      final trace = await _rides.getTrackPoints(ride.id);
      await writeGpxFile(ride, trace);
    } catch (_) {
      // Regenerable; the export and upload paths both rebuild it on demand.
    }
  }

  /// Re-generates the GPX from the stored trace. Used by the export action and
  /// by any ride whose file went missing.
  Future<File> exportGpx(Ride ride) async {
    final trace = await trackPoints(ride.id);
    final path = await writeGpxFile(ride, trace);
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
    return _writeOwnedExport(ride, 'fit', () => FitCodec.encode(ride, trace));
  }

  /// Re-generates the FIT from the stored trace, for the export action.
  Future<File> exportFit(Ride ride) async {
    final trace = await trackPoints(ride.id);
    final path = await writeFitFile(ride, trace);
    return File(path);
  }

  Future<Directory> _exportsDirectory() async {
    final base = await _documentsDirectory();
    final dir = Directory('${base.path}/exports');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // Only this directory is ride-owned. Never delete a path supplied by the
  // user, a share target, or an arbitrary gpxPath/fitPath from the cloud.
  String _ownedDirectoryName(String id) => base64Url.encode(utf8.encode(id)).replaceAll('=', '');

  Future<String> _writeOwnedExport(Ride ride, String extension,
      List<int> Function() encode) async {
    final state = _exportState(ride.id);
    final generation = state.generation;
    // Database work precedes the filesystem lease. A remote merge can hold a
    // DB transaction while waiting for old writers without a lock inversion.
    final current = await _rides.getRide(ride.id);
    if (current == null || current.isDeleted || generation != state.generation) {
      throw StateError('骑行已删除，不能导出');
    }
    final completer = Completer<String>();
    state.pending = state.pending.then((_) async {
      File? temporary;
      try {
        if (generation != state.generation) throw StateError('骑行已删除，不能导出');
        final exports = await _exportsDirectory();
        final dir = Directory('${exports.path}/rides/${_ownedDirectoryName(ride.id)}');
        await dir.create(recursive: true);
        final file = File('${dir.path}/${_safeFileName(ride)}.$extension');
        temporary = File('${file.path}.${generateId()}.tmp');
        await temporary.writeAsBytes(encode(), flush: true);
        if (generation != state.generation) throw StateError('骑行已删除，不能导出');
        await temporary.rename(file.path);
        if (generation != state.generation) {
          if (await file.exists()) await file.delete();
          throw StateError('骑行已删除，不能导出');
        }
        completer.complete(file.path);
      } catch (error, stack) {
        if (temporary != null && await temporary.exists()) await temporary.delete();
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _removeRideExports(String id, Ride? previous) async {
    await _exportState(id).pending;
    final exports = await _exportsDirectory();
    final owned = Directory('${exports.path}/rides/${_ownedDirectoryName(id)}');
    if (await owned.exists()) await owned.delete(recursive: true);
    if (previous == null) return;
    // Legacy files lacked a ride directory. Only recognize our own GPX header
    // with this ride's exact UTC start. Bound the read, never parse user XML.
    final stamp = '${previous.startedAt.toUtc().toIso8601String().split('.').first}Z';
    await for (final entry in exports.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.gpx')) continue;
      final handle = await entry.open();
      late String header;
      try { header = utf8.decode(await handle.read(8192), allowMalformed: true); }
      finally { await handle.close(); }
      if (!header.contains('creator="PureCycling"') ||
          !header.contains('<time>$stamp</time>')) continue;
      await entry.delete();
      // FIT files generated beside an identified legacy GPX share its stem.
      final fit = File('${entry.path.substring(0, entry.path.length - 4)}.fit');
      if (await fit.exists()) await fit.delete();
    }
  }

  static String _safeFileName(Ride ride) {
    final local = ride.startedAt.toLocal();
    final stamp =
        '${local.year}${local.month.toString().padLeft(2, '0')}'
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

class _RideExportState {
  int generation = 0;
  Future<void> pending = Future<void>.value();
}
