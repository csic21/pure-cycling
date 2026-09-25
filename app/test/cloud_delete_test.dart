import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/sync/sync_service.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/routes/data/route_repository.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deleting the cloud copy: the guards, and the local bookkeeping that makes
/// the promise hold.
///
/// The network half cannot run under `flutter test` (no Supabase client), so
/// the request path itself is verified against the real stack by
/// `scripts/local-stack.sh`. What is tested here is everything that would
/// silently make the deletion a lie: refusing when there is nobody to delete
/// for, clearing the Storage paths, and re-queueing what now exists only
/// locally.
void main() {
  late AppDatabase database;
  late bool clientRequested;
  late SyncService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    clientRequested = false;
    service = SyncService(
      db: database,
      rides: RideRepository(database),
      routes: RouteRepository(database),
      resolveClient: () {
        clientRequested = true;
        return null;
      },
    );
  });

  tearDown(() async {
    await service.dispose();
    await database.close();
  });

  test('without a configured account it refuses instead of pretending',
      () async {
    // The switch is off, and that must not matter: turning uploads off is not
    // the same as not wanting the existing copy gone.
    service.applySettings(const AppSettings());

    final report = await service.deleteCloudData();

    expect(report.ok, isFalse);
    expect(report.message, contains('未配置'));
    expect(clientRequested, isFalse);
  });

  test('local bookkeeping: status, GPX path, and the re-upload queue', () async {
    final ride = Ride(
      id: 'ride-1',
      startedAt: DateTime.utc(2026, 9, 25, 6),
      gpxPath: 'rides/u/ride-1/original.gpx',
      syncStatus: SyncStatus.synced,
    );
    await database.rideDao.upsertRide(ride);
    await database.routeDao.upsertRoute(
      Route(
        id: 'route-1',
        name: '环湖',
        points: const [GeoPoint(31.2, 121.4), GeoPoint(31.3, 121.5)],
        syncStatus: SyncStatus.synced,
      ),
    );
    // A locally deleted ride has a tombstone but nothing to back up.
    final deleted = Ride(
      id: 'ride-2',
      startedAt: DateTime.utc(2026, 9, 24, 6),
      deletedAt: DateTime.utc(2026, 9, 24, 7),
      syncStatus: SyncStatus.synced,
    );
    await database.rideDao.upsertRide(deleted);

    await service.forgetCloudCopy();

    final storedRide = await database.rideDao.getRide('ride-1');
    expect(storedRide!.syncStatus, SyncStatus.localOnly);
    expect(storedRide.gpxPath, isNull,
        reason: '这个路径指向的 Storage 对象已经被删了，留着就是指向 404');

    final storedRoute = await database.routeDao.getRoute('route-1');
    expect(storedRoute!.syncStatus, SyncStatus.localOnly);

    final queued = await database.syncQueueDao.all();
    expect(queued, hasLength(2), reason: '一骑行一路线，待重新备份');
    expect(
      queued.map((item) => item.entityId).toSet(),
      {'ride-1', 'route-1'},
      reason: '墓碑不排队：它本来就不该出现在云端',
    );
  });
}
