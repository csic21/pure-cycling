import 'dart:math' as math;

import 'package:cycling_app/core/location/elevation_tuning.dart';
import 'package:cycling_app/features/ride/domain/elevation_accumulator.dart';
import 'package:flutter_test/flutter_test.dart';

/// The climb total is the number riders compare with each other, and the one
/// most easily ruined by a filter that looks reasonable.
///
/// Two of the tests below are regressions for bugs that were found by
/// measurement rather than by reading the code — see
/// `test/elevation_noise_probe_test.dart`. Both were silent: the accumulator
/// simply reported a wrong number, with nothing to indicate anything was
/// wrong.
void main() {
  /// Feeds a series of altitude samples.
  double gainOf(List<double> series, {double threshold = 2.0}) {
    final accumulator = ElevationAccumulator(thresholdMeters: threshold);
    for (final altitude in series) {
      accumulator.add(altitude);
    }
    return accumulator.gainMeters;
  }

  double lossOf(List<double> series, {double threshold = 2.0}) {
    final accumulator = ElevationAccumulator(thresholdMeters: threshold);
    for (final altitude in series) {
      accumulator.add(altitude);
    }
    return accumulator.lossMeters;
  }

  group('plain climbing and descending', () {
    test('a monotonic climb is counted in full', () {
      // 0 → 300 m, one metre per sample.
      final climb = [for (var i = 0; i <= 300; i++) i.toDouble()];

      expect(gainOf(climb), closeTo(300, 0.001));
      expect(lossOf(climb), 0);
    });

    test('a climb in progress is reported while it is happening', () {
      // A dashboard that read zero for the whole ascent and then jumped would
      // be worse than useless on a mountain pass.
      final accumulator = ElevationAccumulator(thresholdMeters: 2);

      for (var i = 0; i <= 50; i++) {
        accumulator.add(i.toDouble());
      }

      expect(accumulator.gainMeters, closeTo(50, 0.001));
    });

    test('a monotonic descent is counted as loss, not as climbing', () {
      final descent = [for (var i = 300; i >= 0; i--) i.toDouble()];

      expect(lossOf(descent), closeTo(300, 0.001));
      expect(gainOf(descent), 0);
    });

    test('a there-and-back ride counts each direction once', () {
      // Climb 200 m, descend 200 m. Not 400 m of climbing.
      final series = [
        for (var i = 0; i <= 200; i++) i.toDouble(),
        for (var i = 199; i >= 0; i--) i.toDouble(),
      ];

      expect(gainOf(series), closeTo(200, 0.001));
      // The final descent is still in progress at the end, and is counted.
      expect(lossOf(series), closeTo(200, 0.001));
    });
  });

  group('regression: rolling terrain must not stall', () {
    test('oscillation near the threshold counts every roller', () {
      // This is the case that broke the original thresholded-reference design.
      //
      // The series starts at 50, rises to 67, then oscillates between 53 and
      // 67 — a swing of 14 m against a threshold of 12. The old design banked
      // one 12 m climb and then parked: with the reference at 62, neither 67
      // (five metres away) nor 53 (nine) ever pulled away from it again, and
      // the accumulator reported 12 m for the rest of the ride.
      final series = <double>[50];
      for (var i = 0; i <= 66; i++) {
        series.add((50 + i).toDouble());
      }
      for (var cycle = 0; cycle < 10; cycle++) {
        for (var i = 65; i >= 53; i--) {
          series.add(i.toDouble());
        }
        for (var i = 54; i <= 67; i++) {
          series.add(i.toDouble());
        }
      }

      final gain = gainOf(series, threshold: 12);

      expect(
        gain,
        greaterThan(100),
        reason: 'rolling terrain must accumulate roller by roller, not stall',
      );
    });

    test('a river path of ten rollers is reported close to its true gain', () {
      // Ten 20 m rollers is 200 m of real climbing.
      final series = <double>[];
      for (var cycle = 0; cycle < 10; cycle++) {
        for (var i = 0; i <= 180; i++) {
          // Half a sine: up 20 m and back down.
          series.add(50 + 20 * (1 - math.cos(i / 90.0 * math.pi)) / 2);
        }
      }

      final gain = gainOf(series, threshold: 4);

      expect(gain, greaterThan(170));
      expect(gain, lessThan(210));
    });
  });

  group('noise suppression', () {
    test('sub-threshold wiggles on flat ground count nothing', () {
      // A ±0.4 m wander — a metre of peak-to-trough — against a 2 m
      // threshold. The reversal is never confirmed, so nothing is banked.
      final series = [
        for (var i = 0; i < 600; i++) 50 + (i.isEven ? 0.4 : -0.4),
      ];

      expect(gainOf(series), 0);
    });

    test('a wiggle larger than the threshold is counted, and that is correct',
        () {
      // ±1.5 m against a 2 m threshold is a 3 m peak-to-trough swing, which
      // *does* confirm a reversal. The accumulator is not wrong to count it:
      // confirming a reversal is exactly what it is for, and the threshold is
      // what defines "confirmed".
      //
      // Keeping this out of a real climb total is the filter's job, not the
      // accumulator's — smoothing shrinks the smoothed series' swing well
      // below the threshold. See `test/elevation_noise_probe_test.dart`,
      // which measures the whole pipeline end to end.
      final series = [
        for (var i = 0; i < 600; i++) 50 + (i.isEven ? 1.5 : -1.5),
      ];

      expect(gainOf(series), greaterThan(100));
    });

    test('a rock-steady signal counts nothing at all', () {
      expect(gainOf(List.filled(500, 100.0)), 0);
      expect(lossOf(List.filled(500, 100.0)), 0);
    });

    test('a non-finite sample is ignored rather than poisoning the total', () {
      final accumulator = ElevationAccumulator(thresholdMeters: 2);
      accumulator.add(50);
      accumulator.add(double.nan);
      accumulator.add(double.infinity);

      expect(accumulator.gainMeters, 0);
      expect(accumulator.gainMeters.isFinite, isTrue);

      accumulator.add(120);
      expect(accumulator.gainMeters, closeTo(70, 0.001));
    });
  });

  group('threshold changes mid-ride', () {
    test('reseeding neither creates nor destroys climbing', () {
      final accumulator = ElevationAccumulator(thresholdMeters: 2);
      for (var i = 0; i <= 100; i++) {
        accumulator.add(i.toDouble());
      }

      final before = accumulator.gainMeters;

      // The receiver's reported accuracy crossed a bucket boundary and the
      // threshold loosened. The reference has to move with it, or the
      // difference between the two thresholds is banked as terrain.
      accumulator.thresholdMeters = 20;
      accumulator.reseed(100);

      expect(accumulator.gainMeters, closeTo(before, 0.001));
    });

    test('climbing continues correctly after a reseed', () {
      final accumulator = ElevationAccumulator(thresholdMeters: 2);
      for (var i = 0; i <= 100; i++) {
        accumulator.add(i.toDouble());
      }

      accumulator.thresholdMeters = 20;
      accumulator.reseed(100);

      for (var i = 101; i <= 200; i++) {
        accumulator.add(i.toDouble());
      }

      expect(accumulator.gainMeters, closeTo(200, 0.001));
    });
  });

  group('crash recovery', () {
    test('seeding restores the totals without double-counting', () {
      final accumulator = ElevationAccumulator(thresholdMeters: 2)
        ..seed(gain: 340, loss: 120, referenceAltitude: 500);

      expect(accumulator.gainMeters, closeTo(340, 0.001));
      expect(accumulator.lossMeters, closeTo(120, 0.001));

      // The ride resumes mid-climb from the checkpoint altitude.
      for (var i = 1; i <= 50; i++) {
        accumulator.add(500 + i.toDouble());
      }

      expect(
        accumulator.gainMeters,
        closeTo(390, 0.001),
        reason: 'only the new climbing is added, not the banked 340 m again',
      );
    });
  });

  group('elevation tuning', () {
    test('a barometer gets a tight threshold', () {
      final tuning = ElevationTuning.forVerticalAccuracy(1.5);

      expect(tuning.quality, ElevationQuality.precise);
      expect(tuning.gainThresholdMeters, 2);
      expect(tuning.quality.isApproximate, isFalse);
    });

    test('GPS-only gets a threshold scaled to its accuracy', () {
      // The threshold has to track the reported error, because that is the
      // scale of the drift it is trying to reject.
      expect(ElevationTuning.forVerticalAccuracy(12).gainThresholdMeters, 12);
      expect(ElevationTuning.forVerticalAccuracy(15).gainThresholdMeters, 15);
      expect(ElevationTuning.forVerticalAccuracy(25).gainThresholdMeters, 25);
    });

    test('a GPS-only source is marked as an estimate', () {
      // The rider needs to know that a climb total from a phone without a
      // barometer is an estimate, not a measurement.
      expect(
        ElevationTuning.forVerticalAccuracy(15).quality.isApproximate,
        isTrue,
      );
      // Up to ±12 m the figure is good enough to present without a caveat.
      expect(
        ElevationTuning.forVerticalAccuracy(12).quality.isApproximate,
        isFalse,
      );
    });

    test('a hopeless receiver is capped and marked approximate', () {
      final tuning = ElevationTuning.forVerticalAccuracy(80);

      expect(tuning.gainThresholdMeters, 30);
      expect(tuning.quality, ElevationQuality.approximate);
    });

    test('an unreported accuracy is treated as the pessimistic case', () {
      // Android returns 0 when it has no vertical accuracy estimate, and iOS
      // returns a negative value when the altitude is invalid. Both mean "no
      // idea", and the safe reading of "no idea" is GPS-only — not barometer.
      for (final unknown in <double?>[null, 0, -1]) {
        final tuning = ElevationTuning.forVerticalAccuracy(unknown);

        expect(
          tuning.quality,
          ElevationQuality.approximate,
          reason: 'unknown accuracy must not be treated as a good one',
        );
        expect(tuning.gainThresholdMeters, greaterThanOrEqualTo(10));
        expect(tuning.quality.isApproximate, isTrue);
      }
    });

    test('the barometer threshold is an order of magnitude tighter than '
        'GPS-only', () {
      // This ratio is the whole reason the tuning exists: one number cannot
      // serve both sources.
      final barometric = ElevationTuning.forVerticalAccuracy(2);
      final gpsOnly = ElevationTuning.forVerticalAccuracy(20);

      expect(
        gpsOnly.gainThresholdMeters / barometric.gainThresholdMeters,
        greaterThan(5),
      );
    });
  });
}
