import 'package:drift/drift.dart';

import '../../../features/routes/domain/route.dart';
import '../../sync/sync_status.dart';
import '../database.dart';
import '../mappers.dart';

part 'route_dao.g.dart';

/// Reads and writes saved routes.
@DriftAccessor(tables: [SavedRoutes])
class RouteDao extends DatabaseAccessor<AppDatabase> with _$RouteDaoMixin {
  RouteDao(super.db);

  Stream<List<Route>> watchRoutes() {
    final query = select(savedRoutes)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.favorite),
        (t) => OrderingTerm.desc(t.updatedAt),
      ]);
    return query.watch().map((rows) => rows.map((r) => r.toDomain()).toList());
  }

  Future<List<Route>> getRoutes() {
    final query = select(savedRoutes)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    return query.get().then((rows) => rows.map((r) => r.toDomain()).toList());
  }

  Future<Route?> getRoute(String id) async {
    final query = select(savedRoutes)..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row?.toDomain();
  }

  Stream<Route?> watchRoute(String id) {
    final query = select(savedRoutes)..where((t) => t.id.equals(id));
    return query.watchSingleOrNull().map((row) => row?.toDomain());
  }

  Future<void> upsertRoute(Route route) =>
      into(savedRoutes).insertOnConflictUpdate(routeToCompanion(route));

  Future<void> renameRoute(String id, String name) async {
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(
        name: Value(name),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> setFavorite(String id, bool favorite) async {
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(
        favorite: Value(favorite),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<void> setSyncStatus(String id, SyncStatus status) async {
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(syncStatus: Value(status.id)),
    );
  }

  /// Tombstones the route. The geometry is kept: a delete still has to reach
  /// the cloud, and re-importing a GPX should not resurrect a route the user
  /// removed on another device.
  Future<void> softDeleteRoute(String id) async {
    final now = DateTime.now().toUtc();
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        syncStatus: Value(SyncStatus.pendingUpload.id),
      ),
    );
  }

  Future<List<Route>> routesAwaitingSync({int limit = 20}) async {
    final query = select(savedRoutes)
      ..where((t) => t.syncStatus.isIn([
            SyncStatus.pendingUpload.id,
            SyncStatus.syncFailed.id,
          ]))
      ..limit(limit);
    final rows = await query.get();
    return rows.map((r) => r.toDomain()).toList();
  }
}
