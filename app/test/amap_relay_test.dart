import 'dart:convert';

import 'package:cycling_app/core/map/amap/amap_relay_client.dart';
import 'package:cycling_app/core/map/amap/amap_place_provider.dart';
import 'package:cycling_app/core/map/amap/amap_route_provider.dart';
import 'package:cycling_app/core/map/coord_transform.dart';
import 'package:cycling_app/core/map/map_providers.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The relay client: the same AMap envelope, a different guard.
///
/// The provider above it — parsing, datum conversion, waypoint stitching —
/// is already covered by `amap_parsing_test.dart` against recorded responses.
/// What is new here is the transport: that it posts what the relay expects,
/// that it carries the session, and that its refusals arrive as messages a
/// rider can act on rather than as an HTTP status.
void main() {
  const origin = GeoPoint(39.9042, 116.4074);
  const destination = GeoPoint(39.9142, 116.4174);

  /// A minimal but structurally complete v5 bicycling response, in GCJ-02 —
  /// which is what the vendor (and therefore the relay) returns.
  String amapBody() => jsonEncode({
    'status': '1',
    'info': 'OK',
    'infocode': '10000',
    'route': {
      'paths': [
        {
          'distance': '1234',
          'duration': '300',
          'steps': [
            {
              'instruction': '向东骑行',
              'road_name': '人民大道',
              'step_distance': '600',
              'action': 'straight',
              'polyline': '116.407400,39.904200;116.417400,39.904200',
              'cost': {'duration': '150'},
            },
            {
              'instruction': '左转进入北向路',
              'road_name': '北向路',
              'step_distance': '634',
              'action': 'left',
              'polyline': '116.417400,39.904200;116.417400,39.914200',
              'cost': {'duration': '150'},
            },
          ],
        },
      ],
    },
  });

  test('posts the relay payload and parses the route back to WGS-84', () async {
    late http.Request seen;
    final client = AmapRelayClient(
      endpoint: 'https://relay.test/functions/v1/route',
      accessToken: () => 'session-token',
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response(
          amapBody(),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    expect(client.isConfigured, isTrue);

    final provider = AmapRouteProvider(client: client);
    final route = await provider.planRoute(
      origin: origin,
      destination: destination,
    );

    expect(seen.method, 'POST');
    expect(seen.headers['Authorization'], 'Bearer session-token');
    final payload = jsonDecode(seen.body) as Map<String, dynamic>;

    // Outbound coordinates are GCJ-02: the vendor must snap to the road the
    // rider is actually on, not to one 300 m to the side.
    final gcjOrigin = CoordTransform.wgs84ToGcj02(origin);
    final gcjDestination = CoordTransform.wgs84ToGcj02(destination);
    expect(
      payload['origin'],
      '${gcjOrigin.lng.toStringAsFixed(6)},${gcjOrigin.lat.toStringAsFixed(6)}',
    );
    expect(
      payload['destination'],
      '${gcjDestination.lng.toStringAsFixed(6)},'
      '${gcjDestination.lat.toStringAsFixed(6)}',
    );
    expect(payload['alternatives'], 1);

    expect(route.points, hasLength(3));
    expect(route.instructions, hasLength(2));
    expect(route.instructions[1].maneuver, Maneuver.left);
    expect(route.instructions[1].roadName, '北向路');
    expect(route.distanceMeters, 1234);

    // The response is GCJ-02; everything downstream is WGS-84. If this ever
    // stops being converted, the route is drawn 300 m from the road.
    final expected = CoordTransform.gcj02ToWgs84(
      const GeoPoint(39.9042, 116.4074),
    );
    expect(route.points.first.lat, closeTo(expected.lat, 1e-9));
    expect(route.points.first.lng, closeTo(expected.lng, 1e-9));
  });

  test('a session that is not there yet is a configuration problem', () async {
    final client = AmapRelayClient(
      endpoint: 'https://relay.test/functions/v1/route',
      accessToken: () => null,
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );

    expect(client.isConfigured, isFalse);
    await expectLater(
      AmapRouteProvider(
        client: client,
      ).planRoute(origin: origin, destination: destination),
      throwsA(
        isA<RoutePlanningException>()
            .having((e) => e.isConfiguration, 'isConfiguration', isTrue)
            .having((e) => e.message, 'message', contains('登录')),
      ),
    );
  });

  test('a refusal carries the relay\'s own words', () async {
    final client = AmapRelayClient(
      endpoint: 'https://relay.test/functions/v1/route',
      accessToken: () => 'session-token',
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': '0',
            'info': '今日在线路线规划次数已用完（上限 200 次）',
            'infocode': 'relay_429',
          }),
          429,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      AmapRouteProvider(
        client: client,
      ).planRoute(origin: origin, destination: destination),
      throwsA(
        isA<RoutePlanningException>()
            .having((e) => e.isConfiguration, 'isConfiguration', isFalse)
            .having((e) => e.message, 'message', contains('次数已用完')),
      ),
    );
  });

  test(
    'an expired session points at the login rather than at a retry',
    () async {
      final client = AmapRelayClient(
        endpoint: 'https://relay.test/functions/v1/route',
        accessToken: () => 'stale',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': '0',
              'info': '需要登录后使用在线路线规划（匿名账号也可以）',
              'infocode': 'relay_401',
            }),
            401,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );

      await expectLater(
        AmapRouteProvider(
          client: client,
        ).planRoute(origin: origin, destination: destination),
        throwsA(
          isA<RoutePlanningException>().having(
            (e) => e.isConfiguration,
            'isConfiguration',
            isTrue,
          ),
        ),
      );
    },
  );

  test('a vendor error inside a 200 keeps its translation', () async {
    final client = AmapRelayClient(
      endpoint: 'https://relay.test/functions/v1/route',
      accessToken: () => 'session-token',
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': '0',
            'info': 'INVALID_PARAMS',
            'infocode': '20802',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      AmapRouteProvider(
        client: client,
      ).planRoute(origin: origin, destination: destination),
      throwsA(
        isA<RoutePlanningException>().having(
          (e) => e.message,
          'message',
          contains('无法规划出骑行路线'),
        ),
      ),
    );
  });

  test('the relay is not a general gateway', () async {
    final client = AmapRelayClient(
      endpoint: 'https://relay.test/functions/v1/route',
      accessToken: () => 'session-token',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );

    await expectLater(
      client.get('/v3/geocode/regeo', const {'location': '116.4,39.9'}),
      throwsA(isA<RoutePlanningException>()),
    );
  });

  test(
    'place search uses the relay and converts returned coordinates',
    () async {
      late http.Request seen;
      final client = AmapRelayClient(
        endpoint: 'https://relay.test/functions/v1/route',
        accessToken: () => 'session-token',
        anonKey: 'public-key',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'status': '1',
              'pois': [
                {
                  'id': 'poi-1',
                  'name': '人民公园',
                  'location': '116.407400,39.904200',
                  'address': '北京市',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final places = AmapPlaceProvider(client: client);
      final found = await places.search('人民公园', near: origin, limit: 8);
      expect(seen.method, 'POST');
      expect(seen.headers['Authorization'], 'Bearer session-token');
      expect(seen.headers['apikey'], 'public-key');
      final payload = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(payload['action'], 'place_search');
      expect(payload['keywords'], '人民公园');
      expect(payload['limit'], 8);
      expect(found, hasLength(1));
      expect(found.first.name, '人民公园');
      final expected = CoordTransform.gcj02ToWgs84(origin);
      expect(found.first.point.lat, closeTo(expected.lat, 1e-9));
      expect(found.first.point.lng, closeTo(expected.lng, 1e-9));
    },
  );
}
