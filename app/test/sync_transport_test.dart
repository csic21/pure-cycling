import 'dart:convert';
import 'dart:io';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/sync/supabase_remote.dart';
import 'package:cycling_app/core/sync/cloud_data_wipe_client.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:cycling_app/core/sync/sync_service.dart';
import 'package:cycling_app/core/sync/sync_status.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/routes/data/route_repository.dart';
import 'package:cycling_app/features/routes/domain/route.dart' as route_model;
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
  const connectivityEvents = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
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
  late CloudDataWipeClient wipeClient;
  late Directory temp;
  late Set<String> storedObjects;
  late bool failWipe;
  Future<void> Function()? duringRidePush;

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
    temp = await Directory.systemTemp.createTemp('sync-test-');
    rides = _ExportRepository(db, File('${temp.path}/trace.gpx'));
    storedObjects = {objectPath};
    failWipe = false;
    duringRidePush = null;
    cloudRows = {rideId: cloudRide()};
    cloudRoutes = [];
    requests = [];
    failStorage = false;
    failPush = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivityEvents, (_) async => null);

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
        if (path == '/rest/v1/rpc/new_gpx_upload_path') {
          final payload = jsonDecode(request.body) as Map;
          return jsonResponse(
            request,
            'rides/$userId/${payload['p_ride_id']}/11111111-1111-4111-8111-111111111111/${payload['p_attempt_id']}.gpx',
          );
        }
        if (path == '/rest/v1/rpc/push_ride_v2') {
          if (failPush) {
            return jsonResponse(request, {
              'message': 'push unavailable',
              'code': '503',
            }, status: 503);
          }
          final payload = Map<String, dynamic>.from(
            (jsonDecode(request.body) as Map)['p_ride'] as Map,
          );
          final hook = duringRidePush;
          duringRidePush = null;
          if (hook != null) await hook();
          if (payload['deleted_at'] == null &&
              payload['gpx_path'] != null &&
              !storedObjects.contains(payload['gpx_path'])) {
            return jsonResponse(request, {
              'code': 'PC001',
              'message': 'GPX_OBJECT_MISSING',
            }, status: 400);
          }
          final id = payload['id'] as String;
          final old = cloudRows[id];
          final newer =
              old == null ||
              DateTime.parse(
                payload['updated_at'] as String,
              ).isAfter(DateTime.parse(old['updated_at'] as String));
          final deleteTie =
              old != null &&
              old['deleted_at'] == null &&
              payload['deleted_at'] != null &&
              payload['updated_at'] == old['updated_at'];
          final accepted =
              old == null ||
              ((old['deleted_at'] == null || payload['deleted_at'] != null) &&
                  (newer || deleteTie));
          if (accepted) {
            cloudRows[id] = {
              ...?old,
              ...payload,
              'gpx_path': payload['gpx_path'] ?? old?['gpx_path'],
            };
          }
          return jsonResponse(request, {
            'accepted': accepted,
            'row': cloudRows[id],
          });
        }
        if (path == '/rest/v1/rpc/push_route_v2') {
          final payload = Map<String, dynamic>.from(
            (jsonDecode(request.body) as Map)['p_route'] as Map,
          );
          final index = cloudRoutes.indexWhere(
            (row) => row['id'] == payload['id'],
          );
          final old = index < 0 ? null : cloudRoutes[index];
          final accepted =
              old == null ||
              (old['deleted_at'] == null &&
                  DateTime.parse(
                    payload['updated_at'] as String,
                  ).isAfter(DateTime.parse(old['updated_at'] as String)));
          if (accepted) {
            if (index < 0) {
              cloudRoutes.add(payload);
            } else {
              cloudRoutes[index] = payload;
            }
          }
          return jsonResponse(request, {
            'accepted': accepted,
            'row': accepted ? payload : old,
          });
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
          final paths = (jsonDecode(request.body) as Map)['prefixes'] as List;
          for (final path in paths) {
            storedObjects.remove(path);
          }
          // Already missing is a successful, empty response from Storage.
          return jsonResponse(request, []);
        }
        if (request.method == 'POST' &&
            path.startsWith('/storage/v1/object/rides/')) {
          final object = path.substring('/storage/v1/object/rides/'.length);
          expect(request.headers['x-upsert'], 'false');
          expect(object, isNot(objectPath));
          storedObjects.add(object);
          return jsonResponse(request, {'Key': 'rides/$object'});
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
    db.resolveOwner = () => client.auth.currentUser?.id;
    remote = SupabaseRemote(client, userId);
    wipeClient = CloudDataWipeClient(
      endpoint: 'https://sync-test.invalid/functions/v1/wipe-cloud-data',
      accessToken: () => client.auth.currentSession?.accessToken,
      httpClient: MockClient((request) async {
        requests.add(request);
        if (failStorage || failWipe) {
          return jsonResponse(request, {
            'error': 'Storage unavailable',
          }, status: 503);
        }
        storedObjects.clear();
        cloudRows.clear();
        return jsonResponse(request, {'wiped': true, 'files': 0});
      }),
    );
    service = SyncService(
      db: db,
      rides: rides,
      routes: RouteRepository(db),
      resolveClient: () => client,
      isConfigured: () => true,
      cloudWipeClient: wipeClient,
    );
    service.applySettings(const AppSettings(cloudSync: true));
    requests.clear();
  });

  tearDown(() async {
    await service.dispose();
    await client.dispose();
    wipeClient.close();
    await db.close();
    await temp.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivity, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivityEvents, null);
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
      requests.where((r) => r.url.path == '/rest/v1/rpc/push_ride_v2'),
      hasLength(1),
    );
  });

  test(
    'stale metadata push consumes server winner and cannot overwrite it',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.updateDescription(
        rideId,
        name: 'stale offline name',
        notes: 'stale',
      );
      final newer = DateTime.now().toUtc().add(const Duration(hours: 1));
      cloudRows[rideId]!['updated_at'] = newer.toIso8601String();
      cloudRows[rideId]!['name'] = 'server winner';
      cloudRows[rideId]!['notes'] = 'newer';
      await service.syncNow(force: true);
      expect(cloudRows[rideId]!['name'], 'server winner');
      expect((await rides.getRide(rideId))!.name, 'server winner');
      expect((await rides.getRide(rideId))!.updatedAt, newer);
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

  test(
    'stale trace upload never overwrites winning GPX and removes its candidate',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.importTrackPoints(rideId, [
        for (var i = 1; i <= 2; i++)
          TrackPoint(
            rideId: rideId,
            sequence: i,
            timestamp: recordedAt.add(Duration(seconds: i)),
            lat: 31 + i * .01,
            lng: 121,
          ),
      ]);
      await rides.setGpxPath(rideId, '/local/old-export.gpx');
      await rides.updateDescription(rideId, name: 'stale', notes: null);
      cloudRows[rideId]!['updated_at'] = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String();
      await service.syncNow(force: true);
      expect(storedObjects, {objectPath});
      expect(cloudRows[rideId]!['gpx_path'], objectPath);
      expect((await rides.getRide(rideId))!.gpxPath, objectPath);
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

  test('server tombstone wins even over a future-dated local edit', () async {
    await service.mergeRemoteRide((await remote.fetchRides()).single);
    await rides.updateDescription(rideId, name: 'offline edit', notes: null);
    cloudRows[rideId]!['deleted_at'] = recordedAt.toIso8601String();
    await service.syncNow(force: true);
    expect((await rides.getRide(rideId))!.isDeleted, isTrue);
    expect(cloudRows[rideId]!['deleted_at'], isNotNull);
    expect(storedObjects, isEmpty);
    expect(await db.syncQueueDao.pendingCount(), 0);
  });

  test(
    'a losing stale local delete never removes the live winner GPX',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.deleteRide(rideId);
      cloudRows[rideId]!['updated_at'] = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String();
      await service.syncNow(force: true);
      expect(storedObjects, {objectPath});
      expect((await rides.getRide(rideId))!.isDeleted, isFalse);
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

  test(
    'a deletion during an in-flight upsert is not resurrected by its acknowledgement',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.updateDescription(rideId, name: 'uploading', notes: null);
      duringRidePush = () => rides.deleteRide(rideId);
      await service.syncNow(force: true);
      expect((await rides.getRide(rideId))!.isDeleted, isTrue);
      final pending = await db.syncQueueDao.all();
      expect(pending, hasLength(1));
      expect(pending.single.operation, SyncOperation.delete);
      await service.syncNow(force: true);
      expect(cloudRows[rideId]!['deleted_at'], isNotNull);
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

  test(
    'a committed enqueue wakes the running service without a manual sync',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      service.start();
      final uploaded = service.reports.firstWhere(
        (report) => report.uploaded == 1 && !report.isBusy,
      );
      await rides.updateDescription(
        rideId,
        name: 'automatic upload',
        notes: null,
      );
      await uploaded.timeout(const Duration(seconds: 5));
      expect(cloudRows[rideId]!['name'], 'automatic upload');
      expect(await db.syncQueueDao.pendingCount(), 0);
      await service.stop();
    },
  );

  test(
    'a retained path after a remote wipe is rebuilt from the local trace',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.importTrackPoints(rideId, [
        for (var i = 1; i <= 2; i++)
          TrackPoint(
            rideId: rideId,
            sequence: i,
            timestamp: recordedAt.add(Duration(seconds: i)),
            lat: 31 + i * .01,
            lng: 121,
          ),
      ]);
      await rides.updateDescription(rideId, name: 'local backup', notes: null);
      cloudRows.clear();
      storedObjects.clear();
      await service.syncNow(force: true);
      expect(cloudRows[rideId]!['gpx_path'], isNot(objectPath));
      expect(storedObjects, contains(cloudRows[rideId]!['gpx_path']));
      expect(
        (await rides.getRide(rideId))!.gpxPath,
        cloudRows[rideId]!['gpx_path'],
      );
      expect(await rides.trackPointCount(rideId), 2);
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

  test(
    'a missing cloud trace with no local copy remains retryable, not falsely synced',
    () async {
      await service.mergeRemoteRide((await remote.fetchRides()).single);
      await rides.updateDescription(rideId, name: 'summary only', notes: null);
      cloudRows.clear();
      storedObjects.clear();
      await service.syncNow(force: true);
      expect(cloudRows, isEmpty);
      expect(
        (await db.syncQueueDao.all()).single.lastError,
        contains('云端轨迹已删除'),
      );
      expect((await rides.getRide(rideId))!.name, 'summary only');
    },
  );

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

  test(
    'rejected route push applies the canonical name, geometry and timestamp',
    () async {
      cloudRows.clear();
      final stamp = recordedAt.toIso8601String();
      cloudRoutes = [
        {
          'id': 'route-1',
          'name': 'initial route',
          'updated_at': stamp,
          'created_at': stamp,
          'route_geometry': {
            'type': 'LineString',
            'coordinates': [
              [121.4, 31.2],
              [121.5, 31.3],
            ],
          },
        },
      ];
      await service.syncNow(force: true);
      await RouteRepository(db).renameRoute('route-1', 'stale rename');
      final newer = DateTime.now().toUtc().add(const Duration(hours: 1));
      cloudRoutes.single['updated_at'] = newer.toIso8601String();
      cloudRoutes.single['name'] = 'server route';
      await service.syncNow(force: true);
      final route_model.Route local = (await db.routeDao.getRoute('route-1'))!;
      expect(local.name, 'server route');
      expect(local.updatedAt, newer);
      expect(local.points, hasLength(2));
      expect(await db.syncQueueDao.pendingCount(), 0);
    },
  );

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

class _ExportRepository extends RideRepository {
  _ExportRepository(AppDatabase db, this.file) : super(db, documentsDirectory: () async => file.parent);
  final File file;
  @override
  Future<File> exportGpx(Ride ride) async {
    await file.writeAsString('<gpx><trk><name>${ride.name}</name></trk></gpx>');
    return file;
  }
}
