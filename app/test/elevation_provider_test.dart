import 'dart:convert';

import 'package:cycling_app/core/elevation/elevation_provider.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Terrain heights for a planned route.
///
/// The routing service knows roads and not relief, so a route's climb figure
/// comes from somewhere else or it does not come at all. These tests cover the
/// three things that decide whether the number is trustworthy: which points
/// are asked about, what the answer is paired with, and what happens when the
/// service refuses.
void main() {
  group('sampling', () {
    List<GeoPoint> points(int count) => [
          for (var i = 0; i < count; i++) GeoPoint(39.9 + i / 1000, 116.4),
        ];

    test('a short route is asked about in full', () {
      final route = points(40);
      expect(sampleRoutePoints(route), hasLength(40));
    });

    test('a long route is reduced to the limit, endpoints kept', () {
      final route = points(2500);
      final sampled = sampleRoutePoints(route, max: 100);

      expect(sampled, hasLength(100));
      expect(sampled.first.lat, route.first.lat);
      expect(sampled.last.lat, route.last.lat);

      // Evenly spaced in source points, which is the honest contract: the
      // samples are real points from the route (so a query lands on the road),
      // not interpolated ones, so a gap may be one source point off the ideal.
      final expectedGap = (route.length - 1) / (sampled.length - 1);
      for (var i = 1; i < sampled.length; i++) {
        final gapInSourcePoints =
            (sampled[i].lat - sampled[i - 1].lat) / (1 / 1000);
        expect(gapInSourcePoints, closeTo(expectedGap, 1.0));
      }
    });

    test('a limit below two is a programming error, not a silent clamp', () {
      expect(() => sampleRoutePoints(points(10), max: 1), throwsArgumentError);
    });
  });

  group('parsing', () {
    test('heights come back in the order they were asked for', () {
      // The documented envelope, as the service actually sends it.
      final body = jsonEncode({
        'results': [
          {'elevation': 51.0, 'location': {'lat': 39.9, 'lng': 116.4}},
          {'elevation': 148.0, 'location': {'lat': 39.91, 'lng': 116.4}},
          {'elevation': 302.0, 'location': {'lat': 39.92, 'lng': 116.4}},
        ],
        'status': 'OK',
      });

      expect(
        OpenTopoDataElevationProvider.parseHeights(body),
        [51.0, 148.0, 302.0],
      );
    });

    test('a point with no data keeps its slot', () {
      // Dropping it would slide every later height onto the wrong place on the
      // route, which is worse than a gap.
      final body = jsonEncode({
        'results': [
          {'elevation': 51.0},
          {'elevation': null},
          {'elevation': 302.0},
        ],
        'status': 'OK',
      });

      expect(OpenTopoDataElevationProvider.parseHeights(body), [51.0, null, 302.0]);
    });

    test('a refusal is an error, not an empty profile', () {
      final body = jsonEncode({
        'status': 'INVALID_REQUEST',
        'error': 'Too many locations',
      });

      expect(
        () => OpenTopoDataElevationProvider.parseHeights(body),
        throwsA(isA<ElevationProviderException>()),
      );
    });

    test('nonsense is an error', () {
      expect(
        () => OpenTopoDataElevationProvider.parseHeights('<html>nope</html>'),
        throwsA(isA<ElevationProviderException>()),
      );
      expect(
        () => OpenTopoDataElevationProvider.parseHeights('{"status":"OK"}'),
        throwsA(isA<ElevationProviderException>()),
      );
    });
  });

  group('the request', () {
    test('is one GET with lat,lng pairs in order, up to the documented limit',
        () async {
      Uri? requested;
      final provider = OpenTopoDataElevationProvider(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode({
              'results': [
                {'elevation': 10.0},
                {'elevation': 20.0},
              ],
              'status': 'OK',
            }),
            200,
          );
        }),
      );

      final heights = await provider.heights(const [
        GeoPoint(39.9, 116.4),
        GeoPoint(39.91, 116.41),
      ]);

      expect(heights, [10.0, 20.0]);
      expect(requested!.host, 'api.opentopodata.org');
      expect(requested!.path, '/v1/srtm30m');
      expect(
        requested!.queryParameters['locations'],
        '39.90000,116.40000|39.91000,116.41000',
      );
    });

    test('an oversized request is refused before it is sent', () async {
      var called = false;
      final provider = OpenTopoDataElevationProvider(
        client: MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        provider.heights([
          for (var i = 0; i < 101; i++) GeoPoint(39.9 + i / 1000, 116.4),
        ]),
        throwsArgumentError,
      );
      expect(called, isFalse, reason: '超限的请求不该发出去');
    });

    test('a non-200 is an error the caller can report', () async {
      final provider = OpenTopoDataElevationProvider(
        client: MockClient((request) async => http.Response('rate limited', 429)),
      );

      await expectLater(
        provider.heights(const [GeoPoint(39.9, 116.4)]),
        throwsA(isA<ElevationProviderException>()),
      );
    });
  });

  test('the default provider sends nothing', () async {
    const provider = NullElevationProvider();
    expect(provider.isConfigured, isFalse);
    expect(await provider.heights(const [GeoPoint(39.9, 116.4)]), isEmpty);
  });
}
