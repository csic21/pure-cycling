import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/sync/sync_status.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The outbox is where durability lives: a ride that is not queued never
/// uploads. These assertions are about the queue staying *one row per thing*,
/// because a queue that can throw on a second enqueue turns "sync failed" into
/// "sync failed, and the retry can never even be scheduled".
void main() {
  late AppDatabase database;

  setUp(() => database = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => database.close());

  Future<void> enqueueRide(String id) => database.syncQueueDao.enqueue(
        SyncEntityType.ride,
        id,
        SyncOperation.upsert,
      );

  test('enqueuing the same ride twice keeps one row', () async {
    await enqueueRide('ride-1');
    // The second call must replace, not throw. This is reachable in the app:
    // the rider edits a ride while an earlier edit is still waiting to upload.
    await enqueueRide('ride-1');

    final items = await database.syncQueueDao.all();
    expect(items, hasLength(1));
    expect(items.single.entityId, 'ride-1');
  });

  test('a fresh enqueue clears the failed attempt and its backoff', () async {
    await enqueueRide('ride-1');
    final first = (await database.syncQueueDao.all()).single;
    await database.syncQueueDao.markFailed(first.id, 'network down');

    final failed = (await database.syncQueueDao.all()).single;
    expect(failed.retryCount, 1);
    expect(failed.lastError, 'network down');
    expect(
      await database.syncQueueDao.due(),
      isEmpty,
      reason: '失败后有退避，不该立刻重试',
    );

    // The rider edits the ride again. That is a new reason to try, so the
    // failed attempt must not hold the upload back.
    await enqueueRide('ride-1');

    final retried = (await database.syncQueueDao.all()).single;
    expect(retried.retryCount, 0);
    expect(retried.lastError, isNull);
    expect(
      await database.syncQueueDao.due(),
      hasLength(1),
      reason: '新的编辑是一次新的尝试，不继承上一次的退避',
    );
  });

  test('different entities and operations are separate rows', () async {
    await enqueueRide('ride-1');
    await enqueueRide('ride-2');
    await database.syncQueueDao.enqueue(
      SyncEntityType.ride,
      'ride-1',
      SyncOperation.delete,
    );

    final items = await database.syncQueueDao.all();
    expect(items, hasLength(3));
  });
}
