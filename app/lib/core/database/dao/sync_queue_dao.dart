import 'package:drift/drift.dart';

import '../../sync/sync_status.dart';
import '../database.dart';

part 'sync_queue_dao.g.dart';

/// A queued sync operation, as read back from the outbox.
class PendingSyncItem {
  const PendingSyncItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.retryCount,
    this.lastError,
    this.ownerUserId,
  });

  final int id;
  final SyncEntityType entityType;
  final String entityId;
  final SyncOperation operation;
  final int retryCount;
  final String? lastError;
  final String? ownerUserId;
}

/// The durable upload outbox.
///
/// Every mutation that needs to reach Supabase enqueues a row here in the same
/// transaction that writes the data itself. If the process dies between the
/// two, the ride is still on disk — the worst case is a ride that never
/// uploads, never a ride that is lost.
@DriftAccessor(tables: [SyncQueueItems])
class SyncQueueDao extends DatabaseAccessor<AppDatabase>
    with _$SyncQueueDaoMixin {
  SyncQueueDao(super.db);

  /// Enqueues an operation, replacing any pending duplicate.
  ///
  /// One entry per (entity, operation): re-saving a ride five times while
  /// offline still results in a single upload.
  ///
  /// The conflict target has to be spelled out. `insertOnConflictUpdate` only
  /// detects a conflict on the *primary key*, and this table's primary key is
  /// an auto-increment id that nothing supplies — so the unique key the table
  /// is actually built on (entity, operation) never matched, and a second
  /// enqueue threw `UNIQUE constraint failed` instead of replacing the row.
  /// The same call also resets the backoff: a fresh edit is a new reason to
  /// try, and it should not inherit the failed attempt's timer.
  Future<void> enqueue(
    SyncEntityType type,
    String entityId,
    SyncOperation operation, {
    bool resetExisting = true,
  }) async {
    final owner = switch (type) {
      SyncEntityType.ride => (await attachedDatabase.rideDao.getRide(entityId))?.ownerUserId,
      SyncEntityType.route => (await attachedDatabase.routeDao.getRoute(entityId))?.ownerUserId,
      SyncEntityType.settings => attachedDatabase.resolveOwner(),
    };
    final now = DateTime.now().toUtc();
    final target = [
      syncQueueItems.entityType,
      syncQueueItems.entityId,
      syncQueueItems.operation,
    ];
    await into(syncQueueItems).insert(
      SyncQueueItemsCompanion.insert(
        ownerUserId: Value(owner),
        entityType: type.id,
        entityId: entityId,
        operation: operation.id,
        createdAt: now,
      ),
      // Reconciliation discovers work; it is not a new user edit. Preserve an
      // existing entry's retry schedule and error when requested by the pull.
      // A new edit gets a new ID. An acknowledgement for an upload already
      // in flight must not remove or back off that replacement operation.
      mode: resetExisting ? InsertMode.insertOrReplace : InsertMode.insert,
      onConflict: resetExisting ? null : DoNothing(target: target),
    );
  }

  /// Items whose backoff has elapsed, oldest first.
  Future<List<PendingSyncItem>> due({int limit = 10, String? ownerUserId}) async {
    final now = DateTime.now().toUtc();
    final query = select(syncQueueItems)
      ..where(
        (t) =>
            (ownerUserId == null ? const Constant(true) : t.ownerUserId.equals(ownerUserId)) &
            (t.nextAttemptAt.isNull() |
            t.nextAttemptAt.isSmallerOrEqualValue(now)),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
      ..limit(limit);
    final rows = await query.get();
    return rows.map(_toItem).toList();
  }

  /// Earliest durable wake, including a fresh enqueue whose deadline is null.
  /// SQLite sorts null first; one result avoids loading the
  /// entire outbox merely to arm a timer.
  Stream<DateTime?> watchNextAttempt() =>
      (select(syncQueueItems)
            ..orderBy([(t) => OrderingTerm.asc(t.nextAttemptAt)])
            ..limit(1))
          .watch()
          .map(
            (rows) => rows.isEmpty
                ? null
                : rows.single.nextAttemptAt ??
                      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          );

  Future<DateTime?> nextAttempt({String? ownerUserId}) async {
    final row =
        await (select(syncQueueItems)
              ..where((t) => ownerUserId == null ? const Constant(true) : t.ownerUserId.equals(ownerUserId))
              ..orderBy([(t) => OrderingTerm.asc(t.nextAttemptAt)])
              ..limit(1))
            .getSingleOrNull();
    return row == null
        ? null
        : row.nextAttemptAt ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  Future<List<PendingSyncItem>> all() async {
    final query = select(syncQueueItems)
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    final rows = await query.get();
    return rows.map(_toItem).toList();
  }

  Future<int> pendingCount() async {
    final count = syncQueueItems.id.count();
    final query = selectOnly(syncQueueItems)..addColumns([count]);
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Stream<int> watchPendingCount() {
    final count = syncQueueItems.id.count();
    final query = selectOnly(syncQueueItems)..addColumns([count]);
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  Future<bool> contains(int id) async =>
      await (select(
        syncQueueItems,
      )..where((t) => t.id.equals(id))).getSingleOrNull() !=
      null;

  Future<void> remove(int id) async {
    await (delete(syncQueueItems)..where((t) => t.id.equals(id))).go();
  }

  /// Records a failure and schedules a retry with exponential backoff.
  ///
  /// Capped at one hour: a ride recorded in a tunnel should reach the cloud
  /// soon after the rider surfaces, not the next morning.
  Future<void> markFailed(int id, String error) async {
    final query = select(syncQueueItems)..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    if (row == null) return;

    final retry = row.retryCount + 1;
    final backoffSeconds = _backoffSeconds(retry);
    await (update(syncQueueItems)..where((t) => t.id.equals(id))).write(
      SyncQueueItemsCompanion(
        retryCount: Value(retry),
        lastError: Value(error.length > 500 ? error.substring(0, 500) : error),
        nextAttemptAt: Value(
          DateTime.now().toUtc().add(Duration(seconds: backoffSeconds)),
        ),
      ),
    );
  }

  /// Clears the backoff so the next drain retries immediately — used when the
  /// user taps "sync now" or the app regains connectivity.
  Future<void> resetBackoff() async {
    await update(syncQueueItems).write(
      const SyncQueueItemsCompanion(
        nextAttemptAt: Value(null),
        retryCount: Value(0),
      ),
    );
  }

  Future<void> clear() async {
    await delete(syncQueueItems).go();
  }

  static int _backoffSeconds(int retry) {
    const schedule = [15, 60, 300, 900, 1800, 3600];
    final idx = (retry - 1).clamp(0, schedule.length - 1);
    return schedule[idx];
  }

  PendingSyncItem _toItem(SyncQueueRow row) => PendingSyncItem(
    id: row.id,
    entityType: SyncEntityType.fromId(row.entityType),
    entityId: row.entityId,
    operation: SyncOperation.fromId(row.operation),
    retryCount: row.retryCount,
    lastError: row.lastError,
    ownerUserId: row.ownerUserId,
  );
}
