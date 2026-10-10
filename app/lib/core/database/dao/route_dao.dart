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

  /// A projection rather than decoding full routes and throwing their traces
  /// away. Large imported GPX files stay off the list's database/UI path.
  Stream<List<RouteSummary>> watchRouteSummaries() {
    final query = selectOnly(savedRoutes)
      ..addColumns([
        savedRoutes.id,
        savedRoutes.name,
        savedRoutes.distanceMeters,
        savedRoutes.estimatedSeconds,
        savedRoutes.elevationGainMeters,
        savedRoutes.favorite,
      ])
      ..where(savedRoutes.deletedAt.isNull())
      ..orderBy([
        OrderingTerm.desc(savedRoutes.favorite),
        OrderingTerm.desc(savedRoutes.updatedAt),
        OrderingTerm.asc(savedRoutes.id),
      ]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          RouteSummary(
            id: row.read(savedRoutes.id)!,
            name: row.read(savedRoutes.name)!,
            distanceMeters: row.read(savedRoutes.distanceMeters)!,
            estimatedDuration: Duration(
              seconds: row.read(savedRoutes.estimatedSeconds)!,
            ),
            elevationGainMeters: row.read(savedRoutes.elevationGainMeters),
            favorite: row.read(savedRoutes.favorite)!,
          ),
      ],
    );
  }

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

  Future<void> upsertRoute(Route route) async {
    final existing = await getRoute(route.id);
    final owner = existing == null
        ? (route.ownerUserId ?? attachedDatabase.resolveOwner())
        : existing.ownerUserId;
    await into(savedRoutes).insertOnConflictUpdate(
      routeToCompanion(route).copyWith(ownerUserId: Value(owner)),
    );
  }

  Future<DateTime> nextEditTime(String id) async {
    final previous = (await getRoute(id))?.updatedAt;
    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    );
    return previous != null && !now.isAfter(previous)
        ? previous.add(const Duration(seconds: 1))
        : now;
  }

  Future<void> renameRoute(String id, String name) async {
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(
        name: Value(name),
        updatedAt: Value(await nextEditTime(id)),
      ),
    );
  }

  Future<void> setFavorite(String id, bool favorite) async {
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(favorite: Value(favorite)),
    );
  }

  Future<void> setSyncStatus(String id, SyncStatus status) async {
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(syncStatus: Value(status.id)),
    );
  }

  /// Records that the cloud no longer holds a copy of anything. See
  /// `RideDao.markCloudCopyGone` — the two tables move together.
  Future<void> markCloudCopyGone({String? ownerUserId}) async {
    await (update(savedRoutes)..where((t) => ownerUserId == null
        ? t.ownerUserId.isNull() : t.ownerUserId.equals(ownerUserId)))
        .write(SavedRoutesCompanion(syncStatus: Value(SyncStatus.localOnly.id)));
  }

  /// Tombstones the route. The geometry is kept: a delete still has to reach
  /// the cloud, and re-importing a GPX should not resurrect a route the user
  /// removed on another device.
  Future<void> softDeleteRoute(
    String id, {
    DateTime? deletedAt,
    DateTime? updatedAt,
  }) async {
    final now = updatedAt ?? await nextEditTime(id);
    await (update(savedRoutes)..where((t) => t.id.equals(id))).write(
      SavedRoutesCompanion(
        deletedAt: Value(deletedAt ?? now),
        updatedAt: Value(updatedAt ?? now),
        syncStatus: Value(SyncStatus.pendingUpload.id),
      ),
    );
  }

  Future<List<Route>> routesAwaitingSync({int limit = 20}) async {
    final query = select(savedRoutes)
      ..where(
        (t) => t.syncStatus.isIn([
          SyncStatus.pendingUpload.id,
          SyncStatus.syncFailed.id,
        ]),
      )
      ..limit(limit);
    final rows = await query.get();
    return rows.map((r) => r.toDomain()).toList();
  }
}
