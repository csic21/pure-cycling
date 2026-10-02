import 'package:cycling_app/core/location/distance_calculator.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests exist because distance is the number a rider trusts least and
/// checks first. A bike computer that reports 1.2 km for a ride to the corner
/// shop is worse than one that reports nothing.
void main() {
  /// Moves [meters] north from [origin]. Roughly 1 degree of latitude is
  /// 111,132 m, so the inverse is exact enough for a test.
  GeoPoint north(GeoPoint origin, double meters) =>
      GeoPoint(origin.lat + meters / 111132.0, origin.lng);

  const origin = GeoPoint(39.9042, 116.4074);
  final t0 = DateTime.utc(2026, 9, 23, 6);

  DistanceCalculator fresh() => DistanceCalculator();

  group('standing still', () {
    test('oscillating jitter around a parked bicycle adds no distance', () {
      final calc = fresh();
      calc.add(origin, t0);

      // A minute at a red light. The receiver swings across a five-metre span
      // at 1 Hz — consecutive samples are ten metres apart, which is exactly
      // the pattern a per-sample threshold cannot catch. Summing raw deltas
      // here would report about 600 m.
      for (var i = 1; i <= 60; i++) {
        final wobble = (i % 2 == 0) ? 5.0 : -5.0;
        calc.add(
          north(origin, wobble),
          t0.add(Duration(seconds: i)),
          accuracyMeters: 5,
        );
      }

      expect(
        calc.totalMeters,
        0,
        reason: 'a stationary rider must not accumulate distance',
      );
    });

    test('a long, slow wander is rejected by the speed gate', () {
      final calc = fresh();
      calc.add(origin, t0);

      // The receiver drifts 40 m over two minutes — 0.33 m/s. It clears the
      // radius, so the radius alone would let it through; the speed floor is
      // what stops a stationary bike from manufacturing a city block.
      var point = origin;
      for (var i = 1; i <= 120; i++) {
        point = north(point, 40 / 120);
        calc.add(
          point,
          t0.add(Duration(seconds: i)),
          accuracyMeters: 8,
        );
      }

      expect(calc.totalMeters, 0);
    });

    test('a poor fix widens the radius rather than being trusted', () {
      final calc = DistanceCalculator();
      calc.add(origin, t0, accuracyMeters: 20);

      // 20 m of apparent movement, reported at ±20 m accuracy. The radius is
      // 40 m, so this is not yet evidence of anything.
      calc.add(
        north(origin, 20),
        t0.add(const Duration(seconds: 2)),
        accuracyMeters: 20,
      );

      expect(calc.totalMeters, 0);

      // The same movement reported at ±3 m accuracy clears the 12 m floor and
      // is banked in full.
      final accurate = DistanceCalculator();
      accurate.add(origin, t0, accuracyMeters: 3);
      accurate.add(
        north(origin, 20),
        t0.add(const Duration(seconds: 2)),
        accuracyMeters: 3,
      );

      expect(accurate.totalMeters, closeTo(20, 1));
    });
  });

  group('real movement', () {
    test('a straight 1 km at 20 km/h is measured accurately', () {
      final calc = fresh();
      calc.add(origin, t0, accuracyMeters: 4);

      // 20 km/h is 5.556 m/s; 1 Hz samples over 180 s is 1000 m.
      const speed = 5.5556;
      var point = origin;
      for (var i = 1; i <= 180; i++) {
        point = north(point, speed);
        calc.add(point, t0.add(Duration(seconds: i)), accuracyMeters: 4);
      }

      // Within 1%: the residual is the flat-earth approximation in the test
      // helper, not the calculator.
      expect(calc.totalMeters, closeTo(1000, 10));
    });

    test('slow climbing is deferred across the radius, then banked in full', () {
      final calc = fresh();
      calc.add(origin, t0, accuracyMeters: 3);

      // 1 m/s = 3.6 km/h. Thirty seconds is 30 m, but the first 12 m sit
      // inside the radius before the anchor first moves.
      var point = origin;
      for (var i = 1; i <= 30; i++) {
        point = north(point, 1.0);
        calc.add(point, t0.add(Duration(seconds: i)), accuracyMeters: 3);
      }

      // Two full 12 m advances are banked; the remaining 6 m is still held by
      // the anchor and would be counted a few seconds later. Nothing is lost —
      // only deferred.
      expect(calc.totalMeters, closeTo(24, 1.5));

      for (var i = 31; i <= 40; i++) {
        point = north(point, 1.0);
        calc.add(point, t0.add(Duration(seconds: i)), accuracyMeters: 3);
      }
      expect(calc.totalMeters, closeTo(36, 1.5));
    });
  });

  group('rejection', () {
    test('a 500 m jump in one second is discarded', () {
      final calc = fresh();
      calc.add(origin, t0, accuracyMeters: 4);

      // 500 m/s. The spec's example of a fix that must never be counted.
      calc.add(north(origin, 500), t0.add(const Duration(seconds: 1)));
      expect(calc.totalMeters, 0);

      // ...and the anchor re-seats, so the ride continues from the new
      // position rather than from a stale one.
      final resumed = north(origin, 500);
      calc.add(north(resumed, 20), t0.add(const Duration(seconds: 5)));
      expect(calc.totalMeters, closeTo(20, 1.5));
    });

    test('a fix with a non-advancing timestamp is ignored', () {
      final calc = fresh();
      calc.add(origin, t0, accuracyMeters: 4);
      calc.add(north(origin, 20), t0); // same instant

      expect(calc.totalMeters, 0);
    });

    test('a timestamp that goes backwards is ignored', () {
      final calc = fresh();
      calc.add(origin, t0);
      calc.add(
        north(origin, 20),
        t0.subtract(const Duration(seconds: 5)),
        accuracyMeters: 4,
      );

      expect(calc.totalMeters, 0);
    });
  });

  group('restore', () {
    test('seeding resumes without inventing a segment across the gap', () {
      final calc = DistanceCalculator()
        ..seed(
          totalMeters: 5000,
          anchor: origin,
          anchorTime: t0,
        );

      // The rider resumes 800 m away after the app was closed for an hour.
      // That must not become 800 m of "distance" in the resumed ride.
      calc.add(
        north(origin, 800),
        t0.add(const Duration(hours: 1)),
      );

      expect(calc.totalMeters, 5000);
    });
  });

  group('urban multipath soft gate', () {
    test('heading/displacement disagreement with an accuracy spike holds the anchor', () {
      final calc = fresh();
      calc.add(origin, t0, accuracyMeters: 6);

      // Clear the radius north at good accuracy first so we have a banked
      // segment and a live heading reference.
      final along = north(origin, 20);
      expect(
        calc.add(
          along,
          t0.add(const Duration(seconds: 2)),
          accuracyMeters: 6,
          headingDegrees: 0, // north
        ),
        closeTo(20, 1.5),
      );

      // A sideways multipath jump: displacement is east (~90°), reported
      // course still says north, and accuracy spikes.
      final east = GeoPoint(along.lat, along.lng + 20 / 85000.0);
      final banked = calc.add(
        east,
        t0.add(const Duration(seconds: 4)),
        accuracyMeters: 22,
        headingDegrees: 0,
        previousAccuracyMeters: 6,
      );
      expect(banked, 0, reason: 'multipath must not move the anchor');
      expect(calc.totalMeters, closeTo(20, 1.5));
      expect(calc.anchor!.lat, closeTo(along.lat, 1e-6));
    });

    test('a real hard turn without an accuracy spike still banks', () {
      final calc = fresh();
      calc.add(origin, t0, accuracyMeters: 5);
      final northPoint = north(origin, 20);
      calc.add(
        northPoint,
        t0.add(const Duration(seconds: 2)),
        accuracyMeters: 5,
        headingDegrees: 0,
      );

      // Turn east: displacement ~90°, heading also ~90°, accuracy steady.
      final east = GeoPoint(northPoint.lat, northPoint.lng + 20 / 85000.0);
      final banked = calc.add(
        east,
        t0.add(const Duration(seconds: 4)),
        accuracyMeters: 6,
        headingDegrees: 90,
        previousAccuracyMeters: 5,
      );
      expect(banked, greaterThan(15));
    });

    test('looksLikeMultipath is false when either signal is missing', () {
      expect(
        DistanceCalculator.looksLikeMultipath(
          meters: 20,
          from: origin,
          to: north(origin, 20),
          headingDegrees: null,
          accuracyMeters: 22,
          previousAccuracyMeters: 6,
        ),
        isFalse,
      );
      expect(
        DistanceCalculator.looksLikeMultipath(
          meters: 20,
          from: origin,
          to: north(origin, 20),
          headingDegrees: 90,
          accuracyMeters: 22,
          previousAccuracyMeters: null,
        ),
        isFalse,
      );
    });
  });
}
