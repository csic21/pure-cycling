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
  });

  final int id;
  final SyncEntityType entityType;
  final String entityId;
  final SyncOperation operation;
  final int retryCount;
  final String? lastError;
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
    final now = DateTime.now().toUtc();
    final target = [
      syncQueueItems.entityType,
      syncQueueItems.entityId,
      syncQueueItems.operation,
    ];
    await into(syncQueueItems).insert(
      SyncQueueItemsCompanion.insert(
        entityType: type.id,
        entityId: entityId,
        operation: operation.id,
        createdAt: now,
      ),
      // Reconciliation discovers work; it is not a new user edit. Preserve an
      // existing entry's retry schedule and error when requested by the pull.
      onConflict: resetExisting
          ? DoUpdate(
              (old) => SyncQueueItemsCompanion(
                createdAt: Value(now),
                retryCount: const Value(0),
                nextAttemptAt: const Value(null),
                lastError: const Value(null),
              ),
              target: target,
            )
          : DoNothing(target: target),
    );
  }

  /// Items whose backoff has elapsed, oldest first.
  Future<List<PendingSyncItem>> due({int limit = 10}) async {
    final now = DateTime.now().toUtc();
    final query = select(syncQueueItems)
      ..where(
        (t) =>
            t.nextAttemptAt.isNull() |
            t.nextAttemptAt.isSmallerOrEqualValue(now),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
      ..limit(limit);
    final rows = await query.get();
    return rows.map(_toItem).toList();
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
  );
}
