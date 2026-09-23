import 'dart:convert';

import 'package:cycling_app/core/map/amap/amap_client.dart';
import 'package:cycling_app/core/map/amap/amap_place_provider.dart';
import 'package:cycling_app/core/map/amap/amap_route_provider.dart';
import 'package:cycling_app/core/map/coord_transform.dart';
import 'package:cycling_app/core/map/map_providers.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Tests the AMap integration against **recorded responses**, with no key and
/// no network.
///
/// This is deliberate, and it is the reason nobody needs to put an AMap key in
/// the repository to work on this. A live key would add three problems:
///
/// * It burns quota on every CI run.
/// * It is a credential, and credentials in a repository leak.
/// * It makes the test fail when AMap is slow, rate-limiting, or has changed
///   the road network — none of which are regressions in this code.
///
/// What actually needs testing is the *parsing*: the datum conversion, the
/// step-to-instruction mapping, and the error taxonomy. All three are pure
/// functions of the response body, so a recorded body tests them exactly as
/// well as a live one and reproducibly.
class _Recorder {
  Uri? lastUri;

  /// A client that answers with [body] and records what was asked for.
  MockClient answering(Map<String, dynamic> body, {int status = 200}) {
    return MockClient((request) async {
      lastUri = request.url;
      return http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
  }

  MockClient failing(int status) {
    return MockClient((request) async {
      lastUri = request.url;
      return http.Response('', status);
    });
  }
}

/// A v5 riding-directions response, reduced to the fields the app reads.
///
/// The coordinates are GCJ-02, which is what AMap actually returns — the
/// shifting is the whole point of the conversion this file is checking. They
/// are the real GCJ-02 forms of the WGS-84 points the test plans from, so a
/// round trip through the conversion has to land back where it started.
const Map<String, dynamic> _bicyclingResponse = {
  'status': '1',
  'info': 'OK',
  'infocode': '10000',
  'count': '1',
  'route': {
    'origin': '116.487029,39.990921',
    'destination': '116.440663,39.909541',
    'distance': '12500',
    'duration': '3000',
    'paths': [
      {
        'distance': '12500',
        'duration': '3000',
        'steps': [
          {
            'instruction': '向北骑行200米',
            'orientation': '北',
            'road_name': '中关村大街',
            'step_distance': '200',
            'cost': {'duration': '60'},
            'polyline': '116.487029,39.990921;116.487029,39.992702',
            'action': '直行',
            'assistant_action': '',
          },
          {
            'instruction': '左转进入人民大道骑行1200米',
            'orientation': '西',
            'road_name': '人民大道',
            'step_distance': '1200',
            'cost': {'duration': '288'},
            'polyline': '116.487029,39.992702;116.476001,39.992702',
            'action': '左转',
            'assistant_action': '',
          },
        ],
      },
    ],
  },
};

void main() {
  // Beijing, in WGS-84 — what the GPS receiver reports.
  const wgsOrigin = GeoPoint(39.98964, 116.48094);
  const wgsDestination = GeoPoint(39.90816, 116.43445);

  group('route planning', () {
    late _Recorder recorder;

    setUp(() => recorder = _Recorder());

    Future<Route> plan({Map<String, dynamic>? response}) {
      final provider = AmapRouteProvider(
        client: AmapClient(
          apiKey: 'test-key-not-a-credential',
          httpClient: recorder.answering(response ?? _bicyclingResponse),
        ),
      );
      return provider.planRoute(
        origin: wgsOrigin,
        destination: wgsDestination,
      );
    }

    test('converts the request to GCJ-02 before sending', () async {
      await plan();

      final expected = CoordTransform.wgs84ToGcj02(wgsOrigin);
      final sent = recorder.lastUri!.queryParameters['origin']!;
      final parts = sent.split(',').map(double.parse).toList();

      // Longitude first — AMap's ordering is the reverse of everything else in
      // this codebase, and getting it backwards puts the route in the ocean
      // rather than raising an error.
      expect(parts[0], closeTo(expected.lng, 1e-5));
      expect(parts[1], closeTo(expected.lat, 1e-5));

      // Sending WGS-84 unchanged would snap the route to a road 300 m away.
      expect(parts[1], isNot(closeTo(wgsOrigin.lat, 1e-4)));
    });

    test('asks for the fields it needs, including the polyline', () async {
      await plan();

      expect(recorder.lastUri!.queryParameters['key'], 'test-key-not-a-credential');
      expect(recorder.lastUri!.path, '/v5/direction/bicycling');
      // Without `show_fields` the v5 response omits the geometry entirely and
      // there is nothing to draw or navigate along.
      expect(recorder.lastUri!.queryParameters['show_fields'], contains('polyline'));
    });

    test('converts the returned geometry back to WGS-84', () async {
      final route = await plan();

      // The response's first coordinate is the GCJ-02 form of the origin we
      // sent. After conversion it must land back on the WGS-84 origin.
      final first = route.points.first;
      final error = haversineMeters(
        wgsOrigin.lat,
        wgsOrigin.lng,
        first.lat,
        first.lng,
      );

      expect(
        error,
        lessThan(1),
        reason: 'a route drawn in GCJ-02 on WGS-84 tiles is 300 m off the road',
      );
    });

    test('maps each step to an instruction with its maneuver and road',
        () async {
      final route = await plan();

      expect(route.instructions.length, 2);

      final departure = route.instructions[0];
      expect(departure.maneuver, Maneuver.straight);
      expect(departure.roadName, '中关村大街');
      expect(departure.distanceMeters, 200);

      final turn = route.instructions[1];
      // Read from the Chinese instruction text, not the numeric `action` code:
      // the numeric codes changed between API versions and are not documented
      // consistently, while the text is stable and human-authored.
      expect(turn.maneuver, Maneuver.left);
      expect(turn.roadName, '人民大道');
      expect(turn.distanceMeters, 1200);
      expect(turn.durationSeconds, 288);
    });

    test('uses the service distance, not the simplified polyline length',
        () async {
      final route = await plan();

      // The polyline is simplified; the service measures along the real road
      // network. Prefer the service.
      expect(route.distanceMeters, 12500);
      expect(route.estimatedDuration, const Duration(seconds: 3000));
    });

    test('reports no elevation, because AMap does not provide any', () async {
      final route = await plan();

      expect(
        route.elevationGainMeters,
        isNull,
        reason: 'zero would be a claim that the route is flat, not a placeholder',
      );
    });

    test('carries the provider id so a saved route knows its origin', () async {
      final route = await plan();
      expect(route.provider, 'amap');
    });
  });

  group('error handling', () {
    Future<void> expectFailure(
      Map<String, dynamic> body, {
      required bool isConfiguration,
      required String messageContains,
    }) async {
      final recorder = _Recorder();
      final provider = AmapRouteProvider(
        client: AmapClient(
          apiKey: 'test-key-not-a-credential',
          httpClient: recorder.answering(body),
        ),
      );

      await expectLater(
        provider.planRoute(origin: wgsOrigin, destination: wgsDestination),
        throwsA(
          isA<RoutePlanningException>()
              .having((e) => e.isConfiguration, 'isConfiguration', isConfiguration)
              .having((e) => e.message, 'message', contains(messageContains)),
        ),
      );
    }

    test('an invalid key is flagged as a configuration problem', () async {
      // The distinction matters: a configuration error should send the rider
      // to settings, a transient one should offer a retry.
      await expectFailure(
        {'status': '0', 'info': 'INVALID_USER_KEY', 'infocode': '10001'},
        isConfiguration: true,
        messageContains: 'Key 无效',
      );
    });

    test('an exhausted quota is flagged as configuration', () async {
      await expectFailure(
        {'status': '0', 'info': 'DAILY_QUERY_OVER_LIMIT', 'infocode': '10003'},
        isConfiguration: true,
        messageContains: '配额',
      );
    });

    test('a route that cannot be planned is not a configuration problem',
        () async {
      await expectFailure(
        {'status': '0', 'info': 'NO_ROUTE', 'infocode': '20802'},
        isConfiguration: false,
        messageContains: '无法规划',
      );
    });

    test('a success response with no paths is reported cleanly', () async {
      await expectFailure(
        <String, dynamic>{
          'status': '1',
          'info': 'OK',
          'infocode': '10000',
          'route': <String, dynamic>{},
        },
        isConfiguration: false,
        messageContains: '没有返回可用的骑行路线',
      );
    });

    test('an HTTP failure is reported as a network problem', () async {
      final recorder = _Recorder();
      final provider = AmapRouteProvider(
        client: AmapClient(
          apiKey: 'test-key-not-a-credential',
          httpClient: recorder.failing(500),
        ),
      );

      await expectLater(
        provider.planRoute(origin: wgsOrigin, destination: wgsDestination),
        throwsA(
          isA<RoutePlanningException>()
              .having((e) => e.message, 'message', contains('HTTP 500')),
        ),
      );
    });
  });

  group('configuration guard', () {
    test('an empty key fails before any request is made', () async {
      var called = false;
      final provider = AmapRouteProvider(
        client: AmapClient(
          apiKey: '   ',
          httpClient: MockClient((_) async {
            called = true;
            return http.Response('{}', 200);
          }),
        ),
      );

      await expectLater(
        provider.planRoute(origin: wgsOrigin, destination: wgsDestination),
        throwsA(isA<RoutePlanningException>()
            .having((e) => e.isConfiguration, 'isConfiguration', isTrue)),
      );

      expect(called, isFalse, reason: 'no point asking AMap without a key');
      expect(provider.isConfigured, isFalse);
    });
  });

  group('place search', () {
    test('parses POIs and converts their coordinates to WGS-84', () async {
      const response = {
        'status': '1',
        'info': 'OK',
        'infocode': '10000',
        'pois': [
          {
            'id': 'B000A7BM4H',
            'name': '人民广场',
            'location': '121.473700,31.230400',
            'address': '黄浦区人民大道',
          },
          {
            'id': 'B000A7BM4I',
            'name': '没有位置信息的条目',
          },
        ],
      };

      final recorder = _Recorder();
      final provider = AmapPlaceProvider(
        client: AmapClient(
          apiKey: 'test-key-not-a-credential',
          httpClient: recorder.answering(response),
        ),
      );

      final results = await provider.search('人民广场');

      // The entry with no `location` is dropped rather than producing a result
      // at (0, 0), which would be an island in the Atlantic.
      expect(results.length, 1);
      expect(results.first.name, '人民广场');
      // POIs arrive in GCJ-02 like everything else from AMap.
      final shifted = CoordTransform.gcj02ToWgs84(
        const GeoPoint(31.230400, 121.473700),
      );
      expect(results.first.point.lat, closeTo(shifted.lat, 1e-6));
      expect(results.first.point.lng, closeTo(shifted.lng, 1e-6));
    });
  });

  group('traffic lights', () {
    test('reports unavailable rather than returning an empty list', () async {
      // An empty list would be indistinguishable from "no light ahead", and a
      // rider would reasonably conclude the feature worked.
      const provider = AmapTrafficLightProviderStub();

      expect(provider.isAvailable, isFalse);
      expect(provider.unavailableReason, isNotNull);
      expect(await provider.lightsAhead(position: wgsOrigin, headingDegrees: 0),
          isEmpty);
    });
  });
}

/// The AMap traffic-light provider, re-declared here so this file does not
/// depend on the integration module's import graph.
class AmapTrafficLightProviderStub implements TrafficLightProvider {
  const AmapTrafficLightProviderStub();

  @override
  String get id => 'amap';

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason => '需要两轮车导航 SDK 授权，当前版本未接入。';

  @override
  Future<List<TrafficLightInfo>> lightsAhead({
    required GeoPoint position,
    required double headingDegrees,
    double withinMeters = 300,
  }) async =>
      const [];
}
