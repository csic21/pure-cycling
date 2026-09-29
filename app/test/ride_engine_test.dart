import 'package:cycling_app/core/location/location_fix.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/ride_engine.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:cycling_app/features/sensors/domain/sensor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// The engine is the part of this app that has to be right. Everything else
/// can be fixed in an update; a ride that records the wrong distance, or drops
/// its trace when the screen locks, has already cost the rider the thing they
/// opened the app for.
///
/// These tests drive it with synthetic fixes on a controllable wall clock
/// **and** a controllable timer queue. Both matter: the engine reads position
/// timestamps off the wall clock and drives its ticker, auto-pause and
/// signal-loss reporting off real `Timer`s, so a test that advances one
/// without the other is not testing the engine that ships.
void main() {
  const origin = GeoPoint(39.9042, 116.4074);

  /// A fix [meters] north of [from]. 111,132 m per degree of latitude, so the
  /// inverse is exact enough for synthetic input.
  LocationFix fixAt(
    GeoPoint from,
    double meters,
    DateTime timestamp, {
    double accuracy = 4,
    double? speed,
    double? altitude,
  }) {
    return LocationFix(
      latitude: from.lat + meters / 111132.0,
      longitude: from.lng,
      timestamp: timestamp,
      accuracy: accuracy,
      speed: speed,
      altitude: altitude,
    );
  }

  /// Runs [body] with a fake clock and a fake timer queue, both moving
  /// together through the `advance` helper.
  void withRide(
    void Function(
      void Function(Duration) advance,
      DateTime Function() clock,
      void Function(Duration) starveTimers,
    )
    body,
  ) {
    fakeAsync((async) {
      var now = DateTime.utc(2026, 9, 23, 6);
      body(
        (d) {
          now = now.add(d);
          async.elapse(d);
        },
        () => now,
        // Moves the wall clock *without* running the timer queue, which is
        // what happens when the OS suspends or throttles a backgrounded
        // process: time passes, callbacks do not fire.
        (d) => now = now.add(d),
      );
      async.flushTimers();
    });
  }

  /// Creates an engine already in the `riding` state.
  ///
  /// `start()` and `beginRecording()` have no awaits in their bodies, so both
  /// complete synchronously inside the fake zone.
  RideEngine startRiding({
    required DateTime Function() clock,
    RideEngineConfig config = const RideEngineConfig(),
    List<TrackPoint>? points,
  }) {
    final engine = RideEngine(
      config: config,
      now: clock,
      onTrackPoint: (p) => points?.add(p),
    );
    engine.start();
    engine.beginRecording();
    return engine;
  }

  /// Drives a straight ride at [speedMps], one fix per second, and returns the
  /// total distance travelled.
  ///
  /// Returning the distance rather than the position is deliberate: a
  /// follow-on segment must start from where the previous one stopped. Feeding
  /// a resumed engine a fix behind its last position is read — correctly — as
  /// a teleport, and a helper that made that easy to do by accident would
  /// produce tests that pass for the wrong reason.
  double ride(
    void Function(Duration) advance,
    DateTime Function() clock,
    RideEngine engine,
    double speedMps,
    int seconds, {
    double alreadyTravelled = 0,
    double accuracy = 4,
    double? altitude,
  }) {
    var travelled = alreadyTravelled;
    for (var i = 0; i < seconds; i++) {
      advance(const Duration(seconds: 1));
      travelled += speedMps;
      engine.onLocation(
        fixAt(
          origin,
          travelled,
          clock(),
          accuracy: accuracy,
          speed: speedMps,
          altitude: altitude,
        ),
      );
    }
    return travelled;
  }

  // ------------------------------------------------------------------

  group('lifecycle', () {
    test('starts idle and moves through preparing to riding', () {
      withRide((advance, clock, starve) {
        final engine = RideEngine(now: clock);
        expect(engine.state.status, RideStatus.idle);

        engine.start();
        expect(engine.state.status, RideStatus.preparing);
        expect(engine.state.rideId, isNotNull);

        engine.beginRecording();
        expect(engine.state.status, RideStatus.riding);

        engine.dispose();
      });
    });

    test('a weak signal never blocks the start (spec §4)', () {
      withRide((advance, clock, starve) {
        final engine = RideEngine(
          config: const RideEngineConfig(
            preparingTimeout: Duration(seconds: 3),
          ),
          now: clock,
        );
        engine.start();

        // No fixes arrive at all — indoors, or a cold receiver.
        advance(const Duration(seconds: 4));

        expect(
          engine.state.status,
          RideStatus.riding,
          reason:
              'the countdown must expire into a recording ride, not a block',
        );

        engine.dispose();
      });
    });

    test('pause freezes moving time but not elapsed time', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        ride(advance, clock, engine, 5, 10);

        final afterRiding = engine.state.stats;
        expect(afterRiding.moving.inSeconds, greaterThanOrEqualTo(9));

        engine.pause();
        advance(const Duration(seconds: 30));

        final paused = engine.state.stats;
        expect(
          paused.moving,
          afterRiding.moving,
          reason: 'a manual pause must freeze moving time',
        );
        expect(
          paused.elapsed,
          greaterThan(afterRiding.elapsed + const Duration(seconds: 25)),
          reason: 'the ride is still going on around the pause',
        );

        engine.dispose();
      });
    });

    test('stop produces a ride with the ride id and endpoints', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        ride(advance, clock, engine, 5, 60);

        Ride? finished;
        engine.stop().then((r) => finished = r);
        // `stop()` is async, so its future completes on a microtask even
        // though its body has no awaits. Elapsing by zero flushes it.
        advance(Duration.zero);

        expect(finished, isNotNull);
        expect(finished!.id, isNotEmpty);
        expect(finished!.endedAt, isNotNull);
        expect(finished!.startPoint, isNotNull);
        expect(finished!.endPoint, isNotNull);
        expect(finished!.stats.moving.inSeconds, greaterThan(50));
        expect(finished!.stats.distanceMeters, greaterThan(250));

        engine.dispose();
      });
    });
  });

  group('distance and speed', () {
    test('phone GPS movement overrides a stuck Android zero speed', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        var travelled = 0.0;
        for (var i = 0; i < 10; i++) {
          advance(const Duration(seconds: 1));
          travelled += 5;
          engine.onLocation(fixAt(origin, travelled, clock(), speed: 0));
        }

        expect(engine.state.stats.distanceMeters, greaterThan(20));
        expect(engine.state.stats.currentSpeedMps, greaterThan(2));
        expect(engine.state.autoPaused, isFalse);

        for (var i = 0; i < 8; i++) {
          advance(const Duration(seconds: 1));
          engine.onLocation(fixAt(origin, travelled, clock(), speed: 0));
        }
        expect(engine.state.autoPaused, isTrue);
        engine.dispose();
      });
    });

    test('slow GPS movement also escapes a stuck zero speed', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        var travelled = 0.0;
        for (var i = 0; i < 14; i++) {
          advance(const Duration(seconds: 1));
          travelled += 2;
          engine.onLocation(fixAt(origin, travelled, clock(), speed: 0));
        }
        expect(engine.state.stats.currentSpeedMps, greaterThan(1));
        expect(engine.state.stats.distanceMeters, greaterThan(10));
        engine.dispose();
      });
    });

    test('GPS jitter with a zero speed does not create movement', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        for (final offset in [
          0.0,
          5.0,
          -4.0,
          6.0,
          -5.0,
          4.0,
          0.0,
          -6.0,
          5.0,
          0.0,
        ]) {
          advance(const Duration(seconds: 1));
          engine.onLocation(fixAt(origin, offset, clock(), speed: 0));
        }
        expect(engine.state.stats.currentSpeedMps, 0);
        expect(engine.state.stats.distanceMeters, 0);
        expect(engine.state.autoPaused, isFalse);
        engine.dispose();
      });
    });

    test('a steady 18 km/h ride reports a plausible distance and speed', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);

        // 5 m/s for 600 s is 3000 m.
        ride(advance, clock, engine, 5, 600);
        advance(const Duration(seconds: 1));

        final stats = engine.state.stats;

        expect(stats.distanceMeters, closeTo(3000, 60));
        expect(stats.currentSpeedMps, closeTo(5, 1.0));
        expect(stats.avgSpeedMps, closeTo(5, 0.6));
        expect(stats.maxSpeedMps, greaterThan(3));

        engine.dispose();
      });
    });

    test('a standstill adds no distance', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        final travelled = ride(advance, clock, engine, 5, 60);
        final moving = engine.state.stats.distanceMeters;

        // Two minutes parked, with the receiver swinging ±5 m — the pattern
        // that ruins a naive distance accumulator.
        for (var i = 0; i < 120; i++) {
          advance(const Duration(seconds: 1));
          final wobble = (i % 2 == 0) ? 5.0 : -5.0;
          engine.onLocation(
            fixAt(origin, travelled + wobble, clock(), accuracy: 5, speed: 0),
          );
        }

        expect(engine.state.stats.distanceMeters, closeTo(moving, 5));

        engine.dispose();
      });
    });

    test('a teleporting fix is rejected', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        ride(advance, clock, engine, 5, 30);
        final before = engine.state.stats.distanceMeters;

        // A 3 km jump in one second — a bad fix, not a bicycle.
        advance(const Duration(seconds: 1));
        engine.onLocation(fixAt(origin, 3000, clock(), speed: 200));

        expect(engine.state.stats.distanceMeters, closeTo(before, 1));

        engine.dispose();
      });
    });
  });

  group('auto-pause (spec §14)', () {
    test('stationary GPS at the start does not auto-pause before moving', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        for (var i = 0; i < 12; i++) {
          advance(const Duration(seconds: 1));
          engine.onLocation(fixAt(origin, 0, clock(), speed: 0));
        }
        expect(engine.state.speedAvailable, isTrue);
        expect(engine.state.autoPaused, isFalse);
        expect(engine.state.status, RideStatus.riding);
        engine.dispose();
      });
    });

    test('pauses after the delay below the threshold, resumes above it', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        final travelled = ride(advance, clock, engine, 5, 20);
        expect(engine.state.autoPaused, isFalse);

        // Below the 2 km/h pause threshold, held past the 5 s delay.
        for (var i = 0; i < 8; i++) {
          advance(const Duration(seconds: 1));
          engine.onLocation(fixAt(origin, travelled, clock(), speed: 0.2));
        }

        expect(engine.state.autoPaused, isTrue);
        final pausedMoving = engine.state.stats.moving;

        // Still below threshold: moving time must not advance.
        for (var i = 0; i < 20; i++) {
          advance(const Duration(seconds: 1));
          engine.onLocation(fixAt(origin, travelled, clock(), speed: 0.2));
        }
        expect(engine.state.stats.moving, pausedMoving);

        // Above the 3 km/h resume threshold, sustained past the 2 s delay.
        var moved = travelled;
        for (var i = 0; i < 6; i++) {
          advance(const Duration(seconds: 1));
          moved += 4;
          engine.onLocation(fixAt(origin, moved, clock(), speed: 4));
        }

        expect(engine.state.autoPaused, isFalse);

        engine.dispose();
      });
    });

    test('a single slow sample does not trigger a pause', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        final travelled = ride(advance, clock, engine, 5, 20);

        advance(const Duration(seconds: 1));
        engine.onLocation(fixAt(origin, travelled, clock(), speed: 0.5));

        expect(
          engine.state.autoPaused,
          isFalse,
          reason: 'one slow fix is jitter, not a stop',
        );

        engine.dispose();
      });
    });

    test('can be disabled entirely', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(
          clock: clock,
          config: const RideEngineConfig(autoPauseEnabled: false),
        );

        for (var i = 0; i < 60; i++) {
          advance(const Duration(seconds: 1));
          engine.onLocation(fixAt(origin, 0, clock(), speed: 0));
        }

        expect(engine.state.autoPaused, isFalse);

        engine.dispose();
      });
    });
  });

  group('elevation', () {
    test('accumulates gain from a smoothed profile', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);

        // Climb 150 m over 200 s at 5 m/s. The deadband and the smoothing both
        // eat into the total, which is the point: the number must not be
        // inflated by noise.
        var travelled = 0.0;
        var altitude = 50.0;
        for (var i = 0; i < 200; i++) {
          advance(const Duration(seconds: 1));
          travelled += 5;
          altitude += 0.75;
          engine.onLocation(
            fixAt(origin, travelled, clock(), speed: 5, altitude: altitude),
          );
        }

        final gain = engine.state.stats.elevationGainMeters;
        expect(gain, greaterThan(60));
        expect(gain, lessThan(170));

        engine.dispose();
      });
    });

    test('flat terrain with noisy altitude reports almost no climb', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);

        var travelled = 0.0;
        for (var i = 0; i < 300; i++) {
          advance(const Duration(seconds: 1));
          travelled += 5;
          // ±1.5 m of GPS altitude noise on flat ground — below the 2 m
          // threshold, so it must be absorbed rather than counted.
          final noise = (i % 2 == 0) ? 1.5 : -1.5;
          engine.onLocation(
            fixAt(origin, travelled, clock(), speed: 5, altitude: 50 + noise),
          );
        }

        expect(
          engine.state.stats.elevationGainMeters,
          lessThan(20),
          reason: 'a flat ride must not report climbing',
        );

        engine.dispose();
      });
    });
  });

  group('sensors', () {
    test('fresh wheel speed remains visible through new GPS fixes', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        var travelled = ride(advance, clock, engine, 5, 3);
        engine.onSensorReading(
          SensorReading(
            type: SensorType.speed,
            value: 25.2,
            timestamp: clock(),
          ),
        );
        expect(engine.state.stats.currentSpeedMps, closeTo(7, 0.01));

        advance(const Duration(seconds: 1));
        travelled += 5;
        engine.onLocation(fixAt(origin, travelled, clock(), speed: 5));
        expect(engine.state.stats.currentSpeedMps, closeTo(7, 0.01));

        advance(const Duration(seconds: 6));
        expect(engine.state.stats.currentSpeedMps, closeTo(5, 0.01));
        engine.dispose();
      });
    });

    test('wheel speed takes over when GPS is stale, then expires', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        ride(advance, clock, engine, 5, 3);

        advance(const Duration(seconds: 16));
        engine.onSensorReading(
          SensorReading(type: SensorType.speed, value: 7.2, timestamp: clock()),
        );
        expect(engine.state.stats.currentSpeedMps, closeTo(2, 0.01));
        expect(engine.state.speedAvailable, isTrue);
        expect(engine.state.sensors.wheelSpeedMps, closeTo(2, 0.01));

        advance(const Duration(seconds: 6));
        expect(engine.state.speedAvailable, isFalse);
        expect(engine.state.sensors.wheelSpeedMps, isNull);
        engine.dispose();
      });
    });

    test('wheel speed alone can pause and resume a ride', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        engine.onSensorReading(
          SensorReading(
            type: SensorType.speed,
            value: 14.4,
            timestamp: clock(),
          ),
        );
        for (var i = 0; i < 6; i++) {
          engine.onSensorReading(
            SensorReading(type: SensorType.speed, value: 0, timestamp: clock()),
          );
          advance(const Duration(seconds: 1));
        }
        expect(engine.state.autoPaused, isTrue);
        expect(engine.state.status, RideStatus.riding);

        for (var i = 0; i < 3; i++) {
          engine.onSensorReading(
            SensorReading(
              type: SensorType.speed,
              value: 14.4,
              timestamp: clock(),
            ),
          );
          advance(const Duration(seconds: 1));
        }
        expect(engine.state.autoPaused, isFalse);
        expect(engine.state.stats.currentSpeedMps, closeTo(4, 0.01));
        engine.dispose();
      });
    });

    test('heart rate, cadence and power reach the state and the trace', () {
      withRide((advance, clock, starve) {
        final points = <TrackPoint>[];
        final engine = startRiding(clock: clock, points: points);

        var travelled = ride(advance, clock, engine, 5, 10);

        for (final (type, value) in const [
          (SensorType.heartRate, 140.0),
          (SensorType.cadence, 85.0),
          (SensorType.power, 210.0),
        ]) {
          engine.onSensorReading(
            SensorReading(type: type, value: value, timestamp: clock()),
          );
        }

        final sensors = engine.state.sensors;
        expect(sensors.heartRate, 140);
        expect(sensors.cadence, 85);
        expect(sensors.power, 210);
        expect(sensors.avgHeartRate, 140);

        // The values are stamped onto subsequent track points, so the exported
        // GPX carries them (spec §35).
        travelled = ride(
          advance,
          clock,
          engine,
          5,
          3,
          alreadyTravelled: travelled,
        );
        expect(points.last.heartRate, 140);
        expect(points.last.cadence, 85);

        engine.dispose();
      });
    });

    test('implausible sensor values are discarded', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        ride(advance, clock, engine, 5, 5);

        engine.onSensorReading(
          SensorReading(
            type: SensorType.heartRate,
            value: 900,
            timestamp: clock(),
          ),
        );
        engine.onSensorReading(
          SensorReading(
            type: SensorType.cadence,
            value: -5,
            timestamp: clock(),
          ),
        );

        expect(engine.state.sensors.heartRate, isNull);
        expect(engine.state.sensors.cadence, isNull);

        engine.dispose();
      });
    });
  });

  group('crash recovery (spec §42)', () {
    test('a checkpoint carries everything needed to resume, and is written '
        'on the checkpoint cadence', () {
      withRide((advance, clock, starve) {
        final checkpoints = <RideCheckpoint>[];
        final engine = RideEngine(
          config: const RideEngineConfig(
            checkpointInterval: Duration(seconds: 5),
          ),
          now: clock,
          onCheckpoint: checkpoints.add,
        );
        engine.start();
        engine.beginRecording();

        ride(advance, clock, engine, 5, 30);

        // 30 s at a 5 s cadence.
        expect(
          checkpoints.length,
          greaterThanOrEqualTo(4),
          reason: 'a crash must cost seconds of trace, not the whole ride',
        );

        final checkpoint = engine.buildCheckpoint();
        expect(checkpoint.rideId, engine.state.rideId);
        expect(checkpoint.distanceMeters, greaterThan(0));
        expect(checkpoint.lastSequence, greaterThan(0));
        expect(checkpoint.resumable, isTrue);
        expect(checkpoint.anchorLat, isNotNull);
        expect(checkpoint.moving, engine.state.stats.moving);

        engine.dispose();
      });
    });

    test('restoring resumes without a phantom segment across the gap', () {
      withRide((advance, clock, starve) {
        final checkpoint = RideCheckpoint(
          rideId: '0192f3a0-0000-7000-8000-000000000001',
          status: RideStatus.riding.name,
          startedAt: clock().subtract(const Duration(minutes: 30)),
          elapsed: const Duration(minutes: 30),
          moving: const Duration(minutes: 28),
          distanceMeters: 8000,
          maxSpeedMps: 9,
          elevationGainMeters: 120,
          elevationLossMeters: 90,
          lastLat: origin.lat,
          lastLng: origin.lng,
          lastSequence: 1800,
          smoothedSpeedMps: 5,
          anchorLat: origin.lat,
          anchorLng: origin.lng,
          anchorTimestampMs: clock().millisecondsSinceEpoch - 60000,
        );

        final engine = RideEngine(now: clock);
        engine.restoreFrom(checkpoint, resumeSequence: 1800);

        expect(engine.state.status, RideStatus.paused);
        expect(engine.state.stats.distanceMeters, 8000);
        expect(engine.state.stats.moving, const Duration(minutes: 28));

        engine.resume();

        // The rider is 2 km away when the app comes back — they kept riding
        // while it was dead. That must not appear as 2 km of teleport distance
        // in the resumed ride.
        ride(advance, clock, engine, 5, 30, alreadyTravelled: 2000);

        final distance = engine.state.stats.distanceMeters;
        expect(
          distance,
          lessThan(8150),
          reason:
              'the gap between the checkpoint and the resume must not count',
        );
        expect(distance, greaterThan(8000));

        // Sequence numbering continues from the checkpoint, so a resume cannot
        // collide with rows already written.
        expect(engine.state.acceptedPointCount, greaterThan(1800));

        engine.dispose();
      });
    });
  });

  group('a locked screen must not interrupt the ride (spec §31)', () {
    // These tests pin down the *logic* half of a requirement whose other half
    // is platform configuration: `UIBackgroundModes: location` on iOS and a
    // `location`-typed foreground service on Android keep the process alive
    // and location arriving with the screen off. See `docs/gps.md` for the
    // on-device verification checklist.
    //
    // What is testable here is that nothing in the engine depends on the app
    // being in the foreground, and that a starved timer queue costs nothing.

    test('time is not lost when the process is suspended', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        ride(advance, clock, engine, 5, 60);

        final beforeLock = engine.state.stats;

        // The screen locks. On a platform where the background mode is
        // misconfigured — or where the OS throttles a backgrounded app
        // anyway — wall-clock time keeps passing while timer callbacks stop.
        starve(const Duration(minutes: 30));

        // The next tick fires and catches up. Time is derived from wall-clock
        // deltas precisely so that a coalesced or delayed tick does not
        // silently lose seconds.
        advance(const Duration(seconds: 1));

        final afterLock = engine.state.stats;

        expect(
          afterLock.elapsed - beforeLock.elapsed,
          greaterThanOrEqualTo(const Duration(minutes: 30)),
          reason: 'the ride clock keeps running with the screen off',
        );
        expect(
          engine.state.status,
          RideStatus.riding,
          reason: 'nothing about a locked screen changes the ride state',
        );

        engine.dispose();
      });
    });

    test('a checkpoint survives a suspension, so nothing is lost even if the '
        'process is killed', () {
      withRide((advance, clock, starve) {
        final checkpoints = <RideCheckpoint>[];
        final engine = RideEngine(
          config: const RideEngineConfig(
            checkpointInterval: Duration(seconds: 5),
          ),
          now: clock,
          onCheckpoint: checkpoints.add,
        );
        engine.start();
        engine.beginRecording();

        ride(advance, clock, engine, 5, 120);

        // The last checkpoint is the one the app would write as it goes to
        // the background.
        final last = engine.buildCheckpoint();
        expect(last.resumable, isTrue);
        expect(last.lastSequence, greaterThan(0));
        expect(last.distanceMeters, greaterThan(400));
        expect(last.anchorLat, isNotNull);

        // And checkpoints have been written all along, not just at the end.
        expect(checkpoints.length, greaterThanOrEqualTo(20));

        engine.dispose();
      });
    });

    test('a long suspension does not corrupt the distance', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        final travelled = ride(advance, clock, engine, 5, 120);
        final beforeLock = engine.state.stats.distanceMeters;

        // Fifteen minutes with no callbacks at all.
        starve(const Duration(minutes: 15));

        // The rider kept riding the whole time. The first fix after the gap
        // arrives 4.5 km further on.
        advance(const Duration(seconds: 1));
        final resumed = travelled + 4500;
        engine.onLocation(fixAt(origin, resumed, clock(), speed: 5));

        final distance = engine.state.stats.distanceMeters;
        expect(
          distance,
          greaterThan(beforeLock),
          reason: 'the gap should be bridged, not dropped',
        );
        expect(
          distance,
          lessThan(beforeLock + 5500),
          reason: 'and bridged once, not counted twice',
        );

        engine.dispose();
      });
    });
  });

  group('GPS quality reporting', () {
    test('reports poor when fixes are arriving but unusable', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(clock: clock);
        final travelled = ride(advance, clock, engine, 5, 10);
        expect(engine.state.gpsPoor, isFalse);

        // Fixes keep arriving — the receiver is not silent — but none of them
        // can be trusted.
        for (var i = 0; i < 5; i++) {
          advance(const Duration(seconds: 1));
          engine.onLocation(fixAt(origin, travelled, clock(), accuracy: 120));
        }

        expect(engine.state.gpsPoor, isTrue);
        expect(
          engine.state.gpsSignalLost,
          isFalse,
          reason: 'a bad fix is not the same as silence',
        );

        engine.dispose();
      });
    });

    test('a fix the receiver stamped long ago is not silence', () {
      withRide((advance, clock, starve) {
        final engine = startRiding(
          clock: clock,
          config: const RideEngineConfig(
            gpsSignalLostAfter: Duration(seconds: 5),
          ),
        );
        ride(advance, clock, engine, 5, 10);
        expect(engine.state.gpsSignalLost, isFalse);

        // iOS hands its cached location over the moment a stream opens, so a
        // re-subscription after a background spell delivers a fix stamped
        // minutes ago. Judged by that stamp the app looks silent; judged by
        // whether updates are arriving, which is the question a rider is
        // asking, it plainly is not.
        engine.onLocation(
          fixAt(origin, 50, clock().subtract(const Duration(minutes: 5))),
        );

        expect(
          engine.state.gpsSignalLost,
          isFalse,
          reason: '判据是「还有没有收到定位」，不是「平台认为这个定位有多旧」',
        );

        engine.dispose();
      });
    });

    test(
      'reports signal lost when fixes stop, and keeps the clock running',
      () {
        withRide((advance, clock, starve) {
          final engine = startRiding(
            clock: clock,
            config: const RideEngineConfig(
              gpsSignalLostAfter: Duration(seconds: 5),
            ),
          );

          ride(advance, clock, engine, 5, 10);

          // A tunnel: no fixes at all for 30 s.
          advance(const Duration(seconds: 30));

          expect(engine.state.gpsSignalLost, isTrue);
          expect(
            engine.state.stats.elapsed.inSeconds,
            greaterThan(35),
            reason: 'the clock keeps running with no signal',
          );

          engine.dispose();
        });
      },
    );
  });
}
