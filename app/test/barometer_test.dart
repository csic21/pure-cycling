import 'dart:async';
import 'dart:math' as math;

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/barometer_source.dart';
import 'package:cycling_app/core/location/elevation_tuning.dart';
import 'package:cycling_app/core/location/gps_filter.dart';
import 'package:cycling_app/core/location/location_fix.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/ride_engine.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_harness.dart';

/// A barometer that answers from a list the test controls.
class FakeBarometerSource implements BarometerSource {
  FakeBarometerSource({this.available = true});

  final bool available;
  final _controller = StreamController<double>.broadcast();

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<BarometerSample> samples() {
    if (!available) {
      return Stream<BarometerSample>.error(
        StateError('no barometer on this device'),
      );
    }

    double? reference;
    return _controller.stream.map((pressure) {
      reference ??= pressure;
      return BarometerSample(
        pressureHpa: pressure,
        timestamp: DateTime.now().toUtc(),
        relativeAltitudeMeters: BarometricAltitude.deltaMeters(
          pressureHpa: pressure,
          referenceHpa: reference!,
        ),
      );
    });
  }

  void emitPressure(double hPa) {
    if (!_controller.isClosed) _controller.add(hPa);
  }

  /// Pushes a reading that means [meters] above the first sample, by inverting
  /// the barometric formula — the same numbers the platform would produce for
  /// a ride that climbed exactly that much.
  void emitClimb(double meters, {int steps = 1, double reference = 1000.0}) {
    // From zero: a real stream defines its own reference with its first
    // reading, so the first sample is the baseline, not one step up from it.
    for (var i = 0; i <= steps; i++) {
      final height = meters * i / steps;
      final ratio = 1 - height / 44330.0;
      emitPressure(reference * math.pow(ratio, 1 / 0.1903).toDouble());
    }
  }

  Future<void> dispose() => _controller.close();
}

void main() {
  group('the arithmetic', () {
    test('a 100 m climb is 100 m, to within a rounding of the reference', () {
      // 1000 hPa at the reference is roughly sea level on a standard day.
      // 100 m higher is about 11.9 hPa less.
      final delta = BarometricAltitude.deltaMeters(
        pressureHpa: 988.1,
        referenceHpa: 1000.0,
      );
      expect(delta, closeTo(100, 1.5));
    });

    test('no change in pressure is no change in height', () {
      expect(
        BarometricAltitude.deltaMeters(pressureHpa: 1013, referenceHpa: 1013),
        0,
      );
    });

    test('a nonsense pressure is treated as no movement, not as infinity', () {
      expect(
        BarometricAltitude.deltaMeters(pressureHpa: 0, referenceHpa: 1000),
        0,
      );
      expect(
        BarometricAltitude.deltaMeters(pressureHpa: -5, referenceHpa: 1000),
        0,
      );
    });
  });

  group('the filter', () {
    test('a barometric series takes over the altitude and the quality', () {
      final filter = GpsFilter();
      final at = DateTime.utc(2026, 9, 25, 6);

      // A GPS fix with a poor vertical accuracy — the case that produces
      // phantom climbing.
      filter.process(
        LocationFix(
          latitude: 39.9,
          longitude: 116.4,
          timestamp: at,
          accuracy: 5,
          altitude: 50,
          altitudeAccuracy: 20,
        ),
      );
      expect(filter.tuning.quality, ElevationQuality.approximate);

      filter.onBarometricAltitude(50, at: at);

      expect(filter.barometerActive, isTrue);
      expect(
        filter.tuning.quality,
        ElevationQuality.precise,
        reason: '气压计接管后，爬升不再是估算值',
      );
      expect(filter.tuning.gainThresholdMeters, 2);

      // The GPS series is still tracked, so it can take over again.
      expect(filter.gpsSmoothedAltitude, 50);
    });

    test('a gentle continuous climb is followed, not stalled', () {
      // 0.05 m per sample: a deadband like the GPS path's would freeze this
      // forever, which is why the barometric path has none.
      final filter = GpsFilter();
      final at = DateTime.utc(2026, 9, 25, 6);
      filter.onBarometricAltitude(0, at: at);
      for (var i = 1; i <= 200; i++) {
        filter.onBarometricAltitude(
          i * 0.05,
          at: at.add(Duration(milliseconds: i * 200)),
        );
      }

      expect(
        filter.smoothedAltitude,
        closeTo(10, 0.5),
        reason: '10 米的缓坡必须跟得上',
      );
    });

    test('a barometer that goes quiet hands the altitude back to GPS', () {
      final filter = GpsFilter();
      final first = DateTime.utc(2026, 9, 25, 6);

      filter.process(
        LocationFix(
          latitude: 39.9,
          longitude: 116.4,
          timestamp: first,
          accuracy: 5,
          altitude: 50,
          altitudeAccuracy: 20,
        ),
      );
      filter.onBarometricAltitude(50, at: first);
      expect(filter.tuning.quality, ElevationQuality.precise);

      // Fifteen seconds without a reading, then a fix. The barometer is gone;
      // the estimate has to go back to what GPS can support.
      filter.process(
        LocationFix(
          latitude: 39.9005,
          longitude: 116.4,
          timestamp: first.add(const Duration(seconds: 20)),
          accuracy: 5,
          altitude: 52,
          altitudeAccuracy: 20,
        ),
      );

      expect(filter.barometerActive, isFalse);
      expect(filter.tuning.quality, ElevationQuality.approximate);
      expect(filter.smoothedAltitude, isNotNull);
    });

    test('track points carry the barometric accuracy while it is in force', () {
      final filter = GpsFilter();
      final fix = LocationFix(
        latitude: 39.9,
        longitude: 116.4,
        timestamp: DateTime.utc(2026, 9, 25, 6),
        accuracy: 5,
        altitude: 50,
        altitudeAccuracy: 20,
      );

      filter.process(fix);
      filter.onBarometricAltitude(50, at: fix.timestamp);
      final processed = filter.process(
        LocationFix(
          latitude: 39.9005,
          longitude: 116.4,
          timestamp: DateTime.utc(2026, 9, 25, 6, 0, 1),
          accuracy: 5,
          altitude: 50,
          altitudeAccuracy: 20,
        ),
      );

      expect(processed.altitudeAccuracyMeters, ElevationTuning.barometerAccuracyMeters);

      // Without one, the fix's own figure is what the point carries.
      final gpsOnly = GpsFilter().process(fix);
      expect(gpsOnly.altitudeAccuracyMeters, 20);
    });
  });

  group('the engine', () {
    /// Runs a started engine on a clock the test controls.
    ///
    /// The engine's ticker, auto-pause and signal-loss reporting all run off
    /// timers, so a test that feeds it fixes without moving both the wall
    /// clock and the timer queue is not testing the engine that ships — the
    /// same reasoning as `ride_engine_test.dart`.
    void withRidingEngine(
      void Function(
        RideEngine engine,
        void Function(Duration) advance,
        DateTime Function() clock,
      ) body,
    ) {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 9, 25, 6);
        final engine = RideEngine(config: const RideEngineConfig(), now: () => now);
        engine.start();
        engine.beginRecording();
        body(engine, (d) {
          now = now.add(d);
          async.elapse(d);
        }, () => now);
        // The ticker reschedules itself, so the queue never drains on its own;
        // `dispose` cancels it synchronously (the same reason `ride_engine_test`
        // disposes before flushing).
        unawaited(engine.dispose());
        async.flushTimers();
      });
    }

    /// A fix [meters] north of [origin], one second after the previous.
    LocationFix fixAt(
      double meters,
      DateTime timestamp, {
      double altitude = 100,
      double altitudeAccuracy = 18,
      double accuracy = 4,
    }) =>
        LocationFix(
          latitude: 39.9 + meters / 111132.0,
          longitude: 116.4,
          timestamp: timestamp,
          accuracy: accuracy,
          altitude: altitude,
          altitudeAccuracy: altitudeAccuracy,
          speed: 5,
        );

    test('a synthetic 120 m climb is measured, not estimated', () {
      withRidingEngine((engine, advance, clock) {
        engine.onLocation(fixAt(0, clock()));

        // From the baseline (0 m) up 120 m, in 60 readings of 2 m.
        engine.onBarometricAltitude(0);
        for (var i = 1; i <= 60; i++) {
          advance(const Duration(milliseconds: 200));
          engine.onBarometricAltitude(2.0 * i);
        }

        // Two metres below the summit, on purpose: the filter's lag is one
        // sample's worth, so a total read *during* a hard climb is short by
        // that much. Hold at the top and it converges — which is the property
        // that matters, because the rider reads the number at the end.
        for (var i = 0; i < 10; i++) {
          advance(const Duration(milliseconds: 200));
          engine.onBarometricAltitude(120.0);
        }

        final stats = engine.state.stats;
        expect(
          stats.elevationGainMeters,
          closeTo(120, 1.5),
          reason: '气压计测到的爬升应当完整入账',
        );
        expect(engine.elevationQuality, ElevationQuality.precise);
      });
    });

    test('a climb between two fixes is still counted', () {
      // The tunnel case, which is the one a barometer exists for: GPS says
      // nothing at all for a while, the phone keeps climbing.
      withRidingEngine((engine, advance, clock) {
        engine.onLocation(fixAt(0, clock()));

        engine.onBarometricAltitude(0);
        for (var i = 1; i <= 50; i++) {
          advance(const Duration(milliseconds: 200));
          engine.onBarometricAltitude(1.0 * i);
        }
        advance(const Duration(seconds: 2));
        engine.onBarometricAltitude(50);

        expect(
          engine.state.stats.elevationGainMeters,
          closeTo(50, 1.5),
          reason: '两次定位之间没有采样，但爬升确实发生了',
        );
      });
    });

    test('a flat road with a drifting GPS altitude does not invent climbing',
        () {
      withRidingEngine((engine, advance, clock) {
        engine.onLocation(fixAt(0, clock(), altitude: 100));

        // Twenty minutes of steady riding while the GPS altitude wanders ±8 m
        // — the case that produces 15–32 m of phantom climbing on a GPS-only
        // phone.
        var travelled = 0.0;
        for (var second = 1; second <= 1200; second++) {
          travelled += 5;
          advance(const Duration(seconds: 1));
          engine.onLocation(
            fixAt(travelled, clock(), altitude: 100 + 8 * math.sin(second / 60)),
          );
          // The barometer holds still, with a centimetre of noise.
          for (var i = 0; i < 5; i++) {
            engine.onBarometricAltitude(math.sin(second + i / 5) * 0.01);
          }
        }

        expect(
          engine.state.stats.elevationGainMeters,
          lessThan(5),
          reason: '气压计在场时，平路不该虚报爬升',
        );
        expect(engine.elevationQuality, ElevationQuality.precise);
      });
    });

    test('without a barometer nothing changes', () {
      withRidingEngine((engine, advance, clock) {
        engine.onLocation(fixAt(0, clock()));

        expect(engine.elevationQuality, ElevationQuality.approximate);
        expect(engine.state.stats.altitudeMeters, 100);
      });
    });
  });

  group('the recorder wiring', () {
    late AppDatabase database;

    setUp(() => database = openTestDatabase());
    tearDown(() => database.close());

    test('barometric readings reach the engine and the stored trace', () async {
      final location = FakeLocationService();
      final barometer = FakeBarometerSource();
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        barometer: barometer,
      );

      await recorder.startRide(const AppSettings());
      await recorder.beginRecording();

      final t0 = DateTime.now().toUtc();
      location.emitRide(count: 10, speedMps: 5, start: t0);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 100 m of climbing, in twenty readings, with GPS left flat.
      barometer.emitClimb(100, steps: 20);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Fixes keep arriving during a real climb; the trailing ones are what
      // carry the barometric altitude into the trace.
      location.emitRide(
        count: 10,
        speedMps: 5,
        start: t0.add(const Duration(seconds: 10)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final ride = await recorder.stopRide();
      expect(
        ride!.stats.elevationGainMeters,
        greaterThan(90),
        reason: '100 米的爬升要基本完整入账',
      );

      final points = await database.rideDao.getTrackPoints(ride.id);
      expect(
        points.where((p) => p.verticalAccuracy == ElevationTuning.barometerAccuracyMeters),
        isNotEmpty,
        reason: '带气压计的轨迹点要带上气压计的精度，否则详情页会把它标成估算',
      );

      await recorder.dispose();
      await barometer.dispose();
      await location.dispose();
    });

    test('a device with no barometer is not an error', () async {
      final location = FakeLocationService();
      final barometer = FakeBarometerSource(available: false);
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        barometer: barometer,
      );

      expect(await recorder.startRide(const AppSettings()), isTrue);
      await recorder.beginRecording();
      location.emitRide(count: 20, speedMps: 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final Ride? ride = await recorder.stopRide();
      expect(ride, isNotNull);
      expect(ride!.stats.distanceMeters, greaterThan(0));

      await recorder.dispose();
      await barometer.dispose();
      await location.dispose();
    });
  });
}
