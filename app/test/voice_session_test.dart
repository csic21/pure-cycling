import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/map/local/offline_providers.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/data/ride_session.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_voice_backend.dart';
import 'support/test_harness.dart';

/// The seam between the ride session, the navigation engine and the voice
/// coach.
///
/// The coach's policy is covered exhaustively in `voice_coach_test.dart` on
/// synthetic snapshots, and none of that proves the session ever feeds it a
/// snapshot. That is exactly the class of bug this project has been bitten by
/// before: everything unit-tested, nothing wired.
void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());
  tearDown(() => database.close());

  const origin = GeoPoint(39.9042, 116.4074);

  /// A straight north route with a single left turn halfway along.
  ///
  /// North because that is the direction [FakeLocationService.emitRide] rides.
  Route northRoute() {
    final points = [
      for (var i = 0; i <= 40; i++)
        GeoPoint(origin.lat + i * 25 / 111132.0, origin.lng),
    ];
    return Route(
      id: 'route-north',
      name: '北向路线',
      points: points,
      distanceMeters: 1000,
      estimatedDuration: const Duration(minutes: 4),
      instructions: [
        RouteInstruction(
          index: 0,
          maneuver: Maneuver.left,
          text: '左转进入人民大道',
          distanceMeters: 500,
          durationSeconds: 120,
          startPolylineIndex: 20,
          endPolylineIndex: 40,
          roadName: '人民大道',
        ),
      ],
      provider: 'test',
    );
  }

  test('a ride with a route speaks its turn through the session', () async {
    final location = FakeLocationService();
    final backend = FakeVoiceBackend();
    const settings = AppSettings(
      navigation: NavigationConfig(voicePrompts: true),
    );

    final session = RideSession(
      recorder: RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
      ),
      routeProvider: () => const OfflineRouteProvider(),
      settings: settings,
      voiceBackend: backend,
    );

    expect(
      await session.start(route: northRoute(), settings: settings),
      isTrue,
    );
    await session.recorder.beginRecording();

    // 60 fixes at 5 m/s is 300 m along the route — past the far announcement
    // band at 250 m, but not yet at the turn.
    location.emitRide(count: 60, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      backend.spoken.any((line) => line.contains('左转进入人民大道')),
      isTrue,
      reason: 'the session must feed navigation snapshots to the coach, or '
          'the toggle in settings promises something that never happens',
    );

    await session.dispose();
    await location.dispose();
  });

  test('nothing is spoken when the rider left voice prompts off', () async {
    final location = FakeLocationService();
    final backend = FakeVoiceBackend();

    final session = RideSession(
      recorder: RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
      ),
      routeProvider: () => const OfflineRouteProvider(),
      settings: const AppSettings(),
      voiceBackend: backend,
    );

    await session.start(route: northRoute(), settings: const AppSettings());
    await session.recorder.beginRecording();
    location.emitRide(count: 60, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(backend.spoken, isEmpty);

    await session.dispose();
    await location.dispose();
  });
}
