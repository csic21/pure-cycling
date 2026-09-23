import 'dart:math' as math;

import 'package:cycling_app/core/location/gps_filter.dart';
import 'package:cycling_app/core/location/location_fix.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/ride/domain/elevation_accumulator.dart';
import 'package:flutter_test/flutter_test.dart';

/// A measurement probe, not a specification.
///
/// This file exists to put numbers on a question that is otherwise argued from
/// intuition: **how much phantom climbing does a phone without a barometer
/// report, and what does suppressing it cost on a real climb?**
///
/// It drives the real filter and the real accumulator with synthetic altitude
/// series matching each source's published noise characteristics, so the
/// answer comes from shipped code rather than from a model of it. The numbers
/// it prints are what the thresholds in `ElevationTuning` were chosen from.
void main() {
  const origin = GeoPoint(39.9042, 116.4074);

  /// Runs a ride and returns the elevation gain the app would report.
  ///
  /// [altitude] produces the raw altitude for each sample. The ride is 5 m/s
  /// at 1 Hz, so 1800 samples is 9 km.
  double measuredGain({
    required double Function(int sample) altitude,
    required double verticalAccuracy,
    int samples = 1800,
  }) {
    final filter = GpsFilter();
    final accumulator = ElevationAccumulator();

    var t = DateTime.utc(2026, 9, 23, 6);
    var travelled = 0.0;

    for (var i = 0; i < samples; i++) {
      t = t.add(const Duration(seconds: 1));
      travelled += 5;

      final fix = LocationFix(
        latitude: origin.lat + travelled / 111132.0,
        longitude: origin.lng,
        timestamp: t,
        altitude: altitude(i),
        altitudeAccuracy: verticalAccuracy,
        accuracy: 4,
        speed: 5,
      );

      final processed = filter.process(fix);
      if (processed.accepted && processed.altitudeMeters != null) {
        final tuning = filter.tuning;
        accumulator.thresholdMeters = tuning.gainThresholdMeters;
        accumulator.add(processed.altitudeMeters!);
      }
    }

    return accumulator.gainMeters;
  }

  /// Slow vertical drift, the failure mode that no filter can remove.
  ///
  /// Satellite geometry changes over tens of minutes and the error wanders
  /// with it. It occupies exactly the same frequency band as a real climb.
  double drift(int i, double amplitude) =>
      amplitude * math.sin(i / 900.0 * math.pi);

  double white(int i, double amplitude, int seed) {
    final random = math.Random(seed);
    var value = 0.0;
    for (var n = 0; n <= i; n++) {
      value = (random.nextDouble() - 0.5) * amplitude;
    }
    return value;
  }

  void report(String label, double gain) {
    // ignore: avoid_print
    print('  ${label.padRight(46)} ${gain.toStringAsFixed(1).padLeft(7)} m');
  }

  test('probe: phantom climbing on a flat road', () {
    // ignore: avoid_print
    print('\nFLAT 9 km — anything above zero is invented');

    report(
      'barometer (±0.2 m white)',
      measuredGain(
        altitude: (i) => 50 + white(i, 0.4, 7),
        verticalAccuracy: 1.5,
      ),
    );
    report(
      'GPS-only, open sky (±4 m + 12 m drift)',
      measuredGain(
        altitude: (i) => 50 + white(i, 8, 7) + drift(i, 12),
        verticalAccuracy: 15,
      ),
    );
    report(
      'GPS-only, urban canyon (±8 m + 25 m drift)',
      measuredGain(
        altitude: (i) => 50 + white(i, 16, 7) + drift(i, 25),
        verticalAccuracy: 35,
      ),
    );
  });

  test('probe: a real 300 m climb', () {
    // 300 m over 30 minutes at 5 m/s — a real alpine pass, not a roller.
    double climb(int i) {
      final progress = i / 1800.0;
      return 50 + 300 * progress;
    }

    // ignore: avoid_print
    print('\nREAL CLIMB 300 m — anything below 300 is lost');

    report(
      'barometer (±0.2 m white)',
      measuredGain(
        altitude: (i) => climb(i) + white(i, 0.4, 7),
        verticalAccuracy: 1.5,
      ),
    );
    report(
      'GPS-only, open sky (±4 m + 12 m drift)',
      measuredGain(
        altitude: (i) => climb(i) + white(i, 8, 7) + drift(i, 12),
        verticalAccuracy: 15,
      ),
    );
    report(
      'GPS-only, urban canyon (±8 m + 25 m drift)',
      measuredGain(
        altitude: (i) => climb(i) + white(i, 16, 7) + drift(i, 25),
        verticalAccuracy: 35,
      ),
    );
  });

  test('probe: rolling terrain, 20 m rollers', () {
    // The case where a high threshold costs the most: a river path with
    // repeated short rises. Ten rollers of 20 m is 200 m of real gain.
    double rolling(int i) => 50 + 20 * (1 - math.cos(i / 90.0 * math.pi)) / 2;

    // ignore: avoid_print
    print('\nROLLING 10 × 20 m rollers — truth is 200 m');

    report(
      'barometer (±0.2 m white)',
      measuredGain(
        altitude: (i) => rolling(i) + white(i, 0.4, 7),
        verticalAccuracy: 1.5,
      ),
    );
    report(
      'GPS-only, open sky (±4 m + 12 m drift)',
      measuredGain(
        altitude: (i) => rolling(i) + white(i, 8, 7),
        verticalAccuracy: 15,
      ),
    );
  });
}
