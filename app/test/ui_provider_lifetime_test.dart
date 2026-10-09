import 'package:cycling_app/app/providers.dart';
import 'package:cycling_app/features/ride/domain/ride_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'detail dependency chain releases full traces after screen closes',
    () async {
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: testOverrides(database: db),
      );
      final geometry = container.listen(
        trackGeometryProvider('ride-a'),
        (_, _) {},
      );
      final elevation = container.listen(
        elevationSamplesProvider('ride-a'),
        (_, _) {},
      );
      final quality = container.listen(
        elevationQualityProvider('ride-a'),
        (_, _) {},
      );
      final ride = container.listen(rideProvider('ride-a'), (_, _) {});
      await container.pump();
      expect(container.exists(trackPointsProvider('ride-a')), isTrue);
      geometry.close();
      elevation.close();
      quality.close();
      ride.close();
      await container.pump();
      expect(container.exists(trackGeometryProvider('ride-a')), isFalse);
      expect(container.exists(elevationSamplesProvider('ride-a')), isFalse);
      expect(container.exists(elevationQualityProvider('ride-a')), isFalse);
      expect(container.exists(trackPointsProvider('ride-a')), isFalse);
      expect(container.exists(rideProvider('ride-a')), isFalse);
      container.dispose();
      await db.close();
    },
  );

  test('UI detaches while the recording session stays alive', () async {
    final db = openTestDatabase();
    final location = FakeLocationService();
    final container = ProviderContainer(
      overrides: testOverrides(database: db, location: location),
    );
    final screen = container.listen(rideStateProvider, (_, _) {});
    final session = container.read(rideSessionInstanceProvider);
    expect(await container.read(rideSessionProvider.notifier).start(), isTrue);
    container.read(rideSessionProvider.notifier).beginRecording();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    screen.close();
    await container.pump();
    expect(container.exists(rideStateProvider), isFalse);
    expect(container.exists(rideSessionProvider), isTrue);
    expect(container.exists(rideRecorderProvider), isTrue);
    expect(
      identical(container.read(rideSessionInstanceProvider), session),
      isTrue,
    );
    location.emitRide(count: 4, speedMps: 5);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(rideSessionProvider).ride.status, RideStatus.riding);
    expect(
      container.read(rideSessionProvider).ride.acceptedPointCount,
      greaterThan(0),
    );
    await container.read(rideSessionProvider.notifier).discard();
    container.dispose();
    await location.dispose();
    await db.close();
  });
}
