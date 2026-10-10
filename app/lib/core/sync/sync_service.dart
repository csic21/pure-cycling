import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/ride/data/ride_repository.dart';
import '../../features/ride/domain/ride.dart';
import '../../features/ride/domain/track_point.dart';
import '../../features/routes/data/route_repository.dart';
import '../../features/routes/domain/route.dart' as routes;
import '../../features/settings/domain/app_settings.dart';
import '../database/dao/sync_queue_dao.dart';
import '../database/database.dart';
import '../gpx/gpx_codec.dart';
import 'supabase_config.dart';
import 'cloud_data_wipe_client.dart';
import 'functions_config.dart';
import 'supabase_remote.dart';
import 'sync_status.dart';
import 'sync_wake_scheduler.dart';

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
  }) => SyncReport(
    phase: phase ?? this.phase,
    pendingCount: pendingCount ?? this.pendingCount,
    uploaded: uploaded ?? this.uploaded,
    downloaded: downloaded ?? this.downloaded,
    message: message ?? this.message,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
  );
}

/// The outcome of a "delete my cloud data" action.
class CloudDeleteReport {
  const CloudDeleteReport({
    this.ok = false,
    this.rides = 0,
    this.routes = 0,
    this.files = 0,
    this.message,
  });

  final bool ok;
  final int rides;
  final int routes;
  final int files;

  /// Why nothing was deleted, when [ok] is false.
  final String? message;

  String get summary =>
      ok ? '已删除云端数据（本次清理 $files 个 GPX 文件）' : (message ?? '删除失败');
}

/// Drains the local outbox to Supabase and merges the cloud back down.
///
/// ## Ordering
///
/// Push before pull. Postgres atomically chooses each winner and returns it;
/// neither ordering nor a client-side preflight can resolve concurrent edits.
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
    bool Function()? isConfigured,
    CloudDataWipeClient? cloudWipeClient,
  }) : _cloudWipeClient = cloudWipeClient,
       _db = db,
       _rides = rides,
       _routes = routes,
       _resolveClient = resolveClient,
       _connectivity = connectivity ?? Connectivity(),
       _isConfigured = isConfigured ?? (() => SupabaseConfig.isConfigured);

  final CloudDataWipeClient? _cloudWipeClient;
  final AppDatabase _db;
  final RideRepository _rides;
  final RouteRepository _routes;
  final AuthResolver _resolveClient;
  final Connectivity _connectivity;
  final bool Function() _isConfigured;

  final _controller = StreamController<SyncReport>.broadcast();
  Stream<SyncReport> get reports => _controller.stream;

  SyncReport _report = const SyncReport();
  SyncReport get report => _report;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<DateTime?>? _queueSub;
  late final _wake = SyncWakeScheduler(onWake: () => unawaited(syncNow()));
  int _scheduleGeneration = 0;
  bool _disposed = false;
  bool _running = false;
  bool _started = false;
  bool _syncAfterIdentityChange = false;
  StreamSubscription<AuthState>? _authSub;
  SupabaseClient? _observedClient;
  int _identityGeneration = 0;

  void _observeIdentity(SupabaseClient client) {
    if (identical(_observedClient, client)) return;
    unawaited(_authSub?.cancel());
    _observedClient = client;
    _identityGeneration++;
    String? lastUser = client.auth.currentUser?.id;
    _authSub = client.auth.onAuthStateChange.listen((event) {
      final next = event.session?.user.id;
      if (lastUser == next) return;
      lastUser = next;
      _identityGeneration++;
      _scheduleGeneration++;
      _wake.cancel();
      if (_running) { _syncAfterIdentityChange = true; }
      else { unawaited(syncNow()); }
    }, onError: (Object error, StackTrace stack) {
      _identityGeneration++;
    });
  }

  void _checkIdentity(SupabaseClient client, String userId, int generation) {
    if (_disposed || generation != _identityGeneration ||
        !identical(_resolveClient(), client) ||
        client.auth.currentUser?.id != userId) {
      throw StateError('账号已切换，已暂停旧账号的同步；本机记录保留');
    }
  }

  AppSettings _settings = const AppSettings();

  void applySettings(AppSettings settings) {
    _settings = settings;
    if (!settings.cloudSync) {
      _scheduleGeneration++;
      _wake.cancel();
    } else if (_started) {
      unawaited(_scheduleNextWake());
    }
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

    _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
      if (_isOnline(results)) {
        // A network appearing is the best possible moment to retry: the queue
        // is drained, and any backoff is cleared so the retry is immediate
        // rather than waiting out the window from the last failure.
        unawaited(_db.syncQueueDao.resetBackoff().then((_) => syncNow()));
      } else {
        _emit(_report.copyWith(phase: SyncPhase.offline));
      }
    });

    _queueSub = _db.syncQueueDao.watchNextAttempt().listen((_) {
      unawaited(_scheduleNextWake());
    });
    unawaited(_refreshPendingCount());
  }

  Future<void> stop() async {
    _started = false;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    await _queueSub?.cancel();
    _queueSub = null;
    _scheduleGeneration++;
    _wake.cancel();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    _identityGeneration++;
    await _authSub?.cancel();
    _wake.dispose();
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
    if (_running || _disposed) return _report;
    _wake.cancel();

    if (!_settings.cloudSync) {
      _emit(_report.copyWith(phase: SyncPhase.disabled, message: null));
      return _report;
    }

    final client = _resolveClient();
    if (client == null || !_isConfigured()) {
      _emit(_report.copyWith(phase: SyncPhase.notConfigured));
      return _report;
    }
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      _emit(_report.copyWith(phase: SyncPhase.signedOut));
      return _report;
    }

    _observeIdentity(client);
    final generation = _identityGeneration;
    void checkIdentity() => _checkIdentity(client, userId, generation);
    _running = true;
    _scheduleGeneration++;
    try {
      if (!_isOnline(await _connectivity.checkConnectivity())) {
        _emit(_report.copyWith(phase: SyncPhase.offline));
        return _report;
      }

      if (_settings.wifiOnlyUpload && !force) {
        final results = await _connectivity.checkConnectivity();
        if (!results.contains(ConnectivityResult.wifi) &&
            !results.contains(ConnectivityResult.ethernet)) {
          _emit(
            _report.copyWith(phase: SyncPhase.idle, message: '已设置为仅 Wi-Fi 上传'),
          );
          return _report;
        }
      }

      _emit(_report.copyWith(phase: SyncPhase.syncing, message: null));

      checkIdentity();
      final remote = SupabaseRemote(client, userId, checkIdentity: checkIdentity);
      var uploaded = 0;
      var downloaded = 0;

      try {
        uploaded = await _push(remote, checkIdentity);
        checkIdentity();
        downloaded = await _pull(remote, checkIdentity);
        checkIdentity();

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
      }

      return _report;
    } finally {
      _running = false;
      if (_syncAfterIdentityChange && !_disposed) {
        _syncAfterIdentityChange = false;
        unawaited(syncNow());
      }
      // A blocked network/preference waits for connectivity/settings changes.
      if (_report.phase != SyncPhase.offline &&
          _report.message != '已设置为仅 Wi-Fi 上传') {
        await _scheduleNextWake(minimumDelay: const Duration(seconds: 1));
      }
    }
  }

  Future<void> _scheduleNextWake({
    Duration minimumDelay = Duration.zero,
  }) async {
    final generation = ++_scheduleGeneration;
    if (!_started || _disposed || _running || !_settings.cloudSync) return;
    final owner = _resolveClient()?.auth.currentUser?.id;
    if (owner == null) return;
    final deadline = await _db.syncQueueDao.nextAttempt(ownerUserId: owner);
    if (generation != _scheduleGeneration ||
        !_started ||
        _disposed ||
        _running ||
        !_settings.cloudSync) {
      return;
    }
    _wake.schedule(deadline, minimumDelay: minimumDelay);
  }

  /// Explicit UI consent binds only unassigned local records. Existing owners
  /// are immutable; signing in or enabling sync never invokes this method.
  Future<int> assignUnownedDataToAccount(String confirmedUserId) async {
    final client = _resolveClient();
    if (client == null || client.auth.currentUser?.id != confirmedUserId) {
      throw StateError('账号已切换，请重新确认');
    }
    _observeIdentity(client);
    final generation = _identityGeneration;
    return _db.transaction(() async {
      _checkIdentity(client, confirmedUserId, generation);
      final rides = await (_db.select(_db.localRides)
        ..where((t) => t.ownerUserId.isNull())).get();
      final routes = await (_db.select(_db.savedRoutes)
        ..where((t) => t.ownerUserId.isNull())).get();
      for (final ride in rides) {
        await (_db.update(_db.localRides)..where((t) => t.id.equals(ride.id)))
          .write(LocalRidesCompanion(ownerUserId: Value(confirmedUserId)));
        await _db.syncQueueDao.enqueue(SyncEntityType.ride, ride.id,
          ride.deletedAt == null ? SyncOperation.upsert : SyncOperation.delete);
      }
      for (final route in routes) {
        await (_db.update(_db.savedRoutes)..where((t) => t.id.equals(route.id)))
          .write(SavedRoutesCompanion(ownerUserId: Value(confirmedUserId)));
        await _db.syncQueueDao.enqueue(SyncEntityType.route, route.id,
          route.deletedAt == null ? SyncOperation.upsert : SyncOperation.delete);
      }
      // A sign-out while the transaction awaited SQLite rolls everything back.
      _checkIdentity(client, confirmedUserId, generation);
      return rides.length + routes.length;
    });
  }

  // ---- Push ----

  Future<int> _push(SupabaseRemote remote, void Function() checkIdentity) async {
    final due = await _db.syncQueueDao.due(limit: 25, ownerUserId: remote.userId);
    var uploaded = 0;

    for (final item in due) {
      checkIdentity();
      if (_disposed || !_settings.cloudSync) break;
      if (!await _db.syncQueueDao.contains(item.id)) continue;
      try {
        switch (item.entityType) {
          case SyncEntityType.ride:
            if (await _pushRide(remote, item, checkIdentity)) uploaded++;
          case SyncEntityType.route:
            if (await _pushRoute(remote, item, checkIdentity)) uploaded++;
          case SyncEntityType.settings:
            await remote.pushSettings(_settings);
            uploaded++;
        }
        checkIdentity();
        await _db.syncQueueDao.remove(item.id);
      } catch (e) {
        checkIdentity();
        // Mark failed and move on. One poisoned entry must not stall the rest
        // of the queue — a ride deleted on the server, a malformed id — and
        // the backoff keeps a persistent failure from hammering the network.
        await _db.syncQueueDao.markFailed(item.id, _describeError(e));
      }
    }

    return uploaded;
  }

  Future<bool> _pushRide(SupabaseRemote remote, PendingSyncItem item,
      void Function() checkIdentity) async {
    final ride = await _rides.getRide(item.entityId);
    if (ride == null || ride.ownerUserId != remote.userId || item.ownerUserId != remote.userId) return false;
    String? candidate;
    var path =
        SupabaseConfig.isRideGpxPath(ride.gpxPath, remote.userId, ride.id)
        ? ride.gpxPath
        : null;
    if (!ride.isDeleted &&
        path == null &&
        await _rides.trackPointCount(ride.id) > 1) {
      final file = await _rides.exportGpx(ride);
      candidate = await remote.uploadGpx(
        rideId: ride.id,
        localFilePath: file.path,
      );
      path = candidate;
    }
    // The RPC alone arbitrates competing writes. A preflight GET would race.
    late final PushResult<RemoteRide> result;
    try {
      result = await remote.pushRide(ride.copyWith(gpxPath: path));
    } on PostgrestException catch (error) {
      if (error.code != 'PC001' || candidate != null || ride.isDeleted) rethrow;
      if (await _rides.trackPointCount(ride.id) < 2) {
        throw StateError('云端轨迹已删除，本机暂无可重新上传的轨迹');
      }
      // Another device wiped the account after this path was remembered.
      // Preserve the local trace and recreate it in the current upload epoch.
      final file = await _rides.exportGpx(ride);
      candidate = await remote.uploadGpx(
        rideId: ride.id,
        localFilePath: file.path,
      );
      result = await remote.pushRide(ride.copyWith(gpxPath: candidate));
    }
    checkIdentity();
    final winner = result.winner;
    if (candidate != null &&
        (winner.isDeleted || winner.gpxPath != candidate)) {
      await remote.deleteGpx(candidate);
    }
    // Never delete a live winner's trace because a stale local delete lost.
    if (winner.isDeleted && winner.gpxPath != null) {
      await remote.deleteGpx(winner.gpxPath!);
    }
    await _db.transaction(() async {
      // A user edit made while the HTTP request was in flight replaced this
      // outbox ID. Its new content/status must survive the old acknowledgement.
      checkIdentity();
      if (!await _db.syncQueueDao.contains(item.id)) return;
      final current = await _rides.getRide(ride.id);
      if (current?.updatedAt != ride.updatedAt ||
          current?.deletedAt != ride.deletedAt) {
        return;
      }
      await _mergeRemoteRide(winner, authoritative: true, ownerUserId: remote.userId);
      await _rides.setSyncStatus(ride.id, SyncStatus.synced);
    });
    return result.accepted;
  }

  Future<bool> _pushRoute(SupabaseRemote remote, PendingSyncItem item,
      void Function() checkIdentity) async {
    final route = await _routes.getRoute(item.entityId);
    if (route == null || route.ownerUserId != remote.userId || item.ownerUserId != remote.userId) return false;
    final result = await remote.pushRoute(route);
    await _db.transaction(() async {
      checkIdentity();
      if (!await _db.syncQueueDao.contains(item.id)) return;
      final current = await _routes.getRoute(route.id);
      if (current?.updatedAt != route.updatedAt ||
          current?.deletedAt != route.deletedAt) {
        return;
      }
      await _mergeRemoteRoute(result.winner, authoritative: true, ownerUserId: remote.userId);
      await _db.routeDao.setSyncStatus(route.id, SyncStatus.synced);
    });
    return result.accepted;
  }

  // ---- Pull ----

  Future<int> _pull(SupabaseRemote remote, void Function() checkIdentity) async {
    var applied = 0;

    // Conflict policy (spec §28): the local copy of a ride wins whenever it is
    // newer. Rides are immutable after they end apart from name, notes and
    // bike, so the only field that can genuinely conflict is a rename — and
    // the later edit is the one the rider meant.
    final remoteRides = await remote.fetchRides();
    for (final remoteRide in remoteRides) {
      checkIdentity();
      if (await _mergeRemoteRide(remoteRide, ownerUserId: remote.userId)) applied++;
    }

    final remoteRoutes = await remote.fetchRoutes();
    for (final route in remoteRoutes) {
      checkIdentity();
      if (await _mergeRemoteRoute(route, ownerUserId: remote.userId)) applied++;
    }

    return applied;
  }

  Future<bool> _mergeRemoteRoute(
    routes.Route remote, {
    bool authoritative = false,
    String? ownerUserId,
  }) => _db.transaction(
    () => _mergeRemoteRouteInTransaction(remote, authoritative: authoritative, ownerUserId: ownerUserId),
  );

  Future<bool> _mergeRemoteRouteInTransaction(
    routes.Route remote, {
    required bool authoritative,
    String? ownerUserId,
  }) async {
    final local = await _routes.getRoute(remote.id);
    if (local != null && local.ownerUserId != ownerUserId) return false;
    if (remote.isDeleted) {
      if (local == null ||
          (local.isDeleted && local.updatedAt == remote.updatedAt)) {
        return false;
      }
      await _routes.applyRemoteDelete(
        remote.id,
        deletedAt: remote.deletedAt,
        updatedAt: remote.updatedAt,
      );
      return true;
    }
    if (!authoritative &&
        local != null &&
        (local.isDeleted ||
            (local.updatedAt != null &&
                remote.updatedAt != null &&
                local.updatedAt!.isAfter(remote.updatedAt!)))) {
      await _db.syncQueueDao.enqueue(
        SyncEntityType.route,
        local.id,
        local.isDeleted ? SyncOperation.delete : SyncOperation.upsert,
        resetExisting: false,
      );
      return false;
    }
    if (remote.points.length < 2) return false;
    if (!authoritative &&
        local != null &&
        local.updatedAt == remote.updatedAt &&
        local.name == remote.name) {
      return false;
    }
    await _routes.saveRoute(
      remote.copyWith(
        ownerUserId: ownerUserId,
        favorite: local?.favorite,
        instructions: local?.instructions,
      ),
      enqueue: false,
    );
    return true;
  }

  /// Entry point for the tests, which have no HTTP client to pull with.
  ///
  /// The merge is the only place where "who wins" is decided, and it is pure
  /// local work — it deserves a test more than the uploads do, precisely
  /// because a mistake here is silent: the rider sees a ride whose name went
  /// back to what it was on another device, or a note that will not go away.
  @visibleForTesting
  Future<bool> mergeRemoteRide(RemoteRide remote) => _mergeRemoteRide(remote,
      ownerUserId: _resolveClient()?.auth.currentUser?.id);

  /// Returns true when the local store changed.
  Future<bool> _mergeRemoteRide(
    RemoteRide remote, {
    bool authoritative = false,
    String? ownerUserId,
  }) => _db.transaction(
    () => _mergeRemoteRideInTransaction(remote, authoritative: authoritative, ownerUserId: ownerUserId),
  );

  Future<bool> _mergeRemoteRideInTransaction(
    RemoteRide remote, {
    required bool authoritative,
    String? ownerUserId,
  }) async {
    final local = await _rides.getRide(remote.id);
    if (local != null && local.ownerUserId != ownerUserId) return false;

    // A tombstone must never pass through the new-device live-row insertion
    // path. Full metadata pulls revisit it, so already deleted rows are no-ops.
    if (remote.isDeleted) {
      if (local == null ||
          (local.isDeleted && local.updatedAt == remote.updatedAt)) {
        return false;
      }
      await _rides.applyRemoteDelete(
        remote.id,
        deletedAt: remote.deletedAt,
        updatedAt: remote.updatedAt,
      );
      return true;
    }

    if (local == null) {
      // A ride that exists only in the cloud — the new-phone case.
      await _rides.insertRemoteRide(
        Ride(
          id: remote.id,
          ownerUserId: ownerUserId,
          name: remote.name,
          notes: remote.notes,
          startedAt: remote.startedAt,
          endedAt: remote.endedAt,
          stats: RideStats(
            distanceMeters: remote.distanceMeters,
            elapsed: Duration(seconds: remote.elapsedSeconds),
            moving: Duration(seconds: remote.movingSeconds),
            avgSpeedMps: remote.avgSpeedMps,
            maxSpeedMps: remote.maxSpeedMps,
            elevationGainMeters: remote.elevationGainMeters,
            elevationLossMeters: remote.elevationLossMeters,
          ),
          startPoint: remote.startPoint,
          endPoint: remote.endPoint,
          gpxPath: remote.gpxPath,
          fitPath: remote.fitPath,
          syncStatus: SyncStatus.synced,
          syncVersion: remote.syncVersion,
          updatedAt: remote.updatedAt,
          createdAt: remote.createdAt,
        ),
      );
      return true;
    }

    if (!authoritative &&
        (local.isDeleted ||
            (local.updatedAt != null &&
                local.updatedAt!.isAfter(remote.updatedAt)))) {
      // Local is newer — re-queue the push so the cloud catches up, rather
      // than overwriting the local edit with a stale copy.
      await _db.syncQueueDao.enqueue(
        SyncEntityType.ride,
        local.id,
        local.isDeleted ? SyncOperation.delete : SyncOperation.upsert,
        resetExisting: false,
      );
      return false;
    }

    // Cloud is newer. Only the fields a rider can edit are taken: the recorded
    // statistics on this device came off a GPS receiver and are not something
    // to overwrite from a summary row.
    //
    // Name and notes are taken *verbatim* — including `null`. A field that can
    // only ever be set is a field that can never be cleared, and the rider who
    // emptied their note on the other phone meant it.
    if (authoritative ||
        local.name != remote.name ||
        local.notes != remote.notes ||
        local.gpxPath != remote.gpxPath ||
        local.updatedAt != remote.updatedAt) {
      await _rides.applyRemoteMetadata(
        local.id,
        name: remote.name,
        notes: remote.notes,
        gpxPath: remote.gpxPath,
        updatedAt: remote.updatedAt,
        restoreLive: authoritative,
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
    if (!_isConfigured()) return SyncPhase.notConfigured;
    if (_resolveClient()?.auth.currentUser == null) return SyncPhase.signedOut;
    return SyncPhase.idle;
  }

  Future<void> _refreshPendingCount() async {
    final count = await _db.syncQueueDao.pendingCount();
    _emit(_report.copyWith(pendingCount: count));
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
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup')) {
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

    _observeIdentity(client);
    final generation = _identityGeneration;
    void checkIdentity() => _checkIdentity(client, userId, generation);
    final ride = await _rides.getRide(rideId);
    if (ride?.gpxPath == null || ride!.ownerUserId != userId || ride.isDeleted) return 0;
    if (await _rides.trackPointCount(rideId) > 1) return 0;

    final remote = SupabaseRemote(client, userId, checkIdentity: checkIdentity);
    final xml = await remote.downloadGpx(ride.gpxPath!);
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

    checkIdentity();
    await _db.transaction(() async {
      final current = await _rides.getRide(rideId);
      checkIdentity();
      if (current == null || current.isDeleted || current.ownerUserId != userId) return;
      await _rides.importTrackPoints(rideId, points);
    });
    return points.length;
  }

  // ---- Deleting the cloud copy ----

  /// Deletes everything this account holds in the cloud: rows and GPX objects.
  ///
  /// Deliberately *not* gated on the cloud-sync switch. That switch is about
  /// uploads, and asking for the existing copy to be gone is a separate
  /// decision — someone who just turned uploading off is exactly who wants
  /// this. It does require a session: deletion runs with the rider's own
  /// token, so RLS stays the boundary instead of a service key.
  ///
  /// The caller is responsible for turning cloud sync off afterwards.
  /// Otherwise the next sync uploads everything that was just deleted, which
  /// would make the whole action a lie.
  Future<CloudDeleteReport> deleteCloudData() async {
    if (_running) {
      return const CloudDeleteReport(message: '同步正在进行，请稍后再试');
    }

    // Cheapest and most fundamental first: with no Supabase configured there
    // is nothing to delete against, and the client is never resolved.
    if (!_isConfigured()) {
      return const CloudDeleteReport(message: '云同步未配置');
    }
    final client = _resolveClient();
    if (client == null) {
      return const CloudDeleteReport(message: '云同步不可用');
    }
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      return const CloudDeleteReport(message: '未登录，无法确认云端数据属于谁');
    }

    final accessToken = client.auth.currentSession?.accessToken;
    _running = true;
    _scheduleGeneration++;
    _wake.cancel();
    try {
      final endpoint = FunctionsConfig.wipeCloudDataUrl;
      if (_cloudWipeClient == null && endpoint == null) {
        return const CloudDeleteReport(message: '云端删除服务未配置，请更新服务配置后重试');
      }
      final wipe =
          _cloudWipeClient ??
          CloudDataWipeClient(
            endpoint: endpoint!,
            accessToken: () => accessToken,
          );
      final int files;
      try {
        files = await wipe.wipe();
      } finally {
        if (_cloudWipeClient == null) wipe.close();
      }
      // Server success means its fenced, authoritative object inventory and
      // row cleanup completed. A partial cleanup never changes local state.
      await forgetCloudCopy(ownerUserId: userId);

      return CloudDeleteReport(ok: true, files: files);
    } catch (e) {
      return CloudDeleteReport(message: _describeError(e));
    } finally {
      _running = false;
    }
  }

  /// Local bookkeeping after the cloud copy is gone.
  ///
  /// Everything local is marked "no cloud copy". [requeue] then decides what
  /// that means:
  ///
  /// * `true` (the default) — the records should be uploaded again if the
  ///   rider turns sync back on, so they go back on the queue: the queue is
  ///   the list of what *should* be in the cloud, and after a wipe that is
  ///   everything again. Enqueueing is idempotent per entity, so rides that
  ///   were already pending do not double up.
  /// * `false` — used when the account itself is gone. There is nowhere to
  ///   upload to, and a queue that can never drain would sit there showing
  ///   「待上传 N 条」 for the rest of the install's life.
  Future<void> forgetCloudCopy({bool requeue = true, String? ownerUserId}) {
    final owner = ownerUserId ?? _resolveClient()?.auth.currentUser?.id;
    return _db.transaction(() async {
        await _db.rideDao.markCloudCopyGone(ownerUserId: owner);
        await _db.routeDao.markCloudCopyGone(ownerUserId: owner);

        if (!requeue) {
          await (_db.delete(_db.syncQueueItems)..where((t) => owner == null
              ? t.ownerUserId.isNull() : t.ownerUserId.equals(owner))).go();
          return;
        }

        for (final ride in await _db.rideDao.getRides(limit: 1 << 30)) {
          if (ride.isDeleted || ride.ownerUserId != owner) continue;
          await _db.syncQueueDao.enqueue(
            SyncEntityType.ride,
            ride.id,
            SyncOperation.upsert,
          );
        }
        for (final route in await _db.routeDao.getRoutes()) {
          if (route.isDeleted || route.ownerUserId != owner) continue;
          await _db.syncQueueDao.enqueue(
            SyncEntityType.route,
            route.id,
            SyncOperation.upsert,
          );
        }
      });
  }
}

/// Resolves the current Supabase client, or null when unavailable.
typedef AuthResolver = SupabaseClient? Function();
