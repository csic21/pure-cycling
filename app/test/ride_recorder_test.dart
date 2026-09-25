import 'dart:async';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/core/sync/sync_status.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/sensors/domain/sensor.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

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
