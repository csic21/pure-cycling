import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'dao/active_ride_dao.dart';
import 'dao/ride_dao.dart';
import 'dao/route_dao.dart';
import 'dao/sensor_dao.dart';
import 'dao/settings_dao.dart';
import 'dao/sync_queue_dao.dart';
import 'tables.dart';

export 'tables.dart';

part 'database.g.dart';

/// The local database — the source of truth for everything the app records.
///
/// The ride pipeline writes here first and always (spec §15). Nothing on the
/// recording path awaits the network, and nothing that fails to sync is ever
/// rolled back locally.
@DriftDatabase(
  tables: [
    LocalRides,
    TrackPoints,
    SavedRoutes,
    SyncQueueItems,
    AppSettingsEntries,
    PairedSensors,
    ActiveRideCheckpoints,
  ],
  daos: [
    RideDao,
    RouteDao,
    SettingsDao,
    SyncQueueDao,
    SensorDao,
    ActiveRideDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Test constructor: pass an in-memory executor.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        beforeOpen: (details) async {
          // Track points cascade from their ride; without this pragma the
          // declared FK is inert and deleting a ride would orphan its trace.
          await customStatement('PRAGMA foreign_keys = ON');

          // WAL keeps a write from blocking the 1 Hz insert stream, and
          // survives a mid-write process death — which, on a phone in a
          // jersey pocket, is a real scenario rather than a hypothetical.
          await customStatement('PRAGMA journal_mode = WAL');
          // NORMAL is the right trade with WAL: an OS crash can lose the last
          // transaction, an app crash cannot. Full sync would cost real
          // battery for a durability level this app does not need.
          await customStatement('PRAGMA synchronous = NORMAL');
        },
      );

  /// Deletes everything. Test-support only.
  Future<void> wipe() async {
    await transaction(() async {
      for (final table in allTables) {
        await delete(table).go();
      }
    });
  }
}

QueryExecutor _openConnection() {
  // Native only — Android, iOS and macOS.
  //
  // Web is deliberately not a target. The product is a phone strapped to
  // handlebars, and drift on the web needs `sqlite3.wasm` plus a compiled
  // worker that `drift_dev make-web-worker` produces — a command that is
  // broken in the only drift_dev version this Flutter SDK can resolve
  // (2.34.0, pinned by the SDK's `meta 1.17.0`). Shipping a target that
  // cannot be built is worse than not shipping it.
  return driftDatabase(name: 'pure_cycling');
}
