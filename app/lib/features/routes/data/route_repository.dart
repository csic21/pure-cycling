import '../../../core/database/dao/route_dao.dart';
import '../../../core/database/database.dart';
import '../../../core/gpx/gpx_codec.dart';
import '../../../core/sync/sync_status.dart';
import '../../../core/utils/ids.dart';
import '../domain/route.dart';

/// Reads, writes and imports routes.
class RouteRepository {
  RouteRepository(this._db);

  final AppDatabase _db;

  RouteDao get _dao => _db.routeDao;

  Stream<List<Route>> watchRoutes() => _dao.watchRoutes();

  Future<List<Route>> getRoutes() => _dao.getRoutes();

  Future<Route?> getRoute(String id) => _dao.getRoute(id);

  Stream<Route?> watchRoute(String id) => _dao.watchRoute(id);

  /// Saves a route and, unless [enqueue] is false, queues it for upload.
  ///
  /// [enqueue] is false when the route arrived *from* the cloud: re-uploading
  /// a record that was just downloaded would make every sync push back what it
  /// pulled, and on a slow connection that is a loop the user pays for.
  Future<void> saveRoute(Route route, {bool enqueue = true}) async {
    await _dao.upsertRoute(
      route.copyWith(updatedAt: DateTime.now().toUtc()),
    );

    if (enqueue) {
      await _db.syncQueueDao.enqueue(
        SyncEntityType.route,
        route.id,
        SyncOperation.upsert,
      );
      await _dao.setSyncStatus(route.id, SyncStatus.pendingUpload);
    }
  }

  Future<void> renameRoute(String id, String name) async {
    await _dao.renameRoute(id, name);
    await _db.syncQueueDao.enqueue(
      SyncEntityType.route,
      id,
      SyncOperation.upsert,
    );
  }

  Future<void> setFavorite(String id, bool favorite) async {
    // Favourites are a local preference, not shared state — toggling one does
    // not enqueue a sync. Uploading it would make a personal organising
    // decision visible to every device the rider owns, for no benefit.
    await _dao.setFavorite(id, favorite);
  }

  Future<void> deleteRoute(String id) async {
    await _dao.softDeleteRoute(id);
    await _db.syncQueueDao.enqueue(
      SyncEntityType.route,
      id,
      SyncOperation.delete,
    );
  }

  /// Applies a tombstone that arrived from the cloud.
  Future<void> applyRemoteDelete(String id) async {
    await _dao.softDeleteRoute(id);
    await _dao.setSyncStatus(id, SyncStatus.synced);
  }

  /// Imports a GPX file as a saved route.
  ///
  /// Throws [GpxImportException] when the file holds no usable geometry, so
  /// the import screen can explain *why* rather than silently doing nothing.
  Future<Route> importGpx(
    String xml, {
    String? name,
  }) async {
    ParsedGpx parsed;
    try {
      parsed = GpxCodec.decode(xml);
    } catch (e) {
      throw GpxImportException('无法解析 GPX 文件：${_brief(e)}');
    }

    if (parsed.points.length < 2) {
      throw const GpxImportException(
        'GPX 文件里没有足够的轨迹点（至少需要 2 个）',
      );
    }

    final route = GpxCodec.toRoute(
      parsed,
      id: generateId(),
      name: name ?? parsed.name,
    );

    await saveRoute(route);
    return route;
  }
}

/// Raised when a GPX file cannot be turned into a route.
class GpxImportException implements Exception {
  const GpxImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _brief(Object error) {
  final text = error.toString();
  return text.length > 100 ? '${text.substring(0, 100)}…' : text;
}
