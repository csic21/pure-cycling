import 'dart:async';

import 'package:cycling_app/app/providers.dart';
import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/location_fix.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/core/sync/sync_service.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/ride_engine.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared fixtures for the widget tests.
///
/// Two things every widget test in this project needs, and neither is obvious:
///
/// * **An in-memory database.** The real one writes to the app documents
///   directory, which does not exist under `flutter test`.
/// * **A location service that does not touch the platform.** `geolocator`
///   needs a plugin registration and a permission dialog, neither of which
///   exists in a test binding — calling it throws a `MissingPluginException`
///   from somewhere deep and unhelpful.
///
/// The rest of the wiring is left real on purpose: the repositories, the
/// providers, the router and the screens are the things under test.

/// A location service that grants permission and answers from a stream the
/// test controls.
class FakeLocationService extends LocationService {
  FakeLocationService({this.permission = LocationPermissionStatus.granted});

  LocationPermissionStatus permission;

  final _controller = StreamController<LocationFix>.broadcast();
  bool streamOpened = false;
  bool appSettingsOpened = false;

  /// Pushes a fix, as the platform would.
  void emit(LocationFix fix) {
    if (!_controller.isClosed) _controller.add(fix);
  }

  /// Pushes [count] fixes one second apart, moving [speedMps] each second.
  ///
  /// Timestamps advance by a second per sample, because the engine derives
  /// speed from the gap between them and a widget test's clock barely moves.
  ///
  /// But they start from **now**, not from a fixed date. The engine compares
  /// the newest fix against the wall clock to decide whether the signal has
  /// been lost, and fixes stamped in the past look exactly like a receiver
  /// that stopped reporting — the ride decays its displayed speed to zero and
  /// the test fails for a reason that has nothing to do with the code.
  void emitRide({
    required int count,
    required double speedMps,
    GeoPoint origin = const GeoPoint(39.9042, 116.4074),
    DateTime? start,
  }) {
    final t0 = start ?? DateTime.now().toUtc();
    var travelled = 0.0;
    for (var i = 1; i <= count; i++) {
      travelled += speedMps;
      emit(
        LocationFix(
          latitude: origin.lat + travelled / 111132.0,
          longitude: origin.lng,
          timestamp: t0.add(Duration(seconds: i)),
          accuracy: 4,
          speed: speedMps,
          altitude: 50,
        ),
      );
    }
  }

  @override
  Future<LocationPermissionStatus> ensurePermission({
    bool requestBackground = true,
  }) async =>
      permission;

  @override
  Future<LocationPermissionStatus> checkPermission() async => permission;

  @override
  Future<LocationFix?> currentFix({
    Duration timeout = const Duration(seconds: 12),
    GpsAccuracyMode mode = GpsAccuracyMode.high,
  }) async =>
      null;

  @override
  Stream<LocationFix> fixes({
    GpsAccuracyMode mode = GpsAccuracyMode.high,
    bool background = true,
  }) {
    streamOpened = true;
    return _controller.stream;
  }

  @override
  Future<bool> openAppSettings() async {
    appSettingsOpened = true;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async => true;

  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Provider overrides that make the app testable without a device.
///
/// `syncReportProvider` is overridden rather than `syncServiceProvider`: the
/// real `start()` registers a connectivity listener, and `connectivity_plus`
/// has no plugin in a test binding. Overriding the report provider means the
/// sync service is never started, while every other provider stays real.
List<Override> testOverrides({
  required AppDatabase database,
  FakeLocationService? location,
}) {
  return [
    databaseProvider.overrideWithValue(database),
    if (location != null) locationServiceProvider.overrideWithValue(location),
    syncReportProvider.overrideWith(
      (ref) => const Stream<SyncReport>.empty(),
    ),
  ];
}

/// Advances far enough for a drift query to resolve and a route to finish
/// animating.
///
/// **`pumpAndSettle` is unusable here**, and the reason is worth writing down:
/// every screen renders a `CircularProgressIndicator` while its stream is
/// loading. A progress indicator animates forever, so "no frames are
/// scheduled" never becomes true, and `pumpAndSettle` blocks until its
/// ten-minute timeout. That failure produces no output at all — it looks like
/// the test runner has hung.
///
/// The duration is what actually needs covering, and there are two things:
///
/// * **A drift query** needs one turn of the event loop to run and one frame
///   to render. Two pumps.
/// * **A route transition** takes 300 ms, and until it finishes the outgoing
///   screen is still on stage. Assert with too little time and a text that
///   exists on both screens is found twice — or a text on the incoming screen
///   is not found at all.
///
/// 600 ms covers both with room to spare.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Gives the test a viewport tall enough that no list needs scrolling.
///
/// These are smoke tests: the question is whether each screen renders without
/// throwing, not whether a particular row happens to be above the fold. The
/// default 800×600 surface is smaller than most of these screens, and that
/// causes two failures that look like app bugs and are not:
///
/// * A `ListView` only inflates its *visible* children, so `find.text` returns
///   nothing for a row that exists but is off-screen.
/// * A row that falls under the bottom navigation bar gets its tap stolen by
///   the nav bar — tapping 「OLED 模式」 navigates to the history tab.
///
/// Phone width, very generous height: 400 × 1800 logical pixels. The settings
/// list is the longest screen in the app and overflows anything shorter.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 5400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// A fresh in-memory database. The caller owns closing it.
AppDatabase openTestDatabase() => AppDatabase.forTesting(NativeDatabase.memory());

/// Tears a widget test down in the order the binding requires.
///
/// The order is not optional. Disposing the tree while drift's query streams
/// are still open makes drift schedule a zero-duration cleanup timer, and the
/// test binding asserts at the end of the body that no timers are pending —
/// so the tree has to come down first and the timer has to be allowed to fire
/// before the test returns. Getting this wrong produces
/// "A Timer is still pending even after the widget tree was disposed", which
/// reads like a leak in the app rather than a teardown ordering problem.
///
/// Closing the database in a `tearDown` callback does not work: tear-downs run
/// after the invariant check.
Future<void> shutdownApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // `settle`, not a single pump: tearing down a screen with a pushed route on
  // top of it cancels more drift streams than the home screen does, and each
  // cancellation schedules its own cleanup timer.
  await settle(tester);
  await database.close();
  await tester.pump(const Duration(milliseconds: 1));
}

/// Builds the checkpoint a crash would leave behind.
///
/// The numbers are deliberately mid-ride rather than round: the resume sheet
/// is meant to show a rider what they nearly lost, and a fixture of zeros
/// would let a display bug through.
abstract final class RideCheckpointFixture {
  static RideCheckpoint build({
    String rideId = 'unfinished',
    double distanceMeters = 6400,
  }) {
    final started = DateTime.utc(2026, 9, 23, 6, 30);
    return RideCheckpoint(
      rideId: rideId,
      status: RideStatus.riding.name,
      startedAt: started,
      elapsed: const Duration(minutes: 22, seconds: 14),
      moving: const Duration(minutes: 20, seconds: 2),
      distanceMeters: distanceMeters,
      maxSpeedMps: 9.4,
      elevationGainMeters: 118,
      elevationLossMeters: 74,
      lastLat: 39.9042,
      lastLng: 116.4074,
      lastAltitude: 51,
      lastSequence: 1334,
      smoothedSpeedMps: 5.1,
      smoothedAltitudeMeters: 51,
      anchorLat: 39.9042,
      anchorLng: 116.4074,
      anchorTimestampMs: started.millisecondsSinceEpoch + 1334000,
    );
  }
}

/// Inserts a finished ride with a plausible trace.
///
/// Used by the history and detail tests, which need something to render rather
/// than something to record.
Future<Ride> seedRide(
  AppDatabase database, {
  String id = '0192f3a0-0000-7000-8000-000000000001',
  String? name,
  DateTime? startedAt,
  double distanceMeters = 23820,
  Duration moving = const Duration(minutes: 62, seconds: 36),
  double elevationGain = 384,
  int trackPoints = 40,
  double? verticalAccuracy = 2.5,
}) async {
  final start = startedAt ?? DateTime.utc(2026, 9, 23, 6, 30);

  final ride = Ride(
    id: id,
    name: name,
    startedAt: start,
    endedAt: start.add(moving),
    stats: RideStats(
      distanceMeters: distanceMeters,
      elapsed: moving + const Duration(minutes: 4),
      moving: moving,
      avgSpeedMps: distanceMeters / moving.inSeconds,
      maxSpeedMps: 10.7,
      altitudeMeters: 62,
      elevationGainMeters: elevationGain,
      elevationLossMeters: elevationGain - 12,
      gradePercent: 1.8,
    ),
    startPoint: const GeoPoint(39.9042, 116.4074),
    endPoint: const GeoPoint(39.9142, 116.4174),
    createdAt: start,
    updatedAt: start,
  );

  await database.rideDao.upsertRide(ride);
  await database.rideDao.insertTrackPoints([
    for (var i = 1; i <= trackPoints; i++)
      TrackPoint(
        rideId: id,
        sequence: i,
        timestamp: start.add(Duration(seconds: i * 10)),
        lat: 39.9042 + i * 2.5 / 111132.0,
        lng: 116.4074 + i * 1.0 / 85300.0,
        altitude: 50 + i * 1.5,
        speed: 6.3,
        // Reported as precise, so the climb total is presented as a
        // measurement rather than as an estimate. Pass null to simulate a
        // phone that reports no vertical accuracy at all.
        verticalAccuracy: verticalAccuracy,
      ),
  ]);

  return ride;
}
