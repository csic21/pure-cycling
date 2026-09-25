import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/sync/supabase_remote.dart';
import 'package:cycling_app/core/sync/sync_service.dart';
import 'package:cycling_app/core/sync/sync_status.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/routes/data/route_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_harness.dart';

/// The two fields a rider can still change after a ride: the name and the note.
///
/// `bikeId` lives on the same row but has no writer — no local bikes table, and
/// `push_ride` does not send it — so it is deliberately not exercised here.
///
/// The interesting half is not writing them, it is *clearing* them and then
/// getting the cloud and the device to agree about the empty state. A field
/// that can only be set is a field that is write-once, and the failure is
/// invisible until the rider opens the ride on their other phone.
void main() {
  late AppDatabase database;
  late RideRepository rides;
  late SyncService service;

  setUp(() {
    database = openTestDatabase();
    rides = RideRepository(database);
    service = SyncService(
      db: database,
      rides: rides,
      routes: RouteRepository(database),
      resolveClient: () => null,
    );
  });

  tearDown(() async {
    await service.dispose();
    await database.close();
  });

  group('editing a ride', () {
    test('name and notes are written, and the ride is queued for upload',
        () async {
      final ride = await seedRide(database, name: '周末环湖');

      await rides.updateDescription(
        ride.id,
        name: '环湖（逆风）',
        notes: '风大，注意补给',
      );

      final stored = await rides.getRide(ride.id);
      expect(stored!.name, '环湖（逆风）');
      expect(stored.notes, '风大，注意补给');
      expect(stored.syncStatus, SyncStatus.pendingUpload);
      expect(await database.syncQueueDao.pendingCount(), greaterThanOrEqualTo(1));
    });

    test('emptying a field really empties it', () async {
      final ride = await seedRide(database, name: '有名字');
      await rides.updateDescription(ride.id, name: '有名字', notes: '有备注');

      await rides.updateDescription(ride.id, name: null, notes: null);

      final stored = await rides.getRide(ride.id);
      expect(
        stored!.notes,
        isNull,
        reason: '清空备注必须能表达，否则这个字段只能写一次',
      );
      expect(stored.name, isNull);
    });

    test('the recorded statistics are untouched by an edit', () async {
      final ride = await seedRide(database, distanceMeters: 23820);

      await rides.updateDescription(ride.id, name: '改个名', notes: '写点东西');

      final stored = await rides.getRide(ride.id);
      expect(stored!.stats.distanceMeters, 23820);
      expect(stored.stats.moving, ride.stats.moving);
    });
  });

  group('the cloud copy of an edit', () {
    test('a ride recovered on a new phone arrives with its note', () async {
      // The whole point of syncing a note: it is the part the rider wrote.
      final applied = await service.mergeRemoteRide(
        RemoteRide(
          id: 'from-the-cloud',
          startedAt: DateTime.utc(2026, 9, 20, 6),
          updatedAt: DateTime.utc(2026, 9, 20, 8),
          name: '通勤',
          notes: '链条有点响',
          distanceMeters: 18400,
          movingSeconds: 2400,
          elapsedSeconds: 2600,
        ),
      );

      expect(applied, isTrue);
      final stored = await rides.getRide('from-the-cloud');
      expect(stored!.name, '通勤');
      expect(stored.notes, '链条有点响');
      expect(stored.syncStatus, SyncStatus.synced);
      expect(
        await database.syncQueueDao.pendingCount(),
        0,
        reason: '刚拉下来的行不该立刻回推',
      );
    });

    test('a newer cloud copy wins, including a cleared note', () async {
      final ride = await seedRide(database, name: '本地名字');
      await rides.updateDescription(ride.id, name: '本地名字', notes: '本地的备注');

      final applied = await service.mergeRemoteRide(
        RemoteRide(
          id: ride.id,
          startedAt: ride.startedAt,
          updatedAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          name: '云端的名字',
          notes: null,
          distanceMeters: 1,
        ),
      );

      expect(applied, isTrue);
      final stored = await rides.getRide(ride.id);
      expect(stored!.name, '云端的名字');
      expect(stored.notes, isNull, reason: '在另一台手机上删掉备注，这边也要删掉');
      expect(
        stored.stats.distanceMeters,
        isNot(1),
        reason: '云端是摘要行，不能覆盖本机记录的数字',
      );
    });

    test('a newer local edit wins and is re-queued', () async {
      final ride = await seedRide(database, name: '本地名字');
      await rides.updateDescription(ride.id, name: '刚改的名字', notes: null);

      final applied = await service.mergeRemoteRide(
        RemoteRide(
          id: ride.id,
          startedAt: ride.startedAt,
          // Older than the local edit above.
          updatedAt: DateTime.utc(2026, 9, 20, 8),
          name: '旧名字',
          notes: '旧的备注',
        ),
      );

      expect(applied, isFalse);
      final stored = await rides.getRide(ride.id);
      expect(stored!.name, '刚改的名字');
      expect(stored.notes, isNull);
      expect(
        await database.syncQueueDao.pendingCount(),
        greaterThanOrEqualTo(1),
        reason: '本地更新，云端的旧值要靠一次回推收敛',
      );
    });
  });
}
