import 'package:cycling_app/core/gpx/gpx_codec.dart';
import 'package:cycling_app/core/utils/geometry_codec.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:flutter_test/flutter_test.dart';

/// GPX is the app's interchange format in both directions, and the only way a
/// ride leaves the phone without the cloud. A file that drops heart rate, or
/// that another tool cannot open, is data loss.
void main() {
  final started = DateTime.utc(2026, 9, 23, 6, 30);
  const origin = GeoPoint(39.9042, 116.4074);

  TrackPoint pointAt(int sequence, double meters, {int? hr, int? cad}) {
    return TrackPoint(
      rideId: 'ride-1',
      sequence: sequence,
      timestamp: started.add(Duration(seconds: sequence)),
      lat: origin.lat + meters / 111132.0,
      lng: origin.lng,
      altitude: 50 + sequence * 0.5,
      speed: 5.5,
      heartRate: hr,
      cadence: cad,
    );
  }

  final ride = Ride(
    id: '0192f3a0-0000-7000-8000-000000000001',
    name: '周末环湖',
    startedAt: started,
    endedAt: started.add(const Duration(minutes: 40)),
    stats: const RideStats(
      distanceMeters: 12345.6,
      elapsed: Duration(minutes: 40),
      moving: Duration(minutes: 38),
      avgSpeedMps: 5.4,
      maxSpeedMps: 11.2,
      elevationGainMeters: 320,
    ),
  );

  group('encoding', () {
    test('produces a well-formed GPX 1.1 document', () {
      final xml = GpxCodec.encode(ride, [pointAt(1, 0), pointAt(2, 5)]);

      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(xml, contains('version="1.1"'));
      expect(xml, contains('creator="PureCycling"'));
      expect(xml, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect(xml, contains('</gpx>'));
    });

    test('writes the ride name, time and every track point', () {
      final points = [for (var i = 1; i <= 20; i++) pointAt(i, i * 5.0)];
      final xml = GpxCodec.encode(ride, points);

      expect(xml, contains('<name>周末环湖</name>'));
      expect(xml, contains('<type>cycling</type>'));
      expect(xml, contains('<time>2026-09-23T06:30:00Z</time>'));
      expect(
        RegExp(r'<trkpt ').allMatches(xml).length,
        20,
        reason: 'every point must be written, not sampled',
      );
    });

    test('carries heart rate and cadence in the Garmin extension', () {
      final xml = GpxCodec.encode(ride, [
        pointAt(1, 0, hr: 142, cad: 88),
        pointAt(2, 5),
      ]);

      expect(xml, contains('gpxtpx:hr>142<'));
      expect(xml, contains('gpxtpx:cad>88<'));
      expect(xml, contains('TrackPointExtension/v1'));
    });

    test('escapes user text rather than emitting invalid XML', () {
      final awkward = ride.copyWith(name: 'A & B <"quick"> ride');
      final xml = GpxCodec.encode(awkward, [pointAt(1, 0), pointAt(2, 5)]);

      expect(xml, contains('&amp;'));
      expect(xml, contains('&lt;'));
      expect(xml, isNot(contains('<"quick">')));

      // And the escaped form must parse back to the original text.
      final parsed = GpxCodec.decode(xml);
      expect(parsed.name, 'A & B <"quick"> ride');
    });
  });

  group('decoding', () {
    test('round-trips a ride without losing points or coordinates', () {
      final points = [for (var i = 1; i <= 50; i++) pointAt(i, i * 7.0)];
      final parsed = GpxCodec.decode(GpxCodec.encode(ride, points));

      expect(parsed.points.length, 50);
      expect(parsed.name, '周末环湖');

      // Coordinates are written to 7 decimal places, which is sub-centimetre.
      expect(parsed.points.first.point.lat, closeTo(points.first.lat, 1e-6));
      expect(parsed.points.last.point.lng, closeTo(points.last.lng, 1e-6));
      expect(parsed.points[10].elevation, closeTo(points[10].altitude!, 0.01));
      expect(parsed.points[10].time, points[10].timestamp);
    });

    test('reads <rtept> as well as <trkpt>', () {
      // Routes exported by planning tools use <rte>, not <trk>.
      const routeXml = '''
<?xml version="1.0"?>
<gpx version="1.1" creator="other-tool" xmlns="http://www.topografix.com/GPX/1/1">
  <rte>
    <name>上班路线</name>
    <rtept lat="39.9042" lon="116.4074"/>
    <rtept lat="39.9142" lon="116.4174"/>
    <rtept lat="39.9242" lon="116.4274"/>
  </rte>
</gpx>''';

      final parsed = GpxCodec.decode(routeXml);
      expect(parsed.points.length, 3);
      expect(parsed.name, '上班路线');
    });

    test('rejects an entry that is not a GPX document', () {
      expect(() => GpxCodec.decode('hello'), throwsA(anything));
    });

    test('skips points with impossible coordinates rather than trusting them',
        () {
      const bad = '''
<?xml version="1.0"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="39.9042" lon="116.4074"/>
    <trkpt lat="999" lon="116.4074"/>
    <trkpt lat="39.9142" lon="116.4174"/>
  </trkseg></trk>
</gpx>''';

      expect(GpxCodec.decode(bad).points.length, 2);
    });
  });

  group('route construction', () {
    test('computes distance and climb from the geometry', () {
      // A 1 km straight line with 100 m of climb in 10 m steps.
      final points = <ParsedGpxPoint>[];
      for (var i = 0; i <= 100; i++) {
        points.add(
          ParsedGpxPoint(
            point: GeoPoint(origin.lat + (i * 10.0) / 111132.0, origin.lng),
            elevation: 100 + i.toDouble(),
          ),
        );
      }

      final route = GpxCodec.toRoute(
        ParsedGpx(name: '爬坡', points: points),
        id: 'route-1',
      );

      expect(route.distanceMeters, closeTo(1000, 20));
      // The thresholded accumulator absorbs a little of the first climb.
      expect(route.elevationGainMeters, greaterThan(90));
      expect(route.elevationGainMeters, lessThan(110));
      expect(route.points.length, 101);
    });

    test('elevation profile buckets a long trace without aliasing', () {
      // A single spike at sample 500 must still be visible in the profile —
      // sampling at bucket boundaries would step straight over it.
      final points = [
        for (var i = 0; i < 1000; i++)
          ParsedGpxPoint(
            point: GeoPoint(origin.lat + i * 1e-5, origin.lng),
            elevation: i == 500 ? 200.0 : 50.0,
          ),
      ];

      final profile = GpxCodec.elevationProfile(points, buckets: 50);

      expect(profile.length, 50);
      expect(
        profile.reduce((a, b) => a > b ? a : b),
        greaterThan(50),
        reason: 'averaging within buckets must not lose a spike',
      );
    });

    test('a flat file produces a flat profile', () {
      final points = [
        for (var i = 0; i < 200; i++)
          ParsedGpxPoint(
            point: GeoPoint(origin.lat + i * 1e-5, origin.lng),
            elevation: 42.0,
          ),
      ];

      final profile = GpxCodec.elevationProfile(points);
      expect(profile.every((e) => (e - 42).abs() < 0.001), isTrue);
    });
  });

  group('WKT geometry for the cloud', () {
    test('produces a LINESTRING in lng-lat order', () {
      final points = [
        TrackPoint(
          rideId: 'r',
          sequence: 1,
          timestamp: started,
          lat: 39.9,
          lng: 116.4,
        ),
        TrackPoint(
          rideId: 'r',
          sequence: 2,
          timestamp: started,
          lat: 39.95,
          lng: 116.45,
        ),
      ];

      final wkt = trackToLineStringWkt(points.map((p) => p.geo).toList());

      expect(wkt, startsWith('LINESTRING('));
      expect(wkt, endsWith(')'));
      // PostGIS expects longitude first. Getting this backwards produces a
      // line in the wrong hemisphere rather than an error.
      expect(wkt, contains('116.400000 39.900000'));
      expect(wkt, contains('116.450000 39.950000'));
    });

    test('simplification keeps the shape while dropping noise', () {
      // A straight line with ±0.5 m of jitter: 500 points that carry no
      // information beyond their endpoints.
      final noisy = <GeoPoint>[];
      for (var i = 0; i < 500; i++) {
        final jitter = (i % 2 == 0) ? 0.0000045 : -0.0000045;
        noisy.add(GeoPoint(origin.lat + i * 1e-4 + jitter, origin.lng));
      }

      final wkt = trackToLineStringWkt(noisy, simplifyToleranceMeters: 2.0);
      final kept = ','.allMatches(wkt).length + 1;

      expect(kept, lessThan(20));
      expect(
        wkt,
        contains('${noisy.last.lng.toStringAsFixed(6)} '
            '${noisy.last.lat.toStringAsFixed(6)}'),
        reason: 'the endpoint must survive simplification',
      );
    });

    test('a turning path keeps its corners', () {
      // An L: north 100 m, then east 100 m. The corner must survive.
      final path = <GeoPoint>[];
      for (var i = 0; i <= 50; i++) {
        path.add(GeoPoint(origin.lat + (i * 2.0) / 111132.0, origin.lng));
      }
      final corner = path.last;
      for (var i = 1; i <= 50; i++) {
        path.add(
          GeoPoint(corner.lat, origin.lng + (i * 2.0) / 90000.0),
        );
      }

      final wkt = trackToLineStringWkt(path);
      final kept = ','.allMatches(wkt).length + 1;

      expect(kept, lessThan(path.length));
      expect(kept, greaterThan(2));
      expect(
        wkt,
        contains('${corner.lng.toStringAsFixed(6)} '
            '${corner.lat.toStringAsFixed(6)}'),
        reason: 'the corner is the only interesting point on this path',
      );
    });
  });
}
