import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/sync/sync_service.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/routes/data/route_repository.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cloud-sync switch is a product promise, and this is what keeps it.
///
/// The switch has been in the settings screen since the first version, but
/// the service never read it: with it off, six different triggers still
/// uploaded (network returning, the retry timer, app resume, login,
/// pull-to-refresh, the manual button). The assertions here are deliberately
/// about *not doing work* — the client is not even resolved — because "off"
/// has to mean no network attempt at all, not an attempt that happens to be
/// skipped later.
void main() {
  late AppDatabase database;
  late bool clientRequested;
  late SyncService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    clientRequested = false;
    service = SyncService(
      db: database,
      rides: RideRepository(database),
      routes: RouteRepository(database),
      resolveClient: () {
        clientRequested = true;
        return null;
      },
    );
  });

  tearDown(() async {
    await service.dispose();
    await database.close();
  });

  test('with the switch off, nothing is uploaded and no client is resolved',
      () async {
    service.applySettings(const AppSettings());

    final report = await service.syncNow();

    expect(report.phase, SyncPhase.disabled);
    expect(report.uploaded, 0);
    expect(clientRequested, isFalse,
        reason: '关闭后连客户端都不该解析，更不用谈发请求');
  });

  test('the manual button cannot bypass the switch either', () async {
    service.applySettings(const AppSettings());

    final report = await service.syncNow(force: true);

    expect(report.phase, SyncPhase.disabled);
    expect(clientRequested, isFalse,
        reason: '带旁路的承诺不是承诺 —— force 只用于绕过仅 Wi-Fi 限制');
  });

  test('with the switch on, the gate lets the cycle through to the client',
      () async {
    service.applySettings(const AppSettings(cloudSync: true));

    final report = await service.syncNow();

    expect(clientRequested, isTrue);
    // No Supabase configuration exists under `flutter test`, so the cycle
    // stops at the next gate — which is exactly what proves this one opened.
    expect(report.phase, SyncPhase.notConfigured);
  });
}
