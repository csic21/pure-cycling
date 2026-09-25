import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/ride/data/ride_repository.dart';
import '../../features/ride/domain/ride.dart';
import '../../features/ride/domain/track_point.dart';
import '../../features/routes/data/route_repository.dart';
import '../../features/settings/domain/app_settings.dart';
import '../database/dao/sync_queue_dao.dart';
import '../database/database.dart';
import '../gpx/gpx_codec.dart';
import 'supabase_config.dart';
import 'supabase_remote.dart';
import 'sync_status.dart';

/// What the sync engine is doing, for the settings screen.
enum SyncPhase {
  notConfigured,
  signedOut,

  /// The rider turned cloud sync off. Nothing is uploaded — this phase exists
  /// so the screen can say that instead of showing an idle cloud.
  disabled,

  idle,
  syncing,
  offline,
  failed,
}

class SyncReport {
  const SyncReport({
    this.phase = SyncPhase.idle,
    this.pendingCount = 0,
    this.uploaded = 0,
    this.downloaded = 0,
    this.message,
    this.lastSyncedAt,
  });

  final SyncPhase phase;
  final int pendingCount;

  /// Records pushed to the cloud in the last run.
  final int uploaded;

  /// Records pulled from the cloud in the last run.
  final int downloaded;

  final String? message;
  final DateTime? lastSyncedAt;

  bool get isBusy => phase == SyncPhase.syncing;

  SyncReport copyWith({
    SyncPhase? phase,
    int? pendingCount,
    int? uploaded,
    int? downloaded,
    String? message,
    DateTime? lastSyncedAt,
  }) =>
      SyncReport(
        phase: phase ?? this.phase,
        pendingCount: pendingCount ?? this.pendingCount,
        uploaded: uploaded ?? this.uploaded,
        downloaded: downloaded ?? this.downloaded,
        message: message ?? this.message,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );
}

/// Drains the local outbox to Supabase and merges the cloud back down.
///
/// ## Ordering
///
/// Push before pull, always. A ride recorded on this device has never been
/// seen by the cloud, and pulling first would mean reconciling against a
/// dataset that is missing the newest thing the user cares about.
///
/// ## What a failure costs
///
/// Nothing local. Every failure path here leaves the local record untouched and
/// the outbox entry in place with a backoff. There is no code path in this
/// file that deletes or overwrites a local ride because the network was
/// unhappy — that is the whole point of the local-first design (spec §16).
class SyncService {
  SyncService({
    required AppDatabase db,
    required RideRepository rides,
    required RouteRepository routes,
    required AuthResolver resolveClient,
    Connectivity? connectivity,
  })  : _db = db,
        _rides = rides,
        _routes = routes,
        _resolveClient = resolveClient,
        _connectivity = connectivity ?? Connectivity();

  final AppDatabase _db;
  final RideRepository _rides;
  final RouteRepository _routes;
  final AuthResolver _resolveClient;
  final Connectivity _connectivity;

  final _controller = StreamController<SyncReport>.broadcast();
  Stream<SyncReport> get reports => _controller.stream;

  SyncReport _report = const SyncReport();
  SyncReport get report => _report;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _retryTimer;
  bool _running = false;
  bool _started = false;

  /// Last successful sync, used as the pull watermark.
  DateTime? _lastPulledAt;

  AppSettings _settings = const AppSettings();

  void applySettings(AppSettings settings) {
    _settings = settings;
  }

  void _emit(SyncReport report) {
    _report = report;
    if (!_controller.isClosed) _controller.add(report);
  }

  /// Begins listening for connectivity changes.
  ///
  /// There is no polling loop. A sync is attempted when the network comes
  /// back, when the app resumes, after a ride ends, and when the user asks —
  /// which between them cover every moment the answer could have changed.
  void start() {
    if (_started) return;
    _started = true;

    _emit(_report.copyWith(phase: _baselinePhase));

    _connectivitySub =
        _connectivity.onConnectivityChanged.listen((results) {
      if (_isOnline(results)) {
        // A network appearing is the best possible moment to retry: the queue
        // is drained, and any backoff is cleared so the retry is immediate
        // rather than waiting out the window from the last failure.
        unawaited(_db.syncQueueDao.resetBackoff().then((_) => syncNow()));
      } else {
        _emit(_report.copyWith(phase: SyncPhase.offline));
      }
    });

    unawaited(_refreshPendingCount());
  }

  Future<void> stop() async {
    _started = false;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  /// Runs a full push-then-pull cycle.
  ///
  /// [force] bypasses the "wifi only" preference, for an explicit user action
  /// — a rider tapping 立即同步 on cellular means it. It does **not** bypass
  /// the cloud-sync switch: that one is a privacy promise, and a promise with
  /// a bypass is not a promise.
  ///
  /// This method is the single choke point for the switch on purpose. Every
  /// trigger — network returning, the backlog retry, app resume, login,
  /// pull-to-refresh, the manual button — funnels through here, so the gate
  /// cannot be forgotten in a new call site. It is checked before the client
  /// is resolved and before connectivity is queried, so "off" means no
  /// network work at all.
  Future<SyncReport> syncNow({bool force = false}) async {
    if (_running) return _report;

    if (!_settings.cloudSync) {
      _emit(_report.copyWith(phase: SyncPhase.disabled, message: null));
      return _report;
    }

    final client = _resolveClient();
    if (client == null || !SupabaseConfig.isConfigured) {
      _emit(_report.copyWith(phase: SyncPhase.notConfigured));
      return _report;
    }
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      _emit(_report.copyWith(phase: SyncPhase.signedOut));
      return _report;
    }

    if (!_isOnline(await _connectivity.checkConnectivity())) {
      _emit(_report.copyWith(phase: SyncPhase.offline));
      return _report;
    }

    if (_settings.wifiOnlyUpload && !force) {
      final results = await _connectivity.checkConnectivity();
      if (!results.contains(ConnectivityResult.wifi) &&
          !results.contains(ConnectivityResult.ethernet)) {
        _emit(
          _report.copyWith(
            phase: SyncPhase.idle,
            message: '已设置为仅 Wi-Fi 上传',
          ),
        );
        return _report;
      }
    }

    _running = true;
    _emit(_report.copyWith(phase: SyncPhase.syncing, message: null));

    final remote = SupabaseRemote(client, userId);
    var uploaded = 0;
    var downloaded = 0;

    try {
      uploaded = await _push(remote);
      downloaded = await _pull(remote);

      _emit(
        SyncReport(
          phase: SyncPhase.idle,
          pendingCount: await _db.syncQueueDao.pendingCount(),
          uploaded: uploaded,
          downloaded: downloaded,
          lastSyncedAt: DateTime.now(),
          message: _describe(uploaded, downloaded),
        ),
      );
    } catch (e) {
      _emit(
        _report.copyWith(
          phase: SyncPhase.failed,
          pendingCount: await _db.syncQueueDao.pendingCount(),
          message: _describeError(e),
        ),
      );
    } finally {
      _running = false;
    }

    return _report;
  }

  // ---- Push ----

  Future<int> _push(SupabaseRemote remote) async {
    final due = await _db.syncQueueDao.due(limit: 25);
    var uploaded = 0;

    for (final item in due) {
      try {
        switch (item.entityType) {
          case SyncEntityType.ride:
            await _pushRide(remote, item);
            uploaded++;
          case SyncEntityType.route:
            await _pushRoute(remote, item);
            uploaded++;
          case SyncEntityType.settings:
            await remote.pushSettings(_settings);
            uploaded++;
        }
        await _db.syncQueueDao.remove(item.id);
      } catch (e) {
        // Mark failed and move on. One poisoned entry must not stall the rest
        // of the queue — a ride deleted on the server, a malformed id — and
        // the backoff keeps a persistent failure from hammering the network.
        await _db.syncQueueDao.markFailed(item.id, _describeError(e));
      }
    }

    // Keep the outbox from growing without bound: a long offline tour could
    // queue hundreds of rides and one pass only takes 25.
    if (due.length == 25) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 30), () => unawaited(syncNow()));
    }

    return uploaded;
  }

  Future<void> _pushRide(SupabaseRemote remote, PendingSyncItem item) async {
    final ride = await _rides.getRide(item.entityId);
    if (ride == null) {
      // The local row is gone entirely; nothing to push. Dropping the entry
      // is correct — a hard-deleted record has no tombstone to propagate.
      await _db.syncQueueDao.remove(item.id);
      return;
    }

    if (item.operation == SyncOperation.delete) {
      final withTombstone = ride.copyWith(
        deletedAt: ride.deletedAt ?? DateTime.now().toUtc(),
      );
      await remote.pushRide(withTombstone);
      if (ride.gpxPath != null) {
        await remote.deleteGpx(ride.gpxPath!);
      }
      await _rides.setSyncStatus(ride.id, SyncStatus.synced);
      return;
    }

    // Upload the GPX first: the row references `gpx_path`, and a row pointing
    // at an object that is not there is worse than an object nobody points to.
    var gpxPath = ride.gpxPath;
    if (!ride.isDeleted) {
      try {
        final file = await _rides.exportGpx(ride);
        gpxPath = await remote.uploadGpx(
          rideId: ride.id,
          localFilePath: file.path,
        );
        await _rides.setGpxPath(ride.id, gpxPath);
      } catch (_) {
        // No trace on this device — the ride was created elsewhere, or the
        // file was removed. Push the statistics anyway; the geometry and the
        // summary are still worth having in the cloud.
        gpxPath = ride.gpxPath;
      }
    }

    await remote.pushRide(
      ride.copyWith(gpxPath: gpxPath, updatedAt: DateTime.now().toUtc()),
    );
    await _rides.setSyncStatus(ride.id, SyncStatus.synced);
  }

  Future<void> _pushRoute(SupabaseRemote remote, PendingSyncItem item) async {
    final route = await _routes.getRoute(item.entityId);
    if (route == null) {
      await _db.syncQueueDao.remove(item.id);
      return;
    }
    await remote.pushRoute(route);
    await _db.routeDao.setSyncStatus(route.id, SyncStatus.synced);
  }

  // ---- Pull ----

  Future<int> _pull(SupabaseRemote remote) async {
    var applied = 0;

    // Conflict policy (spec §28): the local copy of a ride wins whenever it is
    // newer. Rides are immutable after they end apart from name, notes and
    // bike, so the only field that can genuinely conflict is a rename — and
    // the later edit is the one the rider meant.
    final remoteRides = await remote.fetchRides(since: _lastPulledAt);
    for (final remoteRide in remoteRides) {
      if (await _mergeRemoteRide(remoteRide)) applied++;
    }

    final deleted = await remote.fetchDeletedRides(since: _lastPulledAt);
    for (final tombstone in deleted) {
      final local = await _rides.getRide(tombstone.id);
      if (local == null) continue;
      // A local delete is already consistent; only a live local copy needs
      // tombstoning.
      if (local.isDeleted) continue;
      if (local.updatedAt != null && local.updatedAt!.isAfter(tombstone.updatedAt)) {
        // Edited here more recently than it was deleted elsewhere. Local wins.
        continue;
      }
      await _rides.applyRemoteDelete(tombstone.id);
      applied++;
    }

    final remoteRoutes = await remote.fetchRoutes(since: _lastPulledAt);
    for (final route in remoteRoutes) {
      if (route.isDeleted) {
        if (await _routes.getRoute(route.id) != null) {
          await _routes.applyRemoteDelete(route.id);
        }
        continue;
      }
      // Routes are planning artefacts, not a record of something that
      // happened: if it exists locally, the local copy is at least as good.
      if (await _routes.getRoute(route.id) != null) continue;
      if (route.points.length < 2) continue;
      await _routes.saveRoute(route, enqueue: false);
      applied++;
    }

    _lastPulledAt = DateTime.now().toUtc();
    return applied;
  }

  /// Returns true when the local store changed.
  Future<bool> _mergeRemoteRide(RemoteRide remote) async {
    final local = await _rides.getRide(remote.id);

    if (local == null) {
      // A ride that exists only in the cloud — the new-phone case.
      await _rides.insertRemoteRide(
        Ride(
          id: remote.id,
          name: remote.name,
          startedAt: remote.startedAt,
          endedAt: remote.endedAt,
          stats: RideStats(
            distanceMeters: remote.distanceMeters,
            elapsed: Duration(seconds: remote.elapsedSeconds),
            moving: Duration(seconds: remote.movingSeconds),
          ),
          gpxPath: remote.gpxPath,
          syncStatus: SyncStatus.synced,
          syncVersion: remote.syncVersion,
          updatedAt: remote.updatedAt,
        ),
      );
      return true;
    }

    if (local.updatedAt != null && local.updatedAt!.isAfter(remote.updatedAt)) {
      // Local is newer — re-queue the push so the cloud catches up, rather
      // than overwriting the local edit with a stale copy.
      await _db.syncQueueDao.enqueue(
        SyncEntityType.ride,
        local.id,
        SyncOperation.upsert,
      );
      return false;
    }

    // Cloud is newer. Only the fields a rider can edit are taken: the recorded
    // statistics on this device came off a GPS receiver and are not something
    // to overwrite from a summary row.
    if (local.name != remote.name && remote.name != null) {
      await _rides.applyRemoteMetadata(
        local.id,
        name: remote.name,
        gpxPath: remote.gpxPath,
      );
      return true;
    }
    return false;
  }

  // ---- Helpers ----

  SyncPhase get _baselinePhase {
    // Off before anything else: the screen must not say "已就绪" while the
    // rider has switched uploading off.
    if (!_settings.cloudSync) return SyncPhase.disabled;
    if (!SupabaseConfig.isConfigured) return SyncPhase.notConfigured;
    if (_resolveClient()?.auth.currentUser == null) return SyncPhase.signedOut;
    return SyncPhase.idle;
  }

  Future<void> _refreshPendingCount() async {
    final count = await _db.syncQueueDao.pendingCount();
    _emit(_report.copyWith(pendingCount: count, phase: _baselinePhase));
  }

  /// connectivity_plus reports "no network" as a single-element list holding
  /// `none`, not as an empty list.
  static bool _isOnline(List<ConnectivityResult> results) =>
      results.isNotEmpty &&
      !(results.length == 1 && results.first == ConnectivityResult.none);

  static String _describe(int uploaded, int downloaded) {
    if (uploaded == 0 && downloaded == 0) return '已是最新';
    final parts = <String>[];
    if (uploaded > 0) parts.add('上传 $uploaded 条');
    if (downloaded > 0) parts.add('下载 $downloaded 条');
    return parts.join('，');
  }

  static String _describeError(Object error) {
    if (error is StorageException) {
      return '存储错误：${error.message}';
    }
    if (error is PostgrestException) {
      // 42501 is a row-level security violation, which for this app almost
      // always means the session expired mid-sync.
      if (error.code == '42501') return '权限校验失败，请重新登录';
      return '同步失败：${error.message}';
    }
    if (error is AuthException) {
      return '登录状态失效：${error.message}';
    }
    final text = error.toString();
    if (text.contains('SocketException') || text.contains('Failed host lookup')) {
      return '网络不可用';
    }
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  /// Loads a ride's track points from Storage when they are missing locally.
  ///
  /// This is what makes a ride pulled onto a new phone actually openable: the
  /// cloud stores the summary and a GPX object, not per-point rows, so the
  /// trace has to be re-imported on demand. Returns the number of points
  /// loaded, or 0 when there is nothing to load.
  Future<int> hydrateTrace(String rideId) async {
    final client = _resolveClient();
    if (client == null) return 0;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return 0;

    final ride = await _rides.getRide(rideId);
    if (ride?.gpxPath == null) return 0;
    if (await _rides.trackPointCount(rideId) > 1) return 0;

    final remote = SupabaseRemote(client, userId);
    final xml = await remote.downloadGpx(ride!.gpxPath!);
    if (xml == null) return 0;

    final parsed = GpxCodec.decode(xml);
    if (parsed.isEmpty) return 0;

    // Sequences are renumbered from 1 rather than trusted from the file: the
    // GPX holds positions and times, not our row identifiers, and a file
    // exported from another tool may have no sequence at all.
    final points = <TrackPoint>[];
    for (var i = 0; i < parsed.points.length; i++) {
      final p = parsed.points[i];
      points.add(
        TrackPoint(
          rideId: rideId,
          sequence: i + 1,
          timestamp: p.time ?? ride.startedAt,
          lat: p.point.lat,
          lng: p.point.lng,
          altitude: p.elevation,
          speed: p.speed,
        ),
      );
    }

    await _rides.importTrackPoints(rideId, points);
    return points.length;
  }
}

/// Resolves the current Supabase client, or null when unavailable.
typedef AuthResolver = SupabaseClient? Function();
