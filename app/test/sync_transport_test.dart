import 'dart:convert';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/sync/supabase_remote.dart';
import 'package:cycling_app/core/sync/sync_service.dart';
import 'package:cycling_app/core/sync/sync_status.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/routes/data/route_repository.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Exercise the real SDK request projections and the full push/pull cycle.
// Constructing RemoteRide directly would hide a missing SELECT column.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const userId = '00000000-0000-4000-8000-000000000001';
  const rideId = '00000000-0000-4000-8000-000000000002';
  const objectPath = 'rides/$userId/$rideId/original.gpx';
  final recordedAt = DateTime.utc(2026, 1, 1, 8);

  late AppDatabase db;
  late RideRepository rides;
  late SupabaseClient client;
  late SupabaseRemote remote;
  late SyncService service;
  late Map<String, Map<String, dynamic>> cloudRows;
  late List<Map<String, dynamic>> cloudRoutes;
  late List<http.Request> requests;
  late bool failStorage;
  late bool failPush;

  Map<String, dynamic> cloudRide() => {
    'id': rideId,
    'user_id': userId,
    'name': '环湖',
    'notes': '逆风，注意补给',
    'started_at': recordedAt.toIso8601String(),
    'ended_at': recordedAt.add(const Duration(hours: 1)).toIso8601String(),
    'created_at': recordedAt.toIso8601String(),
    'updated_at': recordedAt.toIso8601String(),
    'distance_meters': 18000.0,
    'elapsed_seconds': 3600,
    'moving_seconds': 3000,
    'avg_speed_mps': 6.0,
    'max_speed_mps': 12.5,
    'elevation_gain_meters': 321.0,
    'elevation_loss_meters': 300.0,
    'start_lat': 31.2,
    'start_lng': 121.4,
    'end_lat': 31.3,
    'end_lng': 121.5,
    'gpx_path': objectPath,
    'fit_path': null,
    'deleted_at': null,
    'sync_version': 1,
  };

  http.Response jsonResponse(
    http.Request request,
    Object? body, {
    int status = 200,
  }) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
    request: request,
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    rides = RideRepository(db);
    cloudRows = {rideId: cloudRide()};
    cloudRoutes = [];
    requests = [];
    failStorage = false;
    failPush = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivity, (_) async => ['wifi']);

    client = SupabaseClient(
      'https://sync-test.invalid',
      'test-publishable-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/auth/v1/signup') {
          String jwtPart(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          final token =
              '${jwtPart({'alg': 'HS256', 'typ': 'JWT'})}.'
              '${jwtPart({'sub': userId, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.test-signature';
          return jsonResponse(request, {
            'access_token': token,
            'refresh_token': 'test-refresh-token',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'created_at': recordedAt.toIso8601String(),
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'is_anonymous': true,
            },
          });
        }
        if (path == '/rest/v1/rpc/push_ride') {
          if (failPush) {
            return jsonResponse(request, {
              'message': 'push unavailable',
              'code': '503',
            }, status: 503);
          }
          final payload = Map<String, dynamic>.from(
            (jsonDecode(request.body) as Map)['p_ride'] as Map,
          );
          final id = payload['id'] as String;
          cloudRows[id] = {...?cloudRows[id], ...payload};
          return http.Response('', 204, request: request);
        }
        if ((path == '/rest/v1/rides' || path == '/rest/v1/routes') &&
            request.method == 'GET') {
          final query = request.url.queryParameters;
          var rows = path.endsWith('/rides')
              ? cloudRows.values.toList()
              : cloudRoutes.toList();
          rows.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
          if (query['deleted_at'] == 'not.is.null') {
            rows = rows.where((row) => row['deleted_at'] != null).toList();
          }
          final since = query['updated_at'];
          if (since != null) {
            final timestamp = DateTime.parse(since.substring(3));
            rows = rows
                .where(
                  (row) => DateTime.parse(
                    row['updated_at'] as String,
                  ).isAfter(timestamp),
                )
                .toList();
          }
          final offset = int.tryParse(query['offset'] ?? '') ?? 0;
          final limit = int.tryParse(query['limit'] ?? '') ?? 1000;
          rows = rows.skip(offset).take(limit).toList();
          final columns = query['select']!.split(',');
          return jsonResponse(request, [
            for (final row in rows)
              {for (final column in columns) column: row[column]},
          ]);
        }
        if (path == '/storage/v1/object/rides' && request.method == 'DELETE') {
          if (failStorage) {
            return jsonResponse(request, {
              'statusCode': '503',
              'error': 'Unavailable',
              'message': 'Storage unavailable',
            }, status: 503);
          }
          // Already missing is a successful, empty response from Storage.
          return jsonResponse(request, []);
        }
        if (request.method == 'DELETE' && path.startsWith('/rest/v1/')) {
          if (path == '/rest/v1/rides') cloudRows.clear();
          return jsonResponse(request, []);
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.url}',
        );
      }),
    );
    await client.auth.signInAnonymously();
    remote = SupabaseRemote(client, userId);
    service = SyncService(
      db: db,
      rides: rides,
      routes: RouteRepository(db),
      resolveClient: () => client,
      isConfigured: () => true,
    );
    service.applySettings(const AppSettings(cloudSync: true));
    requests.clear();
  });

  tearDown(() async {
    await service.dispose();
    await client.dispose();
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivity, null);
  });

  test(
    'HTTP projection restores notes, recorded metrics and edit timestamp',
    () async {
      final result = await remote.fetchRides();
      await service.mergeRemoteRide(result.single);
      final stored = (await rides.getRide(rideId))!;

      expect(stored.notes, '逆风，注意补给');
      expect(stored.stats.avgSpeedMps, 6);
      expect(stored.stats.maxSpeedMps, 12.5);
      expect(stored.stats.elevationGainMeters, 321);
      expect(stored.stats.elevationLossMeters, 300);
      expect(stored.startPoint!.lat, 31.2);
      expect(stored.endPoint!.lng, 121.5);
      expect(stored.updatedAt, recordedAt);
      expect(await rides.trackPointCount(rideId), 0);
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

  test(
    'summary-only edit preserves cloud GPX and metrics and drains outbox',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.updateDescription(rideId, name: '新的名字', notes: '仍然保留备注');
      final editTime = (await rides.getRide(rideId))!.updatedAt;
      requests.clear();

      final report = await service.syncNow(force: true);

      expect(report.phase, SyncPhase.idle);
      expect(report.uploaded, 1);
      expect(report.pendingCount, 0);
      expect(await db.syncQueueDao.pendingCount(), 0);
      expect((await rides.getRide(rideId))!.updatedAt, editTime);
      expect(cloudRows[rideId]!['updated_at'], editTime!.toIso8601String());
      expect(cloudRows[rideId]!['notes'], '仍然保留备注');
      expect(cloudRows[rideId]!['max_speed_mps'], 12.5);
      expect(cloudRows[rideId]!['elevation_gain_meters'], 321);
      expect(cloudRows[rideId]!['gpx_path'], objectPath);
      expect(
        requests.where((r) => r.url.path.startsWith('/storage/')),
        isEmpty,
      );

      requests.clear();
      final second = await service.syncNow(force: true);
      expect(second.uploaded, 0);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
    },
  );

  test(
    'applying newer remote metadata preserves the remote edit time',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      final remoteEdit = recordedAt.add(const Duration(minutes: 10));
      cloudRows[rideId]!['name'] = '另一台手机的名字';
      cloudRows[rideId]!['updated_at'] = remoteEdit.toIso8601String();

      await service.mergeRemoteRide((await remote.fetchRides()).single);

      expect((await rides.getRide(rideId))!.updatedAt, remoteEdit);
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

  test('local export filenames are never sent as cloud object paths', () async {
    await service.mergeRemoteRide((await remote.fetchRides()).single);
    final ride = (await rides.getRide(rideId))!;
    requests.clear();

    await remote.pushRide(ride.copyWith(gpxPath: '/device/exports/ride.gpx'));

    final payload = (jsonDecode(requests.single.body) as Map)['p_ride'] as Map;
    expect(payload['gpx_path'], isNull);
  });

  test(
    'cloud wipe keeps rows and local references when Storage fails',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      failStorage = true;
      requests.clear();

      final report = await service.deleteCloudData();

      expect(report.ok, isFalse);
      expect(report.message, contains('Storage unavailable'));
      expect(cloudRows, contains(rideId));
      expect((await rides.getRide(rideId))!.gpxPath, objectPath);
      expect(
        requests.where(
          (r) => r.method == 'DELETE' && r.url.path.startsWith('/rest/'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'failed individual GPX deletion remains in the outbox for retry',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.deleteRide(rideId);
      failStorage = true;

      await service.syncNow(force: true);

      final pending = await db.syncQueueDao.all();
      expect(pending, hasLength(1));
      expect(pending.single.operation, SyncOperation.delete);
      expect(pending.single.retryCount, 1);
      expect(pending.single.lastError, contains('Storage unavailable'));
    },
  );

  test(
    'already absent GPX objects do not prevent a successful cloud wipe',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);

      final report = await service.deleteCloudData();

      expect(report.ok, isTrue);
      expect(report.files, 0);
      expect(cloudRows, isEmpty);
      expect((await rides.getRide(rideId))!.gpxPath, isNull);
    },
  );

  test('full pull preserves a failed push error and retry backoff', () async {
    await service.mergeRemoteRide((await remote.fetchRides()).single);
    await rides.updateDescription(rideId, name: '新的名字', notes: '新的备注');
    failPush = true;
    requests.clear();

    await service.syncNow(force: true);

    var pending = await db.syncQueueDao.all();
    expect(pending, hasLength(1));
    expect(pending.single.retryCount, 1);
    expect(pending.single.lastError, contains('push unavailable'));
    expect(await db.syncQueueDao.due(), isEmpty);
    await service.syncNow(force: true);
    pending = await db.syncQueueDao.all();
    expect(pending.single.retryCount, 1);
    expect(pending.single.lastError, contains('push unavailable'));
    expect(
      requests.where((r) => r.url.path == '/rest/v1/rpc/push_ride'),
      hasLength(1),
    );
  });

  test('late uploaded offline edits are found after an earlier pull', () async {
    await service.syncNow(force: true);
    final offlineEdit = recordedAt.add(const Duration(minutes: 30));
    cloudRows[rideId]!['updated_at'] = offlineEdit.toIso8601String();
    cloudRows[rideId]!['notes'] = '离线写下、稍后才上传的备注';
    requests.clear();

    await service.syncNow(force: true);

    final stored = (await rides.getRide(rideId))!;
    expect(stored.notes, '离线写下、稍后才上传的备注');
    expect(stored.updatedAt, offlineEdit);
    expect(
      requests.every((r) => !r.url.queryParameters.containsKey('updated_at')),
      isTrue,
    );
  });

  test('first sync restores more than one page of ride summaries', () async {
    cloudRows = {
      for (var i = 0; i < 501; i++)
        'ride-$i': {...cloudRide(), 'id': 'ride-$i'},
    };

    final report = await service.syncNow(force: true);

    expect(report.phase, SyncPhase.idle);
    expect(report.downloaded, 501);
    expect(await rides.getRide('ride-500'), isNotNull);
    expect(await db.syncQueueDao.pendingCount(), 0);
    final reads = requests
        .where((r) => r.url.path == '/rest/v1/rides')
        .toList();
    expect(reads, hasLength(2));
    expect(
      reads.every((r) => r.url.queryParameters['order']!.startsWith('id.asc')),
      isTrue,
    );
  });

  test('saved routes are fetched beyond the first page', () async {
    cloudRoutes = [
      for (var i = 0; i < 501; i++)
        {
          'id': 'route-$i',
          'name': '路线 $i',
          'route_geometry': {
            'type': 'LineString',
            'coordinates': [
              [121.4, 31.2],
              [121.5, 31.3],
            ],
          },
          'updated_at': recordedAt.toIso8601String(),
        },
    ];

    final result = await remote.fetchRoutes();

    expect(result, hasLength(501));
    expect(result.map((route) => route.id).toSet(), hasLength(501));
    expect(result.every((route) => route.points.length == 2), isTrue);
  });

  test('full pulls do not restore unseen tombstones as live rides', () async {
    cloudRows[rideId]!['deleted_at'] = recordedAt.toIso8601String();

    await service.syncNow(force: true);
    await service.syncNow(force: true);

    expect(await rides.getRide(rideId), isNull);
    expect(await db.syncQueueDao.pendingCount(), 0);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test(
    'remote deletion preserves its timestamp and never requeues itself',
    () async {
      await service.syncNow(force: true);
      final deletedAt = recordedAt.add(const Duration(hours: 2));
      cloudRows[rideId]!['deleted_at'] = deletedAt.toIso8601String();
      cloudRows[rideId]!['updated_at'] = deletedAt.toIso8601String();
      requests.clear();

      await service.syncNow(force: true);
      await service.syncNow(force: true);

      final stored = (await rides.getRide(rideId))!;
      expect(stored.deletedAt, deletedAt);
      expect(stored.updatedAt, deletedAt);
      expect(await db.syncQueueDao.pendingCount(), 0);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
    },
  );

  test(
    'a newer local tombstone is queued as a deletion, never an upsert',
    () async {
      final original = (await remote.fetchRides()).single;
      await service.mergeRemoteRide(original);
      await rides.deleteRide(rideId);

      await service.mergeRemoteRide(original);

      final pending = await db.syncQueueDao.all();
      expect(pending, hasLength(1));
      expect(pending.single.operation, SyncOperation.delete);
    },
  );

  test('cloud wipe path listing reads every page', () async {
    cloudRows = {
      for (var i = 0; i < 1001; i++)
        '$i': {
          ...cloudRide(),
          'id': '$i',
          'gpx_path': 'rides/$userId/$i/original.gpx',
        },
    };

    final paths = await remote.listGpxPaths();

    expect(paths, hasLength(1001));
    expect(paths.toSet(), hasLength(1001));
    final reads = requests
        .where((r) => r.url.path == '/rest/v1/rides')
        .toList();
    expect(reads, hasLength(3));
    expect(
      reads.every((r) => r.url.queryParameters['order']!.startsWith('id.asc')),
      isTrue,
    );
  });
}
