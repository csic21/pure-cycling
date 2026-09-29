import 'dart:async';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/core/location/sampling_policy.dart';
import 'package:cycling_app/core/sync/sync_status.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
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
