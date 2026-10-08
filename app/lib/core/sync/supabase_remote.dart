import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/ride/domain/ride.dart';
import '../../features/routes/domain/route.dart';
import '../../features/settings/domain/app_settings.dart';
import '../utils/geo.dart';
import 'supabase_config.dart';

/// What the cloud holds for one ride.
///
/// Deliberately not a `Ride`: the cloud copy carries no track points, and
/// pretending otherwise is how a merge ends up discarding a local trace.
class RemoteRide {
  const RemoteRide({
    required this.id,
    required this.startedAt,
    required this.updatedAt,
    this.endedAt,
    this.name,
    this.notes,
    this.distanceMeters = 0,
    this.elapsedSeconds = 0,
    this.movingSeconds = 0,
    this.avgSpeedMps = 0,
    this.maxSpeedMps = 0,
    this.elevationGainMeters = 0,
    this.elevationLossMeters = 0,
    this.startPoint,
    this.endPoint,
    this.gpxPath,
    this.fitPath,
    this.createdAt,
    this.deletedAt,
    this.syncVersion = 1,
  });

  final String id;
  final DateTime startedAt;
  final DateTime updatedAt;
  final DateTime? endedAt;
  final String? name;

  /// The rider's own note. Carried so a ride recovered on a new phone arrives
  /// with everything they wrote, not just its statistics.
  final String? notes;

  final double distanceMeters;
  final int elapsedSeconds;
  final int movingSeconds;
  final double avgSpeedMps;
  final double maxSpeedMps;
  final double elevationGainMeters;
  final double elevationLossMeters;
  final GeoPoint? startPoint;
  final GeoPoint? endPoint;
  final String? gpxPath;
  final String? fitPath;
  final DateTime? createdAt;
  final DateTime? deletedAt;
  final int syncVersion;

  bool get isDeleted => deletedAt != null;

  static RemoteRide fromRow(Map<String, dynamic> row) => RemoteRide(
    id: row['id'] as String,
    startedAt: DateTime.parse(row['started_at'] as String).toUtc(),
    updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
    endedAt: row['ended_at'] == null
        ? null
        : DateTime.parse(row['ended_at'] as String).toUtc(),
    name: row['name'] as String?,
    notes: row['notes'] as String?,
    distanceMeters: (row['distance_meters'] as num?)?.toDouble() ?? 0,
    elapsedSeconds: (row['elapsed_seconds'] as num?)?.toInt() ?? 0,
    movingSeconds: (row['moving_seconds'] as num?)?.toInt() ?? 0,
    avgSpeedMps: (row['avg_speed_mps'] as num?)?.toDouble() ?? 0,
    maxSpeedMps: (row['max_speed_mps'] as num?)?.toDouble() ?? 0,
    elevationGainMeters:
        (row['elevation_gain_meters'] as num?)?.toDouble() ?? 0,
    elevationLossMeters:
        (row['elevation_loss_meters'] as num?)?.toDouble() ?? 0,
    startPoint: _point(row['start_lat'], row['start_lng']),
    endPoint: _point(row['end_lat'], row['end_lng']),
    gpxPath: row['gpx_path'] as String?,
    fitPath: row['fit_path'] as String?,
    createdAt: row['created_at'] == null
        ? null
        : DateTime.parse(row['created_at'] as String).toUtc(),
    deletedAt: row['deleted_at'] == null
        ? null
        : DateTime.parse(row['deleted_at'] as String).toUtc(),
    syncVersion: (row['sync_version'] as num?)?.toInt() ?? 1,
  );

  static GeoPoint? _point(dynamic lat, dynamic lng) => lat is num && lng is num
      ? GeoPoint(lat.toDouble(), lng.toDouble())
      : null;
}

/// Cloud access: Postgres over PostgREST, and file storage.
///
/// Writes go through `push_ride` / `push_route` RPCs rather than direct table
/// inserts. The reason is the PostGIS `route_geometry` column: sending WKT or
/// GeoJSON through PostgREST's geometry casting is version-dependent and fails
/// opaquely when it fails. The RPC takes the line as a GeoJSON object and
/// calls `ST_GeomFromGeoJSON` explicitly, so the behaviour is the same on any
/// project. The functions are `security invoker`, so row level security still
/// applies — the RPC is a convenience, not a bypass.
class SupabaseRemote {
  SupabaseRemote(this._client, this.userId);

  final SupabaseClient _client;
  final String userId;

  /// Uploads a ride's GPX to Storage.
  ///
  /// `upsert: true` because a retried upload after a partial failure must
  /// overwrite rather than fail on the existing object.
  Future<String> uploadGpx({
    required String rideId,
    required String localFilePath,
  }) async {
    final file = File(localFilePath);
    if (!await file.exists()) {
      throw StateError('GPX 文件不存在：$localFilePath');
    }

    final objectPath = SupabaseConfig.gpxPath(userId, rideId);
    await _client.storage
        .from(SupabaseConfig.gpxBucket)
        .upload(
          objectPath,
          file,
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'application/gpx+xml',
            // Location traces are the most sensitive data the app holds; the
            // bucket is private and objects stay private (spec §44).
            cacheControl: 'private, max-age=0',
          ),
        );
    return objectPath;
  }

  /// Downloads a ride's GPX, or null when no object exists.
  Future<String?> downloadGpx(String objectPath) async {
    try {
      final bytes = await _client.storage
          .from(SupabaseConfig.gpxBucket)
          .download(objectPath);
      return String.fromCharCodes(bytes);
    } on StorageException {
      // A missing object is a normal state for a ride uploaded before the
      // storage write succeeded, or deleted out from under us.
      return null;
    }
  }

  Future<void> deleteGpx(String objectPath) async {
    // Storage returns an empty result for an already absent object. Genuine
    // failures must keep the outbox entry so the private trace is retried.
    await _client.storage.from(SupabaseConfig.gpxBucket).remove([objectPath]);
  }

  /// Every GPX object path this account references.
  ///
  /// Read *before* the rows are deleted: once they are gone there is no index
  /// of what to remove from the bucket, and a location trace left behind in
  /// Storage after a "delete my cloud data" is precisely the failure that
  /// action must not have.
  Future<List<String>> listGpxPaths() async {
    final paths = <String>[];
    const pageSize = 500;
    for (var offset = 0; ; offset += pageSize) {
      final rows = await _client
          .from('rides')
          .select('gpx_path')
          .eq('user_id', userId)
          .not('gpx_path', 'is', null)
          .order('id', ascending: true)
          .range(offset, offset + pageSize - 1);
      paths.addAll([
        for (final row in rows)
          if (row['gpx_path'] is String) row['gpx_path'] as String,
      ]);
      if (rows.length < pageSize) return paths;
    }
  }

  /// Removes objects in chunks — the Storage API takes a list per call.
  ///
  /// A missing object is not a failure: the goal state is "absent".
  Future<int> deleteGpxObjects(List<String> paths) async {
    var removed = 0;
    const chunk = 100;
    for (var i = 0; i < paths.length; i += chunk) {
      final end = i + chunk < paths.length ? i + chunk : paths.length;
      final slice = paths.sublist(i, end);
      final deleted = await _client.storage
          .from(SupabaseConfig.gpxBucket)
          .remove(slice);
      removed += deleted.length;
    }
    return removed;
  }

  /// Hard-deletes every ride row, returning how many were removed.
  ///
  /// Hard, not a tombstone: the tombstone exists so *other devices* converge,
  /// and after a wipe the local copy is the only copy left. `.select()` after
  /// the delete is what makes PostgREST report the rows it removed.
  Future<int> deleteAllRides() async {
    final deleted = await _client
        .from('rides')
        .delete()
        .eq('user_id', userId)
        .select('id');
    return deleted.length;
  }

  Future<int> deleteAllRoutes() async {
    final deleted = await _client
        .from('routes')
        .delete()
        .eq('user_id', userId)
        .select('id');
    return deleted.length;
  }

  Future<void> deleteSettings() async {
    await _client.from('user_settings').delete().eq('user_id', userId);
  }

  /// Upserts a ride row, including its PostGIS geometry.
  Future<void> pushRide(Ride ride) async {
    final payload = <String, dynamic>{
      'id': ride.id,
      'name': ride.name,
      'started_at': ride.startedAt.toUtc().toIso8601String(),
      'ended_at': ride.endedAt?.toUtc().toIso8601String(),
      'elapsed_seconds': ride.stats.elapsed.inSeconds,
      'moving_seconds': ride.stats.moving.inSeconds,
      'distance_meters': ride.stats.distanceMeters,
      'avg_speed_mps': ride.stats.avgSpeedMps,
      'max_speed_mps': ride.stats.maxSpeedMps,
      'elevation_gain_meters': ride.stats.elevationGainMeters,
      'elevation_loss_meters': ride.stats.elevationLossMeters,
      'start_lat': ride.startPoint?.lat,
      'start_lng': ride.startPoint?.lng,
      'end_lat': ride.endPoint?.lat,
      'end_lng': ride.endPoint?.lng,
      // Local exports share the model field, but a filesystem path must never
      // replace the Storage object reference in the cloud.
      'gpx_path': ride.gpxPath == SupabaseConfig.gpxPath(userId, ride.id)
          ? ride.gpxPath
          : null,
      'fit_path': ride.fitPath,
      'sync_version': ride.syncVersion,
      'deleted_at': ride.deletedAt?.toUtc().toIso8601String(),
      'notes': ride.notes,
      'updated_at': (ride.updatedAt ?? DateTime.now().toUtc())
          .toUtc()
          .toIso8601String(),
      if (ride.routeGeometryWkt != null)
        'route_geometry': _wktToGeoJson(ride.routeGeometryWkt!),
    };

    await _client.rpc<dynamic>('push_ride', params: {'p_ride': payload});
  }

  Future<void> pushRoute(Route route) async {
    final payload = <String, dynamic>{
      'id': route.id,
      'name': route.name,
      'distance_meters': route.distanceMeters,
      'estimated_seconds': route.estimatedDuration.inSeconds,
      'elevation_gain_meters': route.elevationGainMeters,
      'provider': route.provider,
      'provider_route_id': route.providerRouteId,
      'deleted_at': route.deletedAt?.toUtc().toIso8601String(),
      'updated_at': (route.updatedAt ?? DateTime.now().toUtc())
          .toUtc()
          .toIso8601String(),
      if (route.points.length >= 2)
        'route_geometry': {
          'type': 'LineString',
          'coordinates': route.points
              .map((p) => [p.lng, p.lat])
              .toList(growable: false),
        },
    };

    await _client.rpc<dynamic>('push_route', params: {'p_route': payload});
  }

  /// All ride summaries, including tombstones, in deterministic pages.
  ///
  /// updated_at is an offline client's edit time, not a server arrival time.
  /// It cannot safely serve as an incremental cursor: an old offline edit can
  /// arrive after a newer pull. Read every summary until a server change feed
  /// exists; full-resolution GPX traces are still downloaded only on demand.
  Future<List<RemoteRide>> fetchRides() async {
    final rows = await _fetchAllRows(
      'rides',
      'id, started_at, ended_at, created_at, updated_at, name, notes, '
          'distance_meters, elapsed_seconds, moving_seconds, avg_speed_mps, '
          'max_speed_mps, elevation_gain_meters, elevation_loss_meters, '
          'start_lat, start_lng, end_lat, end_lng, '
          'gpx_path, fit_path, deleted_at, sync_version',
    );

    return rows.map(RemoteRide.fromRow).toList(growable: false);
  }

  Future<List<Route>> fetchRoutes() async {
    final rows = await _fetchAllRows(
      'routes',
      'id, name, distance_meters, estimated_seconds, '
          'elevation_gain_meters, provider, provider_route_id, '
          'route_geometry, deleted_at, created_at, updated_at',
    );

    return rows
        .map((row) {
          final geometry = row['route_geometry'];
          final points = <GeoPoint>[];
          if (geometry is Map<String, dynamic>) {
            points.addAll(_geoJsonToPoints(geometry));
          }

          return Route(
            id: row['id'] as String,
            name: row['name'] as String? ?? '路线',
            points: points,
            distanceMeters: (row['distance_meters'] as num?)?.toDouble() ?? 0,
            estimatedDuration: Duration(
              seconds: (row['estimated_seconds'] as num?)?.toInt() ?? 0,
            ),
            elevationGainMeters: (row['elevation_gain_meters'] as num?)
                ?.toDouble(),
            provider: row['provider'] as String? ?? 'amap',
            providerRouteId: row['provider_route_id'] as String?,
            createdAt: row['created_at'] == null
                ? null
                : DateTime.parse(row['created_at'] as String).toUtc(),
            updatedAt: row['updated_at'] == null
                ? null
                : DateTime.parse(row['updated_at'] as String).toUtc(),
            deletedAt: row['deleted_at'] == null
                ? null
                : DateTime.parse(row['deleted_at'] as String).toUtc(),
          );
        })
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _fetchAllRows(
    String table,
    String columns,
  ) async {
    final result = <Map<String, dynamic>>[];
    const pageSize = 500;
    for (var offset = 0; ; offset += pageSize) {
      final rows = await _client
          .from(table)
          .select(columns)
          .eq('user_id', userId)
          .order('id', ascending: true)
          .range(offset, offset + pageSize - 1);
      result.addAll(rows);
      if (rows.length < pageSize) return result;
    }
  }

  Future<void> pushSettings(AppSettings settings) async {
    await _client.from('user_settings').upsert({
      'user_id': userId,
      'units': settings.units.id,
      'auto_pause': settings.autoPause,
      'oled_mode': settings.oledMode,
      'pixel_shift': settings.pixelShift,
      'dashboard_config': settings.dashboard.toJson(),
      'navigation_config': settings.navigation.toJson(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Remote settings, or null when the account has none yet.
  Future<Map<String, dynamic>?> fetchSettings() async {
    final row = await _client
        .from('user_settings')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return row;
  }

  static List<GeoPoint> _geoJsonToPoints(Map<String, dynamic> geometry) {
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) return const [];
    final out = <GeoPoint>[];
    for (final pair in coordinates) {
      if (pair is List && pair.length >= 2) {
        final lng = (pair[0] as num).toDouble();
        final lat = (pair[1] as num).toDouble();
        out.add(GeoPoint(lat, lng));
      }
    }
    return out;
  }

  /// Converts the stored WKT `LINESTRING(lng lat, ...)` back into GeoJSON for
  /// the RPC.
  ///
  /// The two formats are one conversion apart and the WKT is already on disk
  /// from ride end, so this is cheaper than keeping a second copy of a
  /// 10,000-point line in memory just for upload.
  static Map<String, dynamic> _wktToGeoJson(String wkt) {
    final coordinates = <List<double>>[];

    final start = wkt.indexOf('(');
    final end = wkt.lastIndexOf(')');
    if (start < 0 || end <= start) {
      return {'type': 'LineString', 'coordinates': coordinates};
    }

    for (final pair in wkt.substring(start + 1, end).split(',')) {
      final parts = pair.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final lng = double.tryParse(parts[0]);
      final lat = double.tryParse(parts[1]);
      if (lng == null || lat == null) continue;
      coordinates.add([lng, lat]);
    }

    return {'type': 'LineString', 'coordinates': coordinates};
  }
}
