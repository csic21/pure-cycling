import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
// `show` rather than a bare import: the Supabase SDK also exports a type
// called `AuthUser`, and this file's own `AuthUser` is the one in play.
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, Supabase;

import '../core/database/database.dart';
import '../core/diagnostics/diagnostic_log.dart';
import '../core/elevation/elevation_provider.dart';
import '../core/diagnostics/failure_reporter.dart';
import '../core/location/barometer_source.dart';
import '../core/location/elevation_tuning.dart';
import '../core/location/location_service.dart';
import '../core/map/amap/amap_client.dart';
import '../core/map/amap/amap_place_provider.dart';
import '../core/map/amap/amap_relay_client.dart';
import '../core/map/amap/amap_route_provider.dart';
import '../core/map/amap/amap_traffic_light_provider.dart';
import '../core/map/local/offline_providers.dart';
import '../core/map/map_providers.dart';
import '../core/permissions/notification_permission.dart';
import '../core/sync/functions_config.dart';
import '../core/sync/supabase_config.dart';
import '../core/sync/account_deletion_client.dart';
import '../core/sync/sync_service.dart';
import '../core/utils/geo.dart';
import '../core/utils/units.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/dashboard/domain/dashboard_config.dart';
import '../features/dashboard/domain/dashboard_field.dart';
import '../features/navigation/data/flutter_tts_voice_backend.dart';
import '../features/navigation/domain/navigation_state.dart';
import '../features/navigation/domain/voice_backend.dart';
import '../features/ride/data/ride_recorder.dart';
import '../features/ride/data/ride_repository.dart';
import '../features/ride/data/ride_session.dart';
import '../features/ride/domain/elevation_accumulator.dart';
import '../features/ride/domain/ride.dart';
import '../features/ride/domain/ride_engine.dart';
import '../features/ride/domain/track_point.dart';
import '../features/routes/data/route_repository.dart';
import '../features/routes/domain/route.dart';
import '../features/sensors/data/sensor_manager.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/settings/domain/app_settings.dart';

// ---------------------------------------------------------------------------
// Infrastructure
// ---------------------------------------------------------------------------

/// The local database. One instance for the process; drift handles its own
/// connection pooling and WAL.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final locationServiceProvider = Provider<LocationService>(
  (ref) => LocationService(),
);

/// The phone's own barometer.
///
/// Unlike the BLE sensors there is nothing to pair, so the only reason to
/// replace it is a test or a platform without a barometer implementation.
final barometerSourceProvider = Provider<BarometerSource>((ref) {
  // The channel is implemented for Android and iOS. macOS has a barometer in
  // some MacBooks but no implementation here, and asking anyway would report a
  // missing plugin on every ride — the app already knows how to ride without
  // one.
  final platform = defaultTargetPlatform;
  if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
    return const NullBarometerSource();
  }
  return const PlatformBarometerSource();
});

/// Whether this phone has a barometer, for the sensors screen.
///
/// Read once and cached: the answer cannot change while the app runs, and the
/// probe costs a brief listen on the sensor.
final barometerAvailabilityProvider = FutureProvider<bool>(
  (ref) => ref.watch(barometerSourceProvider).isAvailable(),
);

/// The Android 13+ grant behind the recording notification.
final notificationPermissionProvider = Provider<NotificationPermission>(
  (ref) => const NotificationPermission(),
);

/// The version the rider sees in the About screen.
///
/// Read from the platform bundle rather than kept as a constant: the number in
/// the app and the number in the store listing are then the same one, without
/// anybody having to remember to update two places.
///
/// Null when there is nothing to read — a widget test has no plugin registry,
/// and an unbuilt tree has no bundle — and the screen says 「开发版本」 rather
/// than showing a made-up number.
final appVersionProvider = FutureProvider<String?>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version.isEmpty ? null : info.version;
  } catch (_) {
    return null;
  }
});

/// Terrain heights for planned routes, when the rider has allowed it.
///
/// Null when the setting is off: nothing about a route leaves the device, and
/// the route screens keep showing `—` with the reason they always gave.
final elevationProviderProvider = Provider<ElevationProvider>((ref) {
  if (!ref.watch(currentSettingsProvider).routeElevation) {
    return const NullElevationProvider();
  }
  return OpenTopoDataElevationProvider();
});

/// The elevation profile of a saved route.
///
/// One request per route per session: the provider is not auto-disposed, so
/// opening the same route twice does not ask the terrain service twice.
///
/// Gain is computed with the same peak/valley accumulator the rides use, at a
/// threshold of 5 m rather than 2 — a 30 m DEM is a measurement of the ground,
/// but it is a coarse one, and counting its own noise as climbing would be the
/// same mistake the GPS path was designed to avoid.
final routeElevationProfileProvider =
    FutureProvider.family<RouteElevationProfile?, String>((ref, routeId) async {
      final provider = ref.watch(elevationProviderProvider);
      if (!provider.isConfigured) return null;

      final route = await ref.watch(routeRepositoryProvider).getRoute(routeId);
      if (route == null || route.points.length < 2) return null;

      final samples = sampleRoutePoints(route.points);
      final heights = await provider.heights(samples);
      // Nulls are where the terrain service had no data; the chart needs a
      // contiguous series, and the axis is the route length rather than the sample
      // count, so dropping them is honest.
      final known = [for (final height in heights) ?height];
      if (known.length < 2) return null;

      final accumulator = ElevationAccumulator(thresholdMeters: 5);
      for (final height in known) {
        accumulator.add(height);
      }

      return RouteElevationProfile(
        // Even spacing is ElevationChart's contract; the chart plots whatever it
        // is given, so the nulls are dropped here and the axis is the route length.
        samples: known,
        gainMeters: accumulator.gainMeters,
        lossMeters: accumulator.lossMeters,
        distanceMeters: route.distanceMeters,
        source: provider.displayName,
      );
    });

/// A route's terrain profile, as the UI needs it.
class RouteElevationProfile {
  const RouteElevationProfile({
    required this.samples,
    required this.gainMeters,
    required this.lossMeters,
    required this.distanceMeters,
    required this.source,
  });

  /// Heights in metres, evenly spaced along the route.
  final List<double> samples;

  final double gainMeters;
  final double lossMeters;
  final double distanceMeters;

  /// Who to credit, shown under the chart.
  final String source;
}

/// Whether the OS will keep delivering fixes with the screen off.
///
/// A future rather than a value: it is a platform query, and the settings
/// screen shows it beside the other location settings. Unknown (`null` while
/// it resolves, or `true` on a platform that will not answer) is presented as
/// granted — nagging is worse than staying quiet.
final backgroundLocationProvider = FutureProvider<bool>(
  (ref) => ref.watch(locationServiceProvider).hasBackgroundAccess(),
);

/// The process's diagnostic log.
///
/// `main` overrides this with the instance its global error handlers write to.
/// The default resolves its own file lazily and is what a widget test gets
/// when it does not care — under `flutter test` there is no `path_provider`
/// plugin, so it quietly does nothing rather than failing the test.
final diagnosticLogProvider = Provider<DiagnosticLog>((ref) => DiagnosticLog());

/// Turns a caught exception into something the rider sees and the log keeps.
final failureReporterProvider = Provider<FailureReporter>(
  (ref) => FailureReporter(ref.watch(diagnosticLogProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(),
);

/// The signed-in account, or null. Emits on sign-in and sign-out.
final authUserProvider = StreamProvider<AuthUser?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges();
});

final rideRepositoryProvider = Provider<RideRepository>(
  (ref) => RideRepository(ref.watch(databaseProvider)),
);

final routeRepositoryProvider = Provider<RouteRepository>(
  (ref) => RouteRepository(ref.watch(databaseProvider)),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// The live settings tree.
///
/// Async because the first read comes off disk. Everything downstream treats
/// "still loading" as "defaults" by watching [currentSettingsProvider] instead
/// of this one — there is no screen in this app that should show a spinner
/// because a preference has not loaded yet.
final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final settings = await ref.watch(settingsRepositoryProvider).load();
    _propagate(settings);
    return settings;
  }

  /// Applies a change: persists it, republishes it, and tells the long-lived
  /// services about it.
  ///
  /// Named `mutate` rather than `update` because `AsyncNotifier` already has
  /// an `update` with a different contract, and shadowing it would be a
  /// confusing trap for the next reader.
  Future<void> mutate(AppSettings Function(AppSettings) transform) async {
    final current = state.valueOrNull ?? const AppSettings();
    final next = transform(current);

    // Optimistic: the UI reflects the toggle immediately. A settings write
    // that fails is a disk problem the user cannot act on, and the alternative
    // — a switch that lags behind the finger — is worse than a lost
    // preference.
    state = AsyncData(next);
    _propagate(next);

    await ref.read(settingsRepositoryProvider).save(next);
  }

  void _propagate(AppSettings settings) {
    ref.read(rideRecorderProvider).applySettings(settings);
    ref.read(rideSessionProvider.notifier).applySettings(settings);
    ref.read(syncServiceProvider).applySettings(settings);
    ref.read(sensorManagerProvider).applySettings(settings);
  }
}

/// Settings with defaults already applied.
///
/// Widgets watch this rather than the async provider so a build never has to
/// reason about a loading state for something as mundane as the unit suffix.
final currentSettingsProvider = Provider<AppSettings>((ref) {
  return ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
});

final unitFormatterProvider = Provider<UnitFormatter>((ref) {
  return UnitFormatter(ref.watch(currentSettingsProvider).units);
});

// ---------------------------------------------------------------------------
// Map services
// ---------------------------------------------------------------------------

/// The AMap web-service key, if the user supplied one.
///
/// Kept out of [AppSettings] because it is a credential rather than a
/// preference: it is stored in the same key/value table but read here, and it
/// is never uploaded to the cloud or included in an export.
final amapKeyProvider = FutureProvider<String>((ref) async {
  final key = await ref.watch(settingsRepositoryProvider).getString('amap_key');
  return key ?? '';
});

/// The active map provider bundle (spec §33).
///
/// Pages depend on this and never on a vendor. Changing the map service is a
/// change here and nowhere else — which is the entire point of the
/// abstraction, and the reason the traffic-light provider can be a stub today
/// without leaving a mark on the UI.
final mapServicesProvider = Provider<MapServices>((ref) {
  final settings = ref.watch(currentSettingsProvider);
  final relayEndpoint = FunctionsConfig.routeUrl;

  // A build-time choice beats everything below it. Routes are converted to
  // the tile source's datum at the drawing boundary (`RouteMap`), so any
  // combination is geometrically correct — this is about whose tiles we are
  // allowed to serve, not about coordinates.
  final tileOverride = MapConfig.tileSourceOverride;

  // The relay comes first: it is the distribution shape, and it needs no key
  // on the device at all. A rider who also happens to have their own key can
  // still be served by the relay — the quota is what matters, not the key.
  if (relayEndpoint != null) {
    // The relay requires a session. Rebuild this bundle when sign-in changes
    // so guests can plan a clearly labelled straight line right away.
    final signedIn = ref.watch(authUserProvider).valueOrNull != null;
    if (!signedIn) {
      return MapServices(
        places: const NullPlaceProvider(),
        routes: const OfflineRouteProvider(),
        trafficLights: const AmapTrafficLightProvider(),
        tileSource:
            tileOverride ??
            (settings.mapStyle == MapStyle.dark
                ? MapTileSource.cartoDark
                : MapTileSource.osm),
      );
    }
    return MapServices(
      // Search is not relayed (only routing is), so it degrades to "no
      // results" rather than to a broken screen. A rider who wants search can
      // fill their own key below.
      places: const NullPlaceProvider(),
      routes: AmapRouteProvider(
        client: AmapRelayClient(
          endpoint: relayEndpoint,
          accessToken: _sessionAccessToken,
        ),
      ),
      trafficLights: const AmapTrafficLightProvider(),
      tileSource: tileOverride ?? MapTileSource.amapVector,
    );
  }

  final amapKey = ref.watch(amapKeyProvider).valueOrNull ?? '';

  if (amapKey.trim().isEmpty) {
    return MapServices(
      places: const NullPlaceProvider(),
      routes: const OfflineRouteProvider(),
      trafficLights: const AmapTrafficLightProvider(),
      tileSource:
          tileOverride ??
          (settings.mapStyle == MapStyle.dark
              ? MapTileSource.cartoDark
              : MapTileSource.osm),
    );
  }

  final client = AmapClient(apiKey: amapKey);
  ref.onDispose(client.close);

  return MapServices(
    places: AmapPlaceProvider(client: client),
    routes: AmapRouteProvider(client: client),
    trafficLights: const AmapTrafficLightProvider(),
    // Tiles follow the routing provider's datum: a GCJ-02 route drawn on
    // WGS-84 tiles is 300 m off, and this makes that impossible to configure
    // by accident.
    tileSource: tileOverride ?? MapTileSource.amapVector,
  );
});

/// Whether the app can plan real bike routes, and why not if it cannot.
final routingAvailabilityProvider = Provider<({bool available, String reason})>(
  (ref) {
    final services = ref.watch(mapServicesProvider);
    // The offline provider answers, but only with straight lines.
    if (!services.routes.isDegraded) {
      return (available: true, reason: '');
    }
    if (FunctionsConfig.isConfigured) {
      // The relay is built in but the session is not: "not signed in" is the
      // actionable half of this, and the straight line is the fallback either
      // way.
      return (
        available: false,
        reason:
            '登录后可使用在线骑行路线（匿名账号也可以）；'
            '未登录时使用直线路径。',
      );
    }
    return (
      available: false,
      reason:
          '未配置高德 Key，当前只能使用直线路径。'
          '在「设置 → 地图」中填入 Web 服务 Key 即可使用真实骑行路线。',
    );
  },
);

/// The current session token, or null.
///
/// A function rather than a value: supabase_flutter refreshes the session in
/// place, and the provider graph is built once. Shared by every edge-function
/// client — the routing relay and account deletion want the same thing.
String? _sessionAccessToken() {
  if (!SupabaseConfig.isConfigured) return null;
  try {
    return Supabase.instance.client.auth.currentSession?.accessToken;
  } catch (_) {
    // The SDK throws when it has not been initialised; treat that the same as
    // signed out.
    return null;
  }
}

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

final rideRecorderProvider = Provider<RideRecorder>((ref) {
  final recorder = RideRecorder(
    db: ref.watch(databaseProvider),
    repository: ref.watch(rideRepositoryProvider),
    locationService: ref.watch(locationServiceProvider),
    // The reading half of the sensor feature. Without this the manager pairs
    // devices, shows live values on its own screen, and sends nothing to the
    // ride — which is exactly what the code did before anyone checked.
    sensorReadings: ref.watch(sensorManagerProvider).readings,
    // The barometer is not a paired device; it is part of the phone, and when
    // it exists the climb stops being an estimate.
    barometer: ref.watch(barometerSourceProvider),
  );
  ref.onDispose(recorder.dispose);
  return recorder;
});

/// Where spoken navigation prompts go.
///
/// One backend for the process, and a provider rather than a direct
/// construction so a test can record what would have been said without a
/// speech engine. The real backend does not touch the platform until the
/// rider enables voice prompts.
final voiceBackendProvider = Provider<VoiceBackend>(
  (ref) => FlutterTtsVoiceBackend(),
);

/// Self-service account deletion.
///
/// Constructed with an empty endpoint when the project has no functions
/// configured; `isConfigured` is then false and the settings screen says the
/// feature is unavailable rather than offering a button that cannot work.
final accountDeletionClientProvider = Provider<AccountDeletionClient>((ref) {
  return AccountDeletionClient(
    endpoint: FunctionsConfig.deleteAccountUrl ?? '',
    accessToken: _sessionAccessToken,
  );
});

/// True while a password-reset link has been opened and the rider has not yet
/// chosen a new password.
///
/// Without this the reset flow is a lie: the link signs the rider in, the app
/// looks at the new session and concludes everything worked, and the old
/// password is still the one on the account.
final passwordRecoveryProvider =
    NotifierProvider<PasswordRecoveryNotifier, bool>(
      PasswordRecoveryNotifier.new,
    );

class PasswordRecoveryNotifier extends Notifier<bool> {
  StreamSubscription<AuthChangeEvent>? _sub;

  @override
  bool build() {
    // Subscribed from the first frame. The SDK fires this event only after it
    // has exchanged the link for a session, which costs a round trip to the
    // auth server — long enough that a listener attached in this build always
    // wins the race, including on a cold start straight from the email.
    _sub = ref.watch(authRepositoryProvider).authEvents().listen((event) {
      if (event == AuthChangeEvent.passwordRecovery) state = true;
    });
    ref.onDispose(() => _sub?.cancel());
    return false;
  }

  /// The password was changed, or the rider chose to do it later.
  void clear() => state = false;
}

/// The ride session object, created once for the life of the app.
///
/// Deliberately a separate provider from the state that exposes it, and
/// deliberately built with `ref.read` rather than `ref.watch`.
///
/// This object owns the recording engine. Watching anything here would mean
/// that an unrelated provider change — the AMap key finishing its load from
/// disk, the map style being toggled — tears down a ride in progress. `read`
/// makes the identity stable for the process lifetime, which is what a ride
/// needs.
final rideSessionInstanceProvider = Provider<RideSession>((ref) {
  final session = RideSession(
    recorder: ref.read(rideRecorderProvider),
    // A getter, not the provider itself: the routing provider is resolved
    // when navigation starts, so a key entered mid-ride takes effect.
    routeProvider: () => ref.read(mapServicesProvider).routes,
    settings: ref.read(currentSettingsProvider),
    voiceBackend: ref.read(voiceBackendProvider),
  );
  ref.onDispose(session.dispose);
  return session;
});

/// The ride in progress, including navigation if a route is loaded.
final rideSessionProvider =
    NotifierProvider<RideSessionNotifier, RideSessionState>(
      RideSessionNotifier.new,
    );

class RideSessionNotifier extends Notifier<RideSessionState> {
  StreamSubscription<RideSessionState>? _sub;

  /// The session, stable for the process lifetime.
  ///
  /// This field is assigned in the *initializer*, not inside `build()`. That
  /// distinction is the whole reason this class is shaped the way it is:
  /// Riverpod re-runs `build()` whenever a watched provider changes, and a
  /// `late final` assigned inside `build()` throws
  /// `LateInitializationError: field has already been initialized` on the
  /// second run — taking the ride screen down with it.
  late final RideSession _session = ref.read(rideSessionInstanceProvider);

  @override
  RideSessionState build() {
    // Watching the instance provider, whose identity never changes, so this
    // `build` runs exactly once.
    ref.watch(rideSessionInstanceProvider);

    _sub = _session.states.listen((s) => state = s);
    ref.onDispose(() => _sub?.cancel());

    return _session.state;
  }

  Future<bool> start({Route? route, RideCheckpoint? resumeFrom}) {
    return _session.start(
      settings: ref.read(currentSettingsProvider),
      route: route,
      resumeFrom: resumeFrom,
    );
  }

  void beginRecording() => _session.recorder.beginRecording();

  void pause() => _session.pause();

  void resume() => _session.resume();

  Future<Ride?> stop({String? name}) => _session.stop(name: name);

  Future<void> discard() => _session.discard();

  void navigateRoute(Route route) => _session.navigateRoute(route);

  void clearRoute() => _session.clearRoute();

  void requestMap() => _session.requestMap();

  void requestMinimal() => _session.requestMinimal();

  Future<void> reroute() => _session.reroute();

  void applySettings(AppSettings settings) => _session.applySettings(settings);

  Future<void> checkpointNow() => _session.checkpointNow();
}

/// The raw engine state, for widgets that want only the numbers.
final rideStateProvider = Provider<RideState>(
  (ref) => ref.watch(rideSessionProvider).ride,
);

/// Everything the dashboard needs: ride statistics, navigation progress, GPS
/// quality and battery, in one object.
final dashboardDataProvider = Provider<DashboardData>((ref) {
  final session = ref.watch(rideSessionProvider);
  final ride = session.ride;

  return DashboardData(
    stats: ride.stats,
    navigation: session.navigation,
    gpsAccuracyMeters: ride.gpsAccuracyMeters,
    gpsSignalLost: ride.gpsSignalLost,
    batteryPercent: ref.watch(batteryPercentProvider).valueOrNull,
    now: DateTime.now(),
  );
});

/// Battery level, refreshed slowly.
///
/// One minute is deliberate: a battery percentage that ticks every second is
/// noise on the dashboard and a wakeup the platform does not need to serve.
final batteryPercentProvider = StreamProvider<double>((ref) async* {
  final battery = Battery();
  try {
    yield (await battery.batteryLevel).toDouble();
  } catch (_) {
    return;
  }
  yield* Stream<void>.periodic(const Duration(seconds: 60))
      .asyncMap((_) async {
        try {
          return (await battery.batteryLevel).toDouble();
        } catch (_) {
          return -1.0;
        }
      })
      .where((v) => v >= 0);
});

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

final ridesProvider = StreamProvider<List<Ride>>(
  (ref) => ref.watch(rideRepositoryProvider).watchRides(),
);

final mostRecentRideProvider = StreamProvider<Ride?>(
  (ref) => ref.watch(rideRepositoryProvider).watchMostRecent(),
);

/// The month shown on the home screen and at the top of the history list.
final selectedMonthProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month);
});

final monthSummaryProvider = StreamProvider<RideSummary>((ref) {
  final month = ref.watch(selectedMonthProvider);
  return ref.watch(rideRepositoryProvider).watchMonthSummary(month);
});

/// One ride, by id.
final rideProvider = StreamProvider.family<Ride?, String>(
  (ref, rideId) => ref.watch(rideRepositoryProvider).watchRide(rideId),
);

/// A single ride's trace, for the detail screen's map and elevation chart.
final trackPointsProvider = StreamProvider.family<List<TrackPoint>, String>(
  (ref, rideId) => ref.watch(rideRepositoryProvider).watchTrackPoints(rideId),
);

/// The trace as coordinates, for the map.
///
/// Derived rather than stored: the track itself is the source of truth and the
/// projection is cheap, so there is no reason to keep a second copy in sync.
final trackGeometryProvider = Provider.family<List<GeoPoint>, String>((
  ref,
  rideId,
) {
  final points = ref.watch(trackPointsProvider(rideId)).valueOrNull;
  if (points == null) return const [];
  return points.map((p) => p.geo).toList(growable: false);
});

/// How much the climb total for a recorded ride can be trusted.
///
/// Derived from the vertical accuracy stored on each track point, which has
/// been recorded since the beginning — so no schema change was needed to
/// answer "did this ride have a barometer?", and rides recorded before the
/// question was asked still get an honest answer.
///
/// The median rather than the mean: one optimistic fix in a tunnel should not
/// make a whole ride look precise.
final elevationQualityProvider = Provider.family<ElevationQuality, String>((
  ref,
  rideId,
) {
  final points = ref.watch(trackPointsProvider(rideId)).valueOrNull;
  if (points == null || points.isEmpty) return ElevationQuality.approximate;

  final accuracies = <double>[];
  for (final point in points) {
    final accuracy = point.verticalAccuracy;
    // Zero and negative both mean the platform did not report one.
    if (accuracy != null && accuracy > 0 && accuracy.isFinite) {
      accuracies.add(accuracy);
    }
  }

  // A ride where most fixes carried no vertical accuracy is an unknown, and
  // unknown is treated as the pessimistic case.
  if (accuracies.length < points.length ~/ 2) {
    return ElevationQuality.approximate;
  }

  accuracies.sort();
  return ElevationTuning.forVerticalAccuracy(
    accuracies[accuracies.length ~/ 2],
  ).quality;
});

/// Elevation samples for the profile chart, bucketed for drawing.
///
/// Averaged within each bucket rather than sampled at bucket boundaries: a
/// point-sampled profile can miss a short steep ramp entirely, which is
/// exactly the feature a rider is looking for.
final elevationSamplesProvider = Provider.family<List<double>, String>((
  ref,
  rideId,
) {
  final points = ref.watch(trackPointsProvider(rideId)).valueOrNull;
  if (points == null) return const [];

  final altitudes = <double>[];
  for (final point in points) {
    final altitude = point.altitude;
    if (altitude != null && altitude.isFinite) altitudes.add(altitude);
  }
  if (altitudes.length < 2) return const [];

  const buckets = 120;
  if (altitudes.length <= buckets) return altitudes;

  final out = <double>[];
  final step = altitudes.length / buckets;
  for (var i = 0; i < buckets; i++) {
    final start = (i * step).floor();
    final end = ((i + 1) * step).ceil().clamp(0, altitudes.length);
    if (end <= start) continue;
    var sum = 0.0;
    for (var j = start; j < end; j++) {
      sum += altitudes[j];
    }
    out.add(sum / (end - start));
  }
  return out;
});

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

final savedRoutesProvider = StreamProvider<List<Route>>(
  (ref) => ref.watch(routeRepositoryProvider).watchRoutes(),
);

final routeProvider = StreamProvider.family<Route?, String>(
  (ref, id) => ref.watch(routeRepositoryProvider).watchRoute(id),
);

// ---------------------------------------------------------------------------
// Sensors
// ---------------------------------------------------------------------------

final sensorManagerProvider = Provider<SensorManager>((ref) {
  final manager = SensorManager(db: ref.watch(databaseProvider));
  ref.onDispose(manager.dispose);
  return manager;
});

// ---------------------------------------------------------------------------
// Sync
// ---------------------------------------------------------------------------

final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(
    db: ref.watch(databaseProvider),
    rides: ref.watch(rideRepositoryProvider),
    routes: ref.watch(routeRepositoryProvider),
    resolveClient: () {
      if (!SupabaseConfig.isConfigured) return null;
      try {
        return Supabase.instance.client;
      } catch (_) {
        return null;
      }
    },
  );
  ref.onDispose(service.dispose);
  return service;
});

final syncReportProvider = StreamProvider<SyncReport>((ref) {
  final service = ref.watch(syncServiceProvider);
  // `start()` registers the connectivity listener; calling it from the
  // provider means sync begins the first time anything reads this state, and
  // never in a build with no cloud configured.
  service.start();
  return service.reports;
});

/// Any ride checkpoint left behind by a crash (spec §42).
///
/// Read once at startup by the home screen. Deliberately not a `StreamProvider`
/// on the table: an unfinished ride has to be *offered*, and re-offering it
/// every time the row changes would re-open the dialog under the user.
final unfinishedRideProvider = FutureProvider<RideCheckpoint?>(
  (ref) => ref.read(rideRecorderProvider).findUnfinishedRide(),
);

/// The dashboard configuration currently in effect.
final dashboardConfigProvider = Provider<DashboardConfig>((ref) {
  return ref.watch(currentSettingsProvider).dashboard;
});

/// Which navigation presentation the ride screen is in.
final navigationModeProvider = Provider<NavigationMode?>((ref) {
  return ref.watch(rideSessionProvider).navigation?.mode;
});
