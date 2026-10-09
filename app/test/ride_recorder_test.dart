import 'dart:async';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/database/dao/active_ride_dao.dart';
import 'package:cycling_app/core/location/barometer_source.dart';
import 'package:cycling_app/core/location/compass_source.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/core/location/motion_source.dart';
import 'package:cycling_app/core/location/sampling_policy.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/domain/ride_engine.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:cycling_app/features/sensors/domain/sensor.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_diagnostic_log.dart';
import 'support/test_harness.dart';

/// What happens to a ride after the rider presses 结束.
///
/// A plain test, not a widget test, and that is the point. The stop sequence is
/// a chain of awaited writes, and the only thing left in it that touches the
/// platform is the GPX file — which has no plugin here and fails fast into a
/// catch. Without a widget binding the whole chain runs on the real event loop
/// and completes deterministically, so the assertions below are about the app
/// rather than about test timing.
///
/// The widget tests cover the screens; this covers the durability.
void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());
  tearDown(() => database.close());

  RideRecorder buildRecorder(
    FakeLocationService location, {
    Stream<SensorReading>? readings,
  }) =>
      RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        sensorReadings: readings,
      );

  Future<RideCheckpoint> seedRecovery() async {
    final started = DateTime.utc(2026, 1, 1);
    final checkpoint = RideCheckpoint(
      rideId: 'recovered',
      status: RideStatus.riding.name,
      startedAt: started,
      elapsed: const Duration(minutes: 10),
      moving: const Duration(minutes: 8),
      distanceMeters: 2400,
      maxSpeedMps: 9,
      elevationGainMeters: 45,
      elevationLossMeters: 21,
      lastSequence: 2,
      smoothedSpeedMps: 5,
    );
    await database.rideDao.upsertRide(
      Ride(id: checkpoint.rideId, startedAt: started),
    );
    await database.rideDao.insertTrackPoints([
      for (var i = 1; i <= 2; i++)
        TrackPoint(
          rideId: checkpoint.rideId,
          sequence: i,
          timestamp: started.add(Duration(minutes: i)),
          lat: 31 + i * .001,
          lng: 121,
        ),
    ]);
    await database.activeRideDao.save(checkpoint);
    return checkpoint;
  }

  test(
    'recovery ends without location permission or subscribing to inputs',
    () async {
      final checkpoint = await seedRecovery();
      final location = FakeLocationService(
        permission: LocationPermissionStatus.denied,
      );
      final recorder = buildRecorder(location);
      final ride = await recorder.finishRecoveredRide(checkpoint);
      expect(location.permissionRequests, isEmpty);
      expect(location.streamOpened, isFalse);
      expect(recorder.engine, isNull);
      expect(ride.elapsed, const Duration(minutes: 10));
      expect(ride.distanceMeters, 2400);
      expect(ride.endedAt, checkpoint.startedAt.add(checkpoint.elapsed));
      expect(await database.activeRideDao.loadUnfinished(), isNull);
      expect(await database.rideDao.trackPointCount(ride.id), 2);
      expect(
        (await database.rideDao.getRide(ride.id))!.routeGeometryWkt,
        isNotNull,
      );
      expect(await database.syncQueueDao.pendingCount(), 1);
      expect((await recorder.finishRecoveredRide(checkpoint)).id, ride.id);
      expect(await database.syncQueueDao.pendingCount(), 1);
      await recorder.dispose();
    },
  );

  test(
    'failed recovery commit keeps checkpoint and trace available for retry',
    () async {
      final checkpoint = await seedRecovery();
      final recorder = buildRecorder(FakeLocationService());
      await database.customStatement(
        "CREATE TRIGGER fail_recovery BEFORE INSERT ON sync_queue_items BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      );
      await expectLater(
        recorder.finishRecoveredRide(checkpoint),
        throwsA(anything),
      );
      expect(await database.activeRideDao.loadUnfinished(), isNotNull);
      expect(
        (await database.rideDao.getRide(checkpoint.rideId))!.endedAt,
        isNull,
      );
      expect(await database.rideDao.trackPointCount(checkpoint.rideId), 2);
      expect(await database.syncQueueDao.pendingCount(), 0);
      await database.customStatement('DROP TRIGGER fail_recovery');
      await recorder.finishRecoveredRide(checkpoint);
      expect(await database.activeRideDao.loadUnfinished(), isNull);
      expect(await database.syncQueueDao.pendingCount(), 1);
      await recorder.dispose();
    },
  );

  test('a finished ride is persisted with its trace, geometry and queue entry',
      () async {
    final location = FakeLocationService();
    final recorder = buildRecorder(location);

    expect(await recorder.startRide(const AppSettings()), isTrue);
    await recorder.beginRecording();

    // 60 fixes at 5 m/s is 300 m, comfortably past the 200 m threshold below
    // which the UI treats a ride as a mis-tap.
    location.emitRide(count: 60, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final ride = await recorder.stopRide();

    expect(ride, isNotNull);
    expect(ride!.stats.distanceMeters, greaterThan(200));
    expect(ride.stats.maxSpeedMps, greaterThan(3));
    expect(ride.startPoint, isNotNull);
    expect(ride.endPoint, isNotNull);

    // The summary row.
    final stored = await database.rideDao.getRides();
    expect(stored, hasLength(1));
    expect(stored.first.id, ride.id);
    expect(stored.first.stats.distanceMeters, ride.stats.distanceMeters);

    // The trace, at full resolution — this is what the GPX is rebuilt from and
    // what the detail screen draws.
    final points = await database.rideDao.getTrackPoints(ride.id);
    expect(
      points.length,
      greaterThan(40),
      reason: 'the trace must survive the stop, not just the summary',
    );
    expect(points.first.sequence, 1);
    // Sequences are contiguous, so a gap in the trace is visible rather than
    // silently absorbed.
    for (var i = 1; i < points.length; i++) {
      expect(points[i].sequence, points[i - 1].sequence + 1);
    }

    // The PostGIS geometry the cloud will receive, built once at ride end
    // rather than uploaded point by point.
    final withGeometry = await database.rideDao.getRide(ride.id);
    expect(withGeometry!.routeGeometryWkt, startsWith('LINESTRING('));
    expect(withGeometry.routeGeometryWkt, contains(','));

    // And the outbox entry, in the same transaction as the data. A ride that
    // never uploads is a disappointment; a ride that uploads without a queue
    // entry is one that never will.
    expect(await database.syncQueueDao.pendingCount(), 1);
    expect(
      withGeometry.syncStatus,
      SyncStatus.pendingUpload,
      reason: 'a finished ride is waiting to upload, not already synced',
    );

    await recorder.dispose();
    await location.dispose();
  });

  test('the crash-recovery checkpoint is cleared once the ride is saved',
      () async {
    final location = FakeLocationService();
    final recorder = buildRecorder(location);

    await recorder.startRide(const AppSettings());
    await recorder.beginRecording();
    location.emitRide(count: 30, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await recorder.saveCheckpointNow();
    expect(
      await recorder.findUnfinishedRide(),
      isNotNull,
      reason: 'a ride in progress must be recoverable',
    );

    await recorder.stopRide();

    expect(
      await recorder.findUnfinishedRide(),
      isNull,
      reason: 'a cleanly finished ride must not be offered for recovery',
    );

    await recorder.dispose();
    await location.dispose();
  });

  test(
    'a failed final commit keeps recovery and can be retried without duplicates',
    () async {
      final location = FakeLocationService();
      final readings = StreamController<SensorReading>.broadcast();
      final recorder = buildRecorder(location, readings: readings.stream);
      await recorder.startRide(const AppSettings());
      await recorder.beginRecording();
      location.emitRide(count: 35, speedMps: 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final distance = recorder.state.stats.distanceMeters;
      final pointCount = recorder.state.acceptedPointCount;

      // Fail after the ride row has been updated inside the final transaction.
      await database.customStatement('''
      CREATE TRIGGER fail_final_outbox BEFORE INSERT ON sync_queue_items
      BEGIN SELECT RAISE(ABORT, 'injected outbox failure'); END
    ''');
      await expectLater(recorder.stopRide(name: '晨骑'), throwsA(anything));

      final recovery = await recorder.findUnfinishedRide();
      expect(recovery, isNotNull);
      expect(recovery!.distanceMeters, distance);
      expect(recovery.lastSequence, pointCount);
      final incomplete = await database.rideDao.getRide(recovery.rideId);
      expect(
        incomplete!.endedAt,
        isNull,
        reason: 'the summary update rolls back',
      );
      expect(await database.syncQueueDao.pendingCount(), 0);
      final relaunchedLocation = FakeLocationService();
      final relaunched = buildRecorder(relaunchedLocation);
      final durableRecovery = await relaunched.findUnfinishedRide();
      expect(durableRecovery!.rideId, recovery.rideId);
      expect(durableRecovery.lastSequence, pointCount);
      expect(durableRecovery.distanceMeters, distance);
      await relaunched.dispose();
      await relaunchedLocation.dispose();
      expect(
        readings.hasListener,
        isFalse,
        reason: 'failed saving must still stop sensor work',
      );
      await expectLater(
        recorder.startRide(const AppSettings()),
        throwsStateError,
      );

      await database.customStatement('DROP TRIGGER fail_final_outbox');
      // Double-tapping retry shares a single commit and the same frozen result.
      final attempts = await Future.wait([
        recorder.stopRide(),
        recorder.stopRide(),
      ]);
      expect(attempts[0]!.endedAt, attempts[1]!.endedAt);
      expect(attempts[0]!.stats.distanceMeters, distance);
      expect(attempts[0]!.name, '晨骑', reason: 'retry keeps the requested name');
      final points = await database.rideDao.getTrackPoints(recovery.rideId);
      expect(points, hasLength(pointCount));
      expect(points.map((p) => p.sequence).toSet(), hasLength(pointCount));
      expect(await database.syncQueueDao.pendingCount(), 1);
      expect(await recorder.findUnfinishedRide(), isNull);

      await recorder.dispose();
      await readings.close();
      await location.dispose();
    },
  );

  test('a failed point flush cannot advance the recovery checkpoint', () async {
    final location = FakeLocationService();
    final recorder = buildRecorder(location);
    await recorder.startRide(const AppSettings());
    await recorder.beginRecording();
    await database.customStatement('''
      CREATE TRIGGER fail_trace_write BEFORE INSERT ON track_points
      BEGIN SELECT RAISE(ABORT, 'injected trace failure'); END
    ''');
    location.emitRide(count: 5, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final expected = recorder.state.acceptedPointCount;

    await expectLater(recorder.saveCheckpointNow(), throwsA(anything));
    expect(await recorder.findUnfinishedRide(), isNull);
    await expectLater(recorder.stopRide(), throwsA(anything));
    expect(await recorder.findUnfinishedRide(), isNull);
    await database.customStatement('DROP TRIGGER fail_trace_write');
    final saved = await recorder.stopRide();
    expect(
      await database.rideDao.getTrackPoints(saved!.id),
      hasLength(expected),
      reason: 'the failed batch was retained for retry',
    );
    expect(await recorder.findUnfinishedRide(), isNull);

    await recorder.dispose();
    await location.dispose();
  });

  test(
    'a failed final checkpoint save preserves previous recovery and retries',
    () async {
      final location = FakeLocationService();
      final recorder = buildRecorder(location);
      await recorder.startRide(const AppSettings());
      await recorder.beginRecording();
      location.emitRide(count: 5, speedMps: 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await recorder.saveCheckpointNow();
      final before = await recorder.findUnfinishedRide();
      await database.customStatement('''
      CREATE TRIGGER fail_checkpoint BEFORE INSERT ON active_ride_checkpoints
      BEGIN SELECT RAISE(ABORT, 'injected checkpoint failure'); END
    ''');

      await expectLater(recorder.stopRide(), throwsA(anything));
      final recovery = await recorder.findUnfinishedRide();
      expect(recovery!.rideId, before!.rideId);
      expect(recovery.lastSequence, before.lastSequence);
      expect((await database.rideDao.getRide(before.rideId))!.endedAt, isNull);

      await database.customStatement('DROP TRIGGER fail_checkpoint');
      final saved = await recorder.stopRide();
      expect(saved!.id, before.rideId);
      expect(
        await database.rideDao.getTrackPoints(saved.id),
        hasLength(before.lastSequence),
      );
      expect(await recorder.findUnfinishedRide(), isNull);
      await recorder.dispose();
      await location.dispose();
    },
  );

  test('an in-flight checkpoint cannot reappear after a clean stop', () async {
    final location = FakeLocationService();
    final checkpoints = _BlockingCheckpointDao(database);
    final recorder = RideRecorder(
      db: database,
      repository: RideRepository(database),
      locationService: location,
      activeRideDao: checkpoints,
    );
    await recorder.startRide(const AppSettings());
    await recorder.beginRecording();
    location.emitRide(count: 5, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    checkpoints.blockNext = true;
    final checkpoint = recorder.saveCheckpointNow();
    await checkpoints.entered.future;
    final stopping = recorder.stopRide();
    checkpoints.release.complete();
    await checkpoint;
    await stopping;

    expect(await recorder.findUnfinishedRide(), isNull);
    expect(await database.syncQueueDao.pendingCount(), 1);
    await recorder.dispose();
    await location.dispose();
  });

  test(
    'discard racing a successful stop cannot delete the saved ride',
    () async {
      final location = FakeLocationService();
      final checkpoints = _BlockingCheckpointDao(database);
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        activeRideDao: checkpoints,
      );
      await recorder.startRide(const AppSettings());
      await recorder.beginRecording();
      location.emitRide(count: 5, speedMps: 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      checkpoints.blockNext = true;
      final stopping = recorder.stopRide();
      await checkpoints.entered.future;
      final discarding = recorder.discardRide();
      checkpoints.release.complete();
      final saved = await stopping;
      await discarding;

      expect(await database.rideDao.getRide(saved!.id), isNotNull);
      expect(await database.rideDao.getTrackPoints(saved.id), isNotEmpty);
      expect(await database.syncQueueDao.pendingCount(), 1);
      await recorder.dispose();
      await location.dispose();
    },
  );

  for (final discard in [false, true]) {
    test(
      '${discard ? 'discard' : 'stop'} releases every ride sensor subscription',
      () async {
        final location = FakeLocationService();
        final readings = StreamController<SensorReading>.broadcast();
        final barometer = _ListeningBarometer();
        final compass = _ListeningCompass();
        final motion = _ListeningMotion();
        final recorder = RideRecorder(
          db: database,
          repository: RideRepository(database),
          locationService: location,
          sensorReadings: readings.stream,
          barometer: barometer,
          compass: compass,
          motion: motion,
        );
        await recorder.startRide(const AppSettings());
        await recorder.beginRecording();
        expect(readings.hasListener, isTrue);
        expect(barometer.controller.hasListener, isTrue);
        expect(compass.controller.hasListener, isTrue);
        expect(motion.controller.hasListener, isTrue);
        if (discard) {
          await recorder.discardRide();
        } else {
          await recorder.stopRide();
        }
        expect(readings.hasListener, isFalse);
        expect(barometer.controller.hasListener, isFalse);
        expect(compass.controller.hasListener, isFalse);
        expect(motion.controller.hasListener, isFalse);

        await recorder.dispose();
        await readings.close();
        await barometer.controller.close();
        await compass.controller.close();
        await motion.controller.close();
        await location.dispose();
      },
    );
  }

  test('a failed discard retries the original ride after the engine is cleared',
      () async {
    final location = FakeLocationService();
    final recorder = buildRecorder(location);
    await recorder.startRide(const AppSettings());
    await recorder.beginRecording();
    location.emitRide(count: 5, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await recorder.saveCheckpointNow();
    final checkpoint = await recorder.findUnfinishedRide();
    await database.customStatement('''
      CREATE TRIGGER fail_discard BEFORE DELETE ON local_rides
      BEGIN SELECT RAISE(ABORT, 'injected discard failure'); END
    ''');

    await expectLater(recorder.discardRide(), throwsA(anything));
    expect(await recorder.findUnfinishedRide(), isNotNull);
    expect(await database.rideDao.getRide(checkpoint!.rideId), isNotNull);
    await expectLater(recorder.stopRide(), throwsStateError);
    await database.customStatement('DROP TRIGGER fail_discard');
    await recorder.discardRide();
    expect(await database.rideDao.getRide(checkpoint.rideId), isNull);
    expect(await database.rideDao.getTrackPoints(checkpoint.rideId), isEmpty);
    expect(await recorder.findUnfinishedRide(), isNull);

    await recorder.dispose();
    await location.dispose();
  });

  test('a sensor reading reaches the engine and the stored trace', () async {
    // The wiring under test is one line in the provider graph, and it was
    // missing for a while: the manager paired devices and showed live values
    // on its own screen while the engine never saw a single reading. The
    // engine's own tests cannot catch that, so this one feeds a reading
    // through the recorder the way the app does.
    final location = FakeLocationService();
    final readings = StreamController<SensorReading>.broadcast();
    final recorder = buildRecorder(location, readings: readings.stream);

    await recorder.startRide(const AppSettings());
    await recorder.beginRecording();

    final t0 = DateTime.now().toUtc();
    location.emitRide(count: 30, speedMps: 5, start: t0);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    readings.add(
      SensorReading(
        type: SensorType.heartRate,
        value: 142,
        timestamp: DateTime.now().toUtc(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Live: the dashboard reads it from here.
    expect(recorder.state.stats.heartRate, 142);

    // And the next accepted fix carries it into the trace, which is what the
    // detail screen and the GPX/FIT export read.
    location.emitRide(
      count: 5,
      speedMps: 5,
      start: t0.add(const Duration(seconds: 30)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final ride = await recorder.stopRide();
    final points = await database.rideDao.getTrackPoints(ride!.id);
    expect(
      points.where((p) => p.heartRate == 142),
      isNotEmpty,
      reason: 'the heart rate must reach the trace, not just the live state',
    );

    // A reading after the ride is over goes nowhere rather than into a
    // disposed engine.
    readings.add(
      SensorReading(
        type: SensorType.heartRate,
        value: 90,
        timestamp: DateTime.now().toUtc(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await recorder.dispose();
    await readings.close();
    await location.dispose();
  });

  group('the sampling profile', () {
    test('a relaxed policy is what the platform is asked for', () async {
      final location = FakeLocationService();
      final policy = SamplingPolicy(chosen: GpsAccuracyMode.high);

      // Half a minute of stillness, the way the engine's state stream would
      // drive it.
      final start = DateTime.utc(2026, 9, 25, 6);
      policy.update(speedMps: 0, at: start);
      policy.update(speedMps: 0, at: start.add(const Duration(seconds: 31)));
      expect(policy.isRelaxed, isTrue);

      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        samplingPolicy: policy,
      );

      await recorder.startRide(const AppSettings());
      expect(
        location.requestedModes,
        [GpsAccuracyMode.high],
        reason: '停车不降精度。降到均衡功耗会让卫星芯片休眠',
      );
      expect(location.requestedIntervals, [const Duration(seconds: 5)]);

      await recorder.dispose();
      await location.dispose();
    });

    test('changing the setting mid-ride re-subscribes at the new profile',
        () async {
      final location = FakeLocationService();
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
      );

      await recorder.startRide(
        const AppSettings(gpsAccuracy: GpsAccuracyMode.high),
      );
      expect(location.requestedModes, [GpsAccuracyMode.high]);

      // The rider switches to 均衡 in the settings screen while riding.
      recorder.applySettings(
        const AppSettings(gpsAccuracy: GpsAccuracyMode.balanced),
      );

      expect(
        location.requestedModes,
        [GpsAccuracyMode.high, GpsAccuracyMode.balanced],
        reason: '档位属于订阅本身，只能重新订阅',
      );

      await recorder.dispose();
      await location.dispose();
    });
  });

  /// A locked screen must not end the ride.
  ///
  /// Worth its own group because the failure it guards against is invisible
  /// when it happens: the ride screen keeps counting, the engine keeps
  /// checkpointing, and the only symptom is a trace that quietly stops growing.
  /// Both halves are about the one operation that is unsafe in the background —
  /// rebuilding the platform location subscription, which on Android has to
  /// promote a foreground service, and Android 12+ refuses to do that from the
  /// background (`stopForeground` resets the app's allowance, so the next
  /// `startForeground` re-checks the process state).
  group('a locked screen', () {
    RideRecorder buildWatched(
      FakeLocationService location, {
      FakeDiagnosticLog? diagnostics,
      Duration staleAfter = const Duration(milliseconds: 40),
    }) =>
        RideRecorder(
          db: database,
          repository: RideRepository(database),
          locationService: location,
          diagnostics: diagnostics,
          // Seconds in a real ride, milliseconds here: the watchdog is a timer
          // and waiting a real minute would make this suite unusable.
          watchdogInterval: const Duration(milliseconds: 20),
          fixStaleAfter: staleAfter,
        );

    test('the sampling profile waits for the foreground instead of re-subscribing',
        () async {
      final location = FakeLocationService();
      final policy = SamplingPolicy(chosen: GpsAccuracyMode.high);

      // Parked: the policy had already relaxed when the ride began.
      final start = DateTime.utc(2026, 9, 25, 6);
      policy.update(speedMps: 0, at: start);
      policy.update(speedMps: 0, at: start.add(const Duration(seconds: 31)));
      expect(policy.isRelaxed, isTrue);

      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        samplingPolicy: policy,
        // Not what this test is about, so it cannot fire.
        watchdogInterval: const Duration(hours: 1),
        fixStaleAfter: const Duration(hours: 1),
      );

      await recorder.startRide(const AppSettings());
      expect(location.requestedModes, [GpsAccuracyMode.high]);
      expect(location.requestedIntervals, [const Duration(seconds: 5)]);

      // The phone goes in a pocket and the rider sets off. The policy wants the
      // rider's own profile back — which is a re-subscription.
      recorder.setForeground(false);
      recorder.applySettings(
        const AppSettings(gpsAccuracy: GpsAccuracyMode.balanced),
      );

      expect(
        location.requestedModes,
        [GpsAccuracyMode.high],
        reason: '锁屏后重新订阅会降级前台服务，而 Android 12+ 不允许在后台再提升它',
      );
      expect(location.requestedIntervals, [const Duration(seconds: 5)]);

      recorder.setForeground(true);

      expect(
        location.requestedModes,
        [GpsAccuracyMode.high, GpsAccuracyMode.balanced],
        reason: '回到前台必须把推迟的档位补上，而不是一直停在停车间隔',
      );
      expect(location.requestedIntervals, [
        const Duration(seconds: 5),
        const Duration(seconds: 2),
      ]);

      await recorder.dispose();
      await location.dispose();
    });

    test('a stream that goes quiet in the foreground rebuilds itself', () async {
      final location = FakeLocationService();

      // The timer is real; the *decision* runs off a clock this test drives.
      // That is what makes the backoff below assertable — otherwise it would
      // be a race between a 20 ms timer and the test's own delays.
      var now = DateTime.utc(2026, 9, 25, 6);
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        now: () => now,
        watchdogInterval: const Duration(milliseconds: 1),
        fixStaleAfter: const Duration(seconds: 60),
      );

      await recorder.startRide(const AppSettings());
      expect(location.requestedModes.length, 1);

      // The platform stops delivering: an OEM ROM reclaimed the service, the
      // receiver never came back from a tunnel, a promotion was refused.
      now = now.add(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        location.requestedModes.length,
        2,
        reason: '断流必须自愈，否则骑行会安静地不再记录任何点',
      );

      // Silence has two causes — a dead stream and a blocked sky — and the
      // watchdog cannot tell them apart. Rebuilding throws away a live
      // subscription and restarts the receiver, so the next attempt waits
      // twice as long. A tunnel must not be punished with a rebuild every
      // minute.
      now = now.add(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        location.requestedModes.length,
        2,
        reason: '第一次重建没用上，下一次就要等更久',
      );

      now = now.add(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        location.requestedModes.length,
        3,
        reason: '退避翻倍之后应当再试一次，而不是放弃',
      );

      await recorder.dispose();
      await location.dispose();
    });

    test('a live stream is never rebuilt, however slow it is', () async {
      final location = FakeLocationService();

      var now = DateTime.utc(2026, 9, 25, 6);
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        now: () => now,
        watchdogInterval: const Duration(milliseconds: 1),
        fixStaleAfter: const Duration(seconds: 60),
      );

      await recorder.startRide(const AppSettings());
      await recorder.beginRecording();

      // Fixes well inside the tolerance: the stationary profile's five-second
      // interval is the slowest one that ships, and it must never look like a
      // dead stream.
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(seconds: 5));
        location.emitRide(count: 1, speedMps: 0, start: now);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(
        location.requestedModes,
        [GpsAccuracyMode.high],
        reason: '只要还在收到定位就不能重建，否则会打断一条正常的订阅',
      );

      await recorder.dispose();
      await location.dispose();
    });

    test('a stream that dies while locked is left alone until unlock', () async {
      final location = FakeLocationService();
      final log = FakeDiagnosticLog();
      final recorder = buildWatched(location, diagnostics: log);

      await recorder.startRide(const AppSettings());
      recorder.setForeground(false);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        location.requestedModes,
        [GpsAccuracyMode.high],
        reason: '后台重建订阅正是会失败的那个操作，宁可不做',
      );
      expect(
        log.content,
        contains('location_stream_stalled'),
        reason: '后台断流必须留下记录，否则事后没有任何线索',
      );

      recorder.setForeground(true);

      expect(
        location.requestedModes.length,
        greaterThan(1),
        reason: '解锁后应当立刻自愈，让剩下的骑行继续记录',
      );

      await recorder.dispose();
      await location.dispose();
    });
  });

  test('discarding a ride leaves nothing behind', () async {
    final location = FakeLocationService();
    final recorder = buildRecorder(location);

    await recorder.startRide(const AppSettings());
    await recorder.beginRecording();
    location.emitRide(count: 30, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await recorder.saveCheckpointNow();

    await recorder.discardRide();

    expect(await database.rideDao.getRides(), isEmpty);
    expect(await recorder.findUnfinishedRide(), isNull);
    expect(await database.syncQueueDao.pendingCount(), 0);

    await recorder.dispose();
    await location.dispose();
  });

  test('a ride that fails to start writes nothing', () async {
    final location = FakeLocationService(
      permission: LocationPermissionStatus.deniedForever,
    );
    final recorder = buildRecorder(location);

    expect(await recorder.startRide(const AppSettings()), isFalse);
    expect(recorder.engine, isNull);
    expect(await database.rideDao.getRides(), isEmpty);

    await recorder.dispose();
    await location.dispose();
  });

  test('stopping a ride that never started returns nothing', () async {
    final location = FakeLocationService();
    final recorder = buildRecorder(location);

    expect(await recorder.stopRide(), isNull);
    expect(await database.rideDao.getRides(), isEmpty);

    await recorder.dispose();
    await location.dispose();
  });
}

class _BlockingCheckpointDao extends ActiveRideDao {
  _BlockingCheckpointDao(super.db);

  bool blockNext = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> save(RideCheckpoint checkpoint) async {
    if (blockNext) {
      blockNext = false;
      entered.complete();
      await release.future;
    }
    await super.save(checkpoint);
  }
}

class _ListeningBarometer implements BarometerSource {
  final controller = StreamController<BarometerSample>.broadcast();
  @override
  Future<bool> isAvailable() async => true;
  @override
  Stream<BarometerSample> samples() => controller.stream;
}

class _ListeningCompass implements CompassSource {
  final controller = StreamController<CompassSample>.broadcast();
  @override
  Future<bool> isAvailable() async => true;
  @override
  Stream<CompassSample> samples() => controller.stream;
}

class _ListeningMotion implements MotionSource {
  final controller = StreamController<MotionSample>.broadcast();
  @override
  Future<bool> isAvailable() async => true;
  @override
  Stream<MotionSample> samples() => controller.stream;
}
