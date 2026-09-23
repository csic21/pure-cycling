import 'package:cycling_app/core/utils/units.dart';
import 'package:cycling_app/features/dashboard/domain/dashboard_config.dart';
import 'package:cycling_app/features/dashboard/domain/dashboard_field.dart';
import 'package:cycling_app/features/navigation/domain/navigation_state.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two things are checked here that are easy to get subtly wrong and hard to
/// notice: number formatting (which a rider compares against their friends'
/// screens) and settings persistence (which decides whether a preference
/// survives a restart).
void main() {
  const metric = UnitFormatter(UnitSystem.metric);
  const imperial = UnitFormatter(UnitSystem.imperial);

  group('distance', () {
    test('switches to metres below a kilometre', () {
      expect(metric.distance(0), '0');
      expect(metric.distance(420), '420');
      expect(metric.distance(999), '999');
      expect(metric.distance(1000), '1.00');
      expect(metric.distance(23820), '23.82');
      expect(metric.distanceUnit(420), 'm');
      expect(metric.distanceUnit(23820), 'km');
    });

    test('converts to miles and feet', () {
      // 1609.344 m is exactly one mile.
      expect(imperial.distance(1609.344), '1.00');
      expect(imperial.distanceUnit(1609.344), 'mi');
      // 100 m is 328 feet, which reads better than "0.06 miles".
      expect(imperial.distance(100), '328');
      expect(imperial.distanceUnit(100), 'ft');
    });

    test('never renders a non-finite value', () {
      expect(metric.distance(double.nan), '--');
      expect(metric.distance(double.infinity), '--');
    });
  });

  group('speed', () {
    test('converts metres per second to km/h', () {
      // 10 m/s is 36 km/h.
      expect(metric.speed(10), '36.0');
      expect(metric.speedWhole(10), '36');
      expect(metric.speed(0), '0.0');
    });

    test('converts to miles per hour', () {
      // 10 m/s is 22.37 mph.
      expect(imperial.speed(10), '22.4');
    });
  });

  group('elevation', () {
    test('uses metres and feet', () {
      expect(metric.elevation(384), '384');
      expect(metric.elevationWithUnit(384), '384 m');
      expect(imperial.elevation(384), '1260');
      expect(imperial.elevationWithUnit(384), '1260 ft');
    });

    test('optionally carries a sign, for a climb figure', () {
      expect(metric.elevation(384, withSign: true), '+384');
      expect(metric.elevation(0, withSign: true), '0');
      expect(metric.elevation(-12, withSign: true), '-12');
    });
  });

  group('duration', () {
    test('formats as a bike computer does', () {
      expect(UnitFormatter.duration(Duration.zero), '0:00');
      expect(UnitFormatter.duration(const Duration(seconds: 59)), '0:59');
      expect(UnitFormatter.duration(const Duration(minutes: 1)), '1:00');
      expect(
        UnitFormatter.duration(const Duration(minutes: 62, seconds: 36)),
        '1:02:36',
      );
      expect(
        UnitFormatter.duration(const Duration(hours: 10, minutes: 5)),
        '10:05:00',
      );
    });

    test('compacts for dense rows', () {
      expect(UnitFormatter.durationCompact(const Duration(seconds: 45)), '45s');
      expect(UnitFormatter.durationCompact(const Duration(minutes: 48)), '48m');
      expect(
        UnitFormatter.durationCompact(const Duration(minutes: 112)),
        '1h 52m',
      );
      expect(UnitFormatter.durationCompact(const Duration(hours: 3)), '3h');
    });

    test('rounds to minutes for an arrival estimate', () {
      // Seconds of precision on an ETA would be false confidence.
      expect(UnitFormatter.durationMinutes(const Duration(seconds: 100)), '2 min');
      expect(UnitFormatter.durationMinutes(const Duration(minutes: 92)), '1h 32m');
      expect(UnitFormatter.durationMinutes(const Duration(hours: 2)), '2h');
    });
  });

  group('dashboard fields', () {
    const data = DashboardData(
      stats: RideStats(
        distanceMeters: 23820,
        elapsed: Duration(minutes: 62, seconds: 36),
        moving: Duration(minutes: 60),
        currentSpeedMps: 7.944,
        avgSpeedMps: 6.361,
        maxSpeedMps: 10.722,
        altitudeMeters: 62,
        elevationGainMeters: 384,
        gradePercent: 1.8,
        heartRate: 142,
      ),
      gpsAccuracyMeters: 6,
    );

    test('formats values in the rider\'s chosen units', () {
      expect(DashboardField.speed.format(data, metric), '28.6');
      expect(DashboardField.speed.format(data, imperial), '17.8');
      expect(DashboardField.distance.format(data, metric), '23.82');
      expect(DashboardField.movingTime.format(data, metric), '1:00:00');
      expect(DashboardField.elevationGain.format(data, metric), '+384');
    });

    test('shows a dash rather than hiding an unavailable sensor', () {
      // The layout must not reflow when a heart rate strap drops out.
      expect(DashboardField.cadence.format(data, metric), '--');
      expect(DashboardField.cadence.isAvailable(data), isFalse);
      expect(DashboardField.heartRate.isAvailable(data), isTrue);
    });

    test('shows a dash for route fields when not navigating', () {
      expect(DashboardField.distanceToNextTurn.format(data, metric), '--');
      expect(DashboardField.eta.isAvailable(data), isFalse);
    });

    test('populates route fields while navigating', () {
      final navigating = data.copyWith(
        navigation: NavigationSnapshot(
          routeId: 'r',
          routeName: 'n',
          distanceToDestinationMeters: 8200,
          distanceToNextTurnMeters: 180,
          eta: DateTime(2026, 9, 23, 14, 5),
        ),
      );

      expect(DashboardField.distanceToDestination.format(navigating, metric), '8.20');
      expect(DashboardField.distanceToNextTurn.format(navigating, metric), '180');
      expect(DashboardField.eta.format(navigating, metric), '14:05');
      expect(DashboardField.eta.isAvailable(navigating), isTrue);
    });

    test('every field has an id that round-trips', () {
      // The ids are persisted in `dashboard_config`; changing one silently
      // invalidates every rider's layout.
      for (final field in DashboardField.values) {
        expect(DashboardField.fromId(field.id), field);
      }
      expect(DashboardField.fromId('nonexistent'), isNull);
    });

    test('every field formats without throwing', () {
      for (final field in DashboardField.values) {
        expect(() => field.format(data, metric), returnsNormally);
        expect(() => field.unitLabel(data, metric), returnsNormally);
      }
    });
  });

  group('dashboard config', () {
    test('ships three pages, matching the spec', () {
      final config = DashboardConfig.defaults;

      expect(config.pages.length, 3);
      expect(config.pages[0].fields.first, DashboardField.speed);
      expect(config.pages[1].fields.first, DashboardField.altitude);
      expect(config.pages[2].layout, DashboardLayout.grid6);
    });

    test('round-trips through JSON', () {
      final encoded = DashboardConfig.defaults.encode();
      final decoded = DashboardConfig.decode(encoded);

      expect(decoded.pages.length, 3);
      expect(
        decoded.pages.first.fields,
        DashboardConfig.defaults.pages.first.fields,
      );
      expect(decoded.pages.first.layout, DashboardLayout.hero4);
    });

    test('falls back to the defaults on a corrupt value', () {
      // A config that cannot be parsed must not brick the ride screen.
      expect(DashboardConfig.decode('{not json').pages.length, 3);
      expect(DashboardConfig.decode('').pages.length, 3);
      expect(DashboardConfig.decode(null).pages.length, 3);
      expect(DashboardConfig.decode('{"pages":[]}').pages.length, 3);
    });

    test('drops unknown field ids without losing the page', () {
      const raw = '{"pages":[{"layout":"hero_4",'
          '"fields":["speed","from_a_future_version","distance"]}]}';

      final decoded = DashboardConfig.decode(raw);

      expect(decoded.pages.length, 1);
      // The two known fields survive; the unknown one is dropped rather than
      // crashing the parse.
      expect(decoded.pages.first.fields.length, 2);
      expect(decoded.pages.first.fields.first, DashboardField.speed);
    });

    test('pads a short field list so the geometry stays put', () {
      const page = DashboardPage(
        layout: DashboardLayout.hero4,
        fields: [DashboardField.speed, DashboardField.distance],
      );

      expect(page.resolvedFields().length, 5);
      expect(page.heroField, DashboardField.speed);
      expect(page.supportingFields().length, 4);
    });

    test('a grid layout has no hero', () {
      final page = DashboardPage.defaultFor(DashboardLayout.grid6);
      expect(page.heroField, isNull);
      expect(page.supportingFields().length, 6);
    });
  });

  group('settings persistence', () {
    test('survives a round trip through the key/value store', () {
      const original = AppSettings(
        units: UnitSystem.imperial,
        autoPause: false,
        startCountdown: StartCountdown.off,
        gpsAccuracy: GpsAccuracyMode.batterySaver,
        oledMode: false,
        pixelShift: false,
        dimOnStandstill: false,
        minimalOled: true,
        keepScreenOn: false,
        gpsSignalLostSeconds: 45,
        maxAcceptableAccuracyMeters: 35,
      );

      final restored = AppSettings.fromKeyValues(original.toKeyValues());

      expect(restored.units, UnitSystem.imperial);
      expect(restored.autoPause, isFalse);
      expect(restored.startCountdown, StartCountdown.off);
      expect(restored.gpsAccuracy, GpsAccuracyMode.batterySaver);
      expect(restored.oledMode, isFalse);
      expect(restored.pixelShift, isFalse);
      expect(restored.minimalOled, isTrue);
      expect(restored.keepScreenOn, isFalse);
      expect(restored.gpsSignalLostSeconds, 45);
      expect(restored.maxAcceptableAccuracyMeters, 35);
    });

    test('preserves the dashboard and navigation configs', () {
      final original = AppSettings(
        dashboard: DashboardConfig.defaults.copyWith(
          pages: [DashboardPage.defaultFor(DashboardLayout.hero2)],
        ),
        navigation: const NavigationConfig(
          autoShowMap: false,
          rerouteThresholdMeters: 80,
          autoMapDismissSeconds: 12,
        ),
      );

      final restored = AppSettings.fromKeyValues(original.toKeyValues());

      expect(restored.dashboard.pages.length, 1);
      expect(restored.dashboard.pages.first.layout, DashboardLayout.hero2);
      expect(restored.navigation.autoShowMap, isFalse);
      expect(restored.navigation.rerouteThresholdMeters, 80);
      expect(restored.navigation.autoMapDismissSeconds, 12);
    });

    test('an unknown key is ignored rather than fatal', () {
      // An older build reading a newer build's database.
      final restored = AppSettings.fromKeyValues({
        'units': 'metric',
        'a_setting_from_the_future': 'true',
      });

      expect(restored.units, UnitSystem.metric);
      expect(restored.autoPause, isTrue, reason: 'falls back to the default');
    });

    test('a garbage value falls back instead of throwing', () {
      final restored = AppSettings.fromKeyValues({
        'auto_pause': 'yes please',
        'gps_lost_s': 'soon',
        'navigation_config': 'not json',
      });

      expect(restored.autoPause, isTrue);
      expect(restored.gpsSignalLostSeconds, 15);
      expect(restored.navigation.autoShowMap, isTrue);
    });

    test('an empty store yields the documented defaults', () {
      final restored = AppSettings.fromKeyValues(const {});

      expect(restored.units, UnitSystem.metric);
      expect(restored.autoPause, isTrue);
      expect(restored.oledMode, isTrue);
      expect(restored.pixelShift, isTrue);
      expect(restored.startCountdown, StartCountdown.threeSeconds);
      expect(restored.gpsAccuracy, GpsAccuracyMode.high);
      expect(restored.autoPauseSpeedThresholdKph, 2.0);
      expect(restored.autoResumeSpeedThresholdKph, 3.0);
      expect(restored.dashboard.pages.length, 3);
    });
  });

  group('sync status', () {
    test('round-trips through its persisted id', () {
      for (final status in SyncStatus.values) {
        expect(SyncStatus.fromId(status.id), status);
      }
    });

    test('treats an unknown id as local-only rather than as synced', () {
      // Failing safe here matters: the opposite default would make the app
      // believe an unsynced ride had reached the cloud.
      expect(SyncStatus.fromId('nonsense'), SyncStatus.localOnly);
      expect(SyncStatus.fromId(null), SyncStatus.localOnly);
    });

    test('knows which statuses mean work is outstanding', () {
      expect(SyncStatus.pendingUpload.isPending, isTrue);
      expect(SyncStatus.syncFailed.isPending, isTrue);
      expect(SyncStatus.synced.isPending, isFalse);
      expect(SyncStatus.localOnly.isPending, isFalse);
    });
  });
}
