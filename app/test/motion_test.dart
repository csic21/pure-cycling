import 'dart:async';
import 'dart:math' as math;

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/motion_detector.dart';
import 'package:cycling_app/core/location/motion_source.dart';
import 'package:cycling_app/core/location/sampling_policy.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/domain/auto_pause.dart';
import 'package:cycling_app/features/ride/domain/ride_engine.dart';
import 'package:cycling_app/features/sensors/domain/sensor.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_harness.dart';

/// A motion sensor the test drives.
class FakeMotionSource implements MotionSource {
  FakeMotionSource({this.available = true});

  final bool available;
  final _controller = StreamController<MotionSample>.broadcast();

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<MotionSample> samples() {
    if (!available) {
      return Stream<MotionSample>.error(
        StateError('no accelerometer on this device'),
      );
    }
    return _controller.stream;
  }

  void emit(double magnitudeG) {
    if (_controller.isClosed) return;
    _controller.add(
      MotionSample(magnitudeG: magnitudeG, timestamp: DateTime.now().toUtc()),
    );
  }

  Future<void> dispose() => _controller.close();
}

void main() {
  final start = DateTime.utc(2026, 9, 28, 6);

  // ---- Synthetic signatures -------------------------------------------------
  //
  // Deterministic (a seeded generator), so a threshold that only just passes
  // today does not fail next week. The amplitudes are chosen to sit well
  // inside each band rather than near a boundary — a test that lives on the
  // threshold tests the threshold, not the behaviour.

  /// Acceleration at rest: gravity plus a few thousandths of a g of noise.
  final still = _Signature(amplitude: 0.005, seed: 7);

  /// A phone in a pocket or on a mount, on a rolling bicycle.
  final rolling = _Signature(amplitude: 0.07, seed: 11);

  group('the detector', () {
    test('a phone nobody is holding reads as still', () {
      final detector = MotionDetector();
      for (var i = 0; i < 60; i++) {
        detector.add(still.next(), start.add(Duration(milliseconds: i * 66)));
      }
      expect(detector.moving, isFalse);
      expect(detector.hasReading, isTrue);
    });

    test('a rolling bicycle reads as moving', () {
      final detector = MotionDetector();
      for (var i = 0; i < 60; i++) {
        detector.add(rolling.next(), start.add(Duration(milliseconds: i * 66)));
      }
      expect(detector.moving, isTrue);
    });

    test('it works the same however the phone is oriented', () {
      // The magnitude of the acceleration vector is 1 g at rest whichever way
      // up the phone is, which is why the platform reports that rather than
      // three axes: a stem mount, a jersey pocket and a bar bag all give the
      // same answer for the same road.
      for (final gravity in [0.98, 1.0, 1.03]) {
        final detector = MotionDetector();
        for (var i = 0; i < 60; i++) {
          detector.add(
            gravity + still.next() - 1.0,
            start.add(Duration(milliseconds: i * 66)),
          );
        }
        expect(detector.moving, isFalse, reason: '静止判定不能取决于手机怎么放的');
      }
    });

    test('one bump does not count as moving', () {
      final detector = MotionDetector();
      for (var i = 0; i < 30; i++) {
        detector.add(still.next(), start.add(Duration(milliseconds: i * 66)));
      }
      // A pothole: a single large sample, then still again.
      detector.add(1.6, start.add(const Duration(milliseconds: 2000)));
      expect(detector.moving, isFalse, reason: 'RMS 是对窗口取的，一个坑不该把判定翻过来');
    });

    test('enough history is required before the verdict counts', () {
      final detector = MotionDetector();
      detector.add(1.0, start);
      expect(detector.hasReading, isFalse, reason: '一个样本没有窗口可测，不能就此断定车是停着的');

      for (var i = 1; i < 6; i++) {
        detector.add(1.0, start.add(Duration(milliseconds: i * 66)));
      }
      expect(detector.hasReading, isTrue);
    });

    test('a non-finite sample does not decide the rest of the ride', () {
      final detector = MotionDetector();
      for (var i = 0; i < 30; i++) {
        detector.add(rolling.next(), start.add(Duration(milliseconds: i * 66)));
      }
      detector.add(double.nan, start.add(const Duration(milliseconds: 2000)));
      detector.add(
        rolling.next(),
        start.add(const Duration(milliseconds: 2066)),
      );

      expect(detector.moving, isTrue, reason: '一个 NaN 不能污染判定');
    });

    test('the gap between the thresholds is hysteresis, not noise', () {
      // A reading between the two thresholds keeps whatever the answer was:
      // that is the whole point of having two.
      final quiet = MotionDetector();
      for (var i = 0; i < 60; i++) {
        quiet.add(still.next(), start.add(Duration(milliseconds: i * 66)));
      }
      // Now a middling amplitude — not enough evidence to say "moving".
      final middling = _Signature(amplitude: 0.022, seed: 3);
      for (var i = 0; i < 60; i++) {
        quiet.add(
          middling.next(),
          start.add(Duration(milliseconds: 4000 + i * 66)),
        );
      }
      expect(quiet.moving, isFalse, reason: '证据不够就不改口');
    });
  });

  group('auto-pause', () {
    test('a confirmed stop pauses sooner than a speed reading alone', () {
      final alone = AutoPauseController();
      alone.update(0, start);
      expect(
        alone.update(0, start.add(const Duration(seconds: 2))),
        isFalse,
        reason: '只靠速度时要等满 5 秒',
      );
      expect(alone.update(0, start.add(const Duration(seconds: 5))), isTrue);

      final confirmed = AutoPauseController();
      confirmed.update(0, start, motionDetected: false);
      expect(
        confirmed.update(
          0,
          start.add(const Duration(seconds: 2)),
          motionDetected: false,
        ),
        isTrue,
        reason: '两个独立来源都说停了，就不用再等速度那 3 秒',
      );
    });

    test('"moving" neither pauses early nor prevents the pause', () {
      final controller = AutoPauseController();
      controller.update(0, start, motionDetected: true);
      expect(
        controller.update(
          0,
          start.add(const Duration(seconds: 2)),
          motionDetected: true,
        ),
        isFalse,
        reason: '传感器说「在动」是弱证据，不能让它把停车判定提前',
      );
      expect(
        controller.update(
          0,
          start.add(const Duration(seconds: 5)),
          motionDetected: true,
        ),
        isTrue,
        reason: '也不能让它阻止一次真实的停车（口袋里的振动不算骑车）',
      );
    });

    test('no sensor at all is exactly the old behaviour', () {
      final bare = AutoPauseController();
      final explicitNull = AutoPauseController();
      for (final seconds in [1, 2, 3, 4, 5, 6]) {
        final at = start.add(Duration(seconds: seconds));
        expect(
          explicitNull.update(0, at, motionDetected: null),
          bare.update(0, at),
          reason: '没有传感器和显式 null 必须走同一条路',
        );
      }
    });
  });

  group('the sampling policy', () {
    test('a confirmed stop relaxes the profile sooner', () {
      final alone = SamplingPolicy(chosen: GpsAccuracyMode.high);
      alone.update(speedMps: 0, at: start);
      expect(
        alone.update(speedMps: 0, at: start.add(const Duration(seconds: 10))),
        isFalse,
        reason: '只靠速度要等满 30 秒',
      );
      expect(
        alone.update(speedMps: 0, at: start.add(const Duration(seconds: 30))),
        isTrue,
      );

      final confirmed = SamplingPolicy(chosen: GpsAccuracyMode.high);
      confirmed.update(speedMps: 0, at: start, motionDetected: false);
      expect(
        confirmed.update(
          speedMps: 0,
          at: start.add(const Duration(seconds: 10)),
          motionDetected: false,
        ),
        isTrue,
        reason: '传感器已经把「停着」这件事说清楚了，没什么可等的',
      );
    });

    test('the sensor ends a relaxed spell the speed band would hide', () {
      final policy = SamplingPolicy(chosen: GpsAccuracyMode.high);
      policy.update(speedMps: 0, at: start);
      expect(
        policy.update(speedMps: 0, at: start.add(const Duration(seconds: 30))),
        isTrue,
      );
      expect(policy.isRelaxed, isTrue);

      // 2.5 km/h is inside the dead band, where speed alone decides nothing —
      // which is exactly the state it would otherwise sit in until the rider
      // got above 3 km/h.
      const crawl = 2.5 / 3.6;
      final movingAt = start.add(const Duration(seconds: 61));
      policy.update(speedMps: crawl, at: movingAt, motionDetected: true);
      expect(
        policy.update(
          speedMps: crawl,
          at: movingAt.add(const Duration(seconds: 5)),
          motionDetected: true,
        ),
        isTrue,
        reason: '速度分不清，但传感器说车在动',
      );
      expect(policy.isRelaxed, isFalse);
    });

    test('the sensor never upgrades past what the rider chose', () {
      final policy = SamplingPolicy(chosen: GpsAccuracyMode.batterySaver);
      policy.update(speedMps: 5, at: start, motionDetected: true);
      expect(
        policy.effective,
        GpsAccuracyMode.batterySaver,
        reason: '选了省电的人不会因为「在动」被悄悄升级',
      );
    });
  });

  group('the engine', () {
    void armThenStop(RideEngine engine) {
      engine.onSensorReading(
        SensorReading(type: SensorType.speed, value: 14.4, timestamp: start),
      );
      engine.onSensorReading(
        SensorReading(type: SensorType.speed, value: 0, timestamp: start),
      );
    }

    /// Runs a started engine on a clock and timer queue the test controls.
    void withRidingEngine(
      void Function(RideEngine engine, void Function(Duration) advance) body,
    ) {
      fakeAsync((async) {
        var now = start;
        final engine = RideEngine(now: () => now);
        engine.start();
        engine.beginRecording();
        body(engine, (d) {
          now = now.add(d);
          async.elapse(d);
        });
        unawaited(engine.dispose());
        async.flushTimers();
      });
    }

    test('the verdict reaches the state and expires on its own', () {
      withRidingEngine((engine, advance) {
        expect(
          engine.state.motionDetected,
          isNull,
          reason: '还没有读数时说「不知道」，而不是「没动」',
        );

        for (var i = 0; i < 20; i++) {
          advance(const Duration(milliseconds: 66));
          engine.onMotionSample(rolling.next());
        }
        expect(engine.state.motionDetected, isTrue);

        // The sensor stream dies. A verdict about ten seconds ago must not go
        // on being repeated: auto-pause would freeze in whatever state it was
        // in when the stream stopped.
        advance(const Duration(seconds: 10));
        expect(engine.state.motionDetected, isNull);
      });
    });

    test('a confirmed stop pauses in two seconds, not five', () {
      withRidingEngine((engine, advance) {
        // A real movement arms auto-pause; a wheel reading confirms the stop.
        armThenStop(engine);
        for (var i = 0; i < 45; i++) {
          advance(const Duration(milliseconds: 66));
          engine.onMotionSample(still.next());
        }
        expect(engine.state.autoPaused, isTrue, reason: '传感器确认停着，就不必再等速度那 5 秒');
      });
    });

    test('a motion reading never resumes a stop on its own', () {
      withRidingEngine((engine, advance) {
        armThenStop(engine);
        for (var i = 0; i < 45; i++) {
          advance(const Duration(milliseconds: 66));
          engine.onMotionSample(still.next());
        }
        expect(engine.state.autoPaused, isTrue);

        // The phone is now being shaken — an engine idling beside a parked
        // bike, a rack rattling, a rider fidgeting. Six seconds of it, with
        // the receiver still saying nothing.
        for (var i = 0; i < 90; i++) {
          advance(const Duration(milliseconds: 66));
          engine.onMotionSample(rolling.next());
        }

        expect(
          engine.state.autoPaused,
          isTrue,
          reason:
              '振动不能说明骑手出发了；恢复仍然要等速度，'
              '否则一辆停着的车就能把整段骑行卡在 riding 状态',
        );
      });
    });

    test('no speed source never auto-pauses the new ride', () {
      withRidingEngine((engine, advance) {
        for (var i = 0; i < 120; i++) {
          advance(const Duration(milliseconds: 66));
          engine.onMotionSample(still.next());
        }
        expect(engine.state.status, RideStatus.riding);
        expect(engine.state.autoPaused, isFalse);
        expect(engine.state.speedAvailable, isFalse);
      });
    });
  });

  group('the recorder wiring', () {
    late AppDatabase database;

    setUp(() => database = openTestDatabase());
    tearDown(() => database.close());

    test('motion readings reach the ride state', () async {
      final location = FakeLocationService();
      final motion = FakeMotionSource();
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        motion: motion,
      );

      await recorder.startRide(const AppSettings());
      await recorder.beginRecording();

      for (var i = 0; i < 20; i++) {
        motion.emit(rolling.next());
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        recorder.state.motionDetected,
        isTrue,
        reason: '运动读数要进 RideState，而不是只到引擎就停了',
      );

      await recorder.dispose();
      await motion.dispose();
      await location.dispose();
    });

    test('a device with no accelerometer is not an error', () async {
      final location = FakeLocationService();
      final motion = FakeMotionSource(available: false);
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        motion: motion,
      );

      expect(await recorder.startRide(const AppSettings()), isTrue);
      await recorder.beginRecording();
      location.emitRide(count: 20, speedMps: 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(recorder.state.motionDetected, isNull);
      final ride = await recorder.stopRide();
      expect(ride, isNotNull);
      expect(ride!.stats.distanceMeters, greaterThan(0));

      await recorder.dispose();
      await motion.dispose();
      await location.dispose();
    });
  });
}

/// A deterministic acceleration signature around 1 g.
///
/// Uniform noise of amplitude ±[amplitude], which is what the thresholds in
/// `MotionDetector` are documented against: its RMS is `amplitude/√3`.
class _Signature {
  _Signature({required this.amplitude, required int seed})
    : _random = math.Random(seed);

  final double amplitude;
  final math.Random _random;

  double next() => 1.0 + (_random.nextDouble() * 2 - 1) * amplitude;
}
