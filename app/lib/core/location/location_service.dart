import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as permissions;

import '../../features/settings/domain/app_settings.dart';
import 'location_fix.dart';

/// Outcome of a permission check, flattened from the platform's vocabulary
/// into the four cases the UI actually branches on.
enum LocationPermissionStatus {
  notDetermined,
  denied,
  deniedForever,
  serviceDisabled,
  granted;

  bool get isUsable => this == LocationPermissionStatus.granted;

  /// Whether asking again could plausibly change the answer.
  bool get canPrompt =>
      this == LocationPermissionStatus.notDetermined ||
      this == LocationPermissionStatus.denied;
}

/// Wraps the platform location APIs.
///
/// Everything above this file deals in [LocationFix], never in `Position`.
/// That keeps `geolocator` — including its platform-specific settings types —
/// behind one boundary, which is what makes the GPS pipeline testable without
/// a device.
class LocationService {
  /// Checks and, if necessary, requests permission.
  ///
  /// Requests foreground access first. When [requestBackground] is true,
  /// also offers an Always grant after foreground access exists. A ride can
  /// still start with a foreground-only grant.
  Future<LocationPermissionStatus> ensurePermission({
    bool requestBackground = true,
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionStatus.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      return LocationPermissionStatus.denied;
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationPermissionStatus.deniedForever;
    }
    if (permission == LocationPermission.unableToDetermine) {
      return LocationPermissionStatus.notDetermined;
    }

    // Android 10+ and iOS split foreground from background. The second step
    // must request only background access on Android; Geolocator includes the
    // foreground permissions again. On iOS, Geolocator returns immediately
    // once When In Use is granted. Permission Handler covers both cases.
    if (requestBackground && permission == LocationPermission.whileInUse) {
      try {
        if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android) {
          await permissions.Permission.locationAlways.request();
        } else {
          await Geolocator.requestPermission();
        }
      } catch (_) {
        // Background access is optional; foreground recording can proceed.
      }
    }

    return LocationPermissionStatus.granted;
  }

  Future<LocationPermissionStatus> checkPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionStatus.serviceDisabled;
    }
    return switch (await Geolocator.checkPermission()) {
      LocationPermission.always ||
      LocationPermission.whileInUse => LocationPermissionStatus.granted,
      LocationPermission.deniedForever =>
        LocationPermissionStatus.deniedForever,
      LocationPermission.denied => LocationPermissionStatus.denied,
      LocationPermission.unableToDetermine =>
        LocationPermissionStatus.notDetermined,
    };
  }

  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  /// Whether the OS grants location beyond the foreground.
  ///
  /// Android 10+ and iOS 13+ split the grant in two, and only the "always"
  /// tier keeps a ride alive with the screen off. A rider who picked
  /// 「使用 App 期间」 has an app that works and stops recording when they
  /// pocket the phone — which they discover at the end of the ride, from a
  /// straight line on the map. Worth saying out loud, once.
  ///
  /// Unknown counts as granted: nagging somebody whose platform did not answer
  /// is worse than staying quiet.
  Future<bool> hasBackgroundAccess() async {
    try {
      // On Android ≤ 9 there is no background tier at all, and geolocator
      // reports `always` once fine location is granted — so the same check is
      // right on both platforms.
      return await Geolocator.checkPermission() == LocationPermission.always;
    } catch (_) {
      return true;
    }
  }

  /// One-shot fix, used by route planning and by the pre-ride GPS check.
  Future<LocationFix?> currentFix({
    Duration timeout = const Duration(seconds: 12),
    GpsAccuracyMode mode = GpsAccuracyMode.high,
  }) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: _settingsFor(mode, background: false),
      ).timeout(timeout);
      return _toFix(position);
    } on TimeoutException {
      return null;
    } catch (_) {
      // Platform exceptions are not actionable here; callers treat a null fix
      // as "no fix yet" and let the preparing timeout handle it.
      return null;
    }
  }

  /// Continuous fixes for the duration of a ride.
  ///
  /// The stream is left to the platform to drive. Gap detection and rejection
  /// happen downstream in `GpsFilter`, not here — this layer's only job is to
  /// hand over whatever the receiver produces, with no lossy transform in
  /// between.
  ///
  /// On Android, high and balanced rides prefer GPS_PROVIDER directly
  /// (`app.purecycling/gnss`). The geolocator stream stays open beside it:
  /// its foreground service is what keeps satellite delivery legal with the
  /// screen off, and its fixes fill in when the satellite stream errors or
  /// goes quiet. A geolocator fix is dropped for a few seconds after a
  /// satellite fix so the two listeners cannot double-count distance.
  Stream<LocationFix> fixes({
    GpsAccuracyMode mode = GpsAccuracyMode.high,
    bool background = true,
    Duration? interval,
  }) {
    final resolved = interval ?? _defaultInterval(mode);
    final fallback = Geolocator.getPositionStream(
      locationSettings: _settingsFor(
        mode,
        background: background,
        interval: resolved,
      ),
    ).map(_toFix);
    if (!_preferSatelliteFixes(mode)) return fallback;
    return _satelliteFirst(fallback, resolved);
  }

  /// Location settings for a sampling profile (spec §32).
  ///
  /// One hertz at the default profile: a bicycle at 30 km/h moves 8 m between
  /// fixes, which is the right resolution for both distance and a smooth map.
  /// Stopping stretches the interval without relaxing the accuracy request.
  /// [interval] carries that: five seconds while parked, at whatever accuracy
  /// the rider chose. `LocationAccuracy.medium` is reserved for the 省电 tier
  /// the rider picked themselves — it lets the platform sleep the GNSS chip,
  /// and a chip that has to wake up at a traffic light is exactly when the
  /// signal icon turns red. The distance calculator's anchor design means a
  /// slower interval loses nothing when the rider sets off again.
  ///
  /// `distanceFilter: 0` is essential: the platform's default distance-based
  /// filter would silently drop fixes at low speed, which is exactly where the
  /// auto-pause rule needs them.
  ///
  /// **iOS has no rate control.** `CLLocationManager` decides how often to
  /// deliver, guided by the accuracy request; the interval below therefore
  /// buys less on iOS than on Android, where `intervalDuration` is honoured.
  /// What iOS does get from the rider-chosen 省电 tier is a lower-accuracy
  /// request, which is the largest part of the radio's power draw. Stopping
  /// does not take that tier: the accuracy stays what the rider picked.
  LocationSettings _settingsFor(
    GpsAccuracyMode mode, {
    required bool background,
    Duration? interval,
  }) {
    final resolvedInterval = interval ?? _defaultInterval(mode);

    final android = AndroidSettings(
      accuracy: switch (mode) {
        GpsAccuracyMode.high => LocationAccuracy.best,
        GpsAccuracyMode.balanced => LocationAccuracy.high,
        GpsAccuracyMode.batterySaver => LocationAccuracy.medium,
      },
      distanceFilter: 0,
      intervalDuration: resolvedInterval,
      // LocationManager, so a phone without Play Services still produces
      // fixes. The live speed path is the GPS_PROVIDER channel opened beside
      // this stream; this request is what keeps that channel delivering
      // after the screen turns off.
      forceLocationManager: true,
      // Android reports altitude above the WGS84 ellipsoid by default, which
      // reads roughly 30-50 m high in China. The MSL conversion gives the
      // number a rider would recognize from a map.
      useMSLAltitude: true,
      foregroundNotificationConfig: background
          ? const ForegroundNotificationConfig(
              notificationTitle: '正在记录骑行',
              notificationText: '纯粹骑行正在后台记录你的轨迹',
              notificationChannelName: '骑行记录',
              enableWakeLock: true,
              setOngoing: true,
            )
          : null,
    );

    final apple = AppleSettings(
      accuracy: switch (mode) {
        GpsAccuracyMode.high => LocationAccuracy.bestForNavigation,
        GpsAccuracyMode.balanced => LocationAccuracy.high,
        GpsAccuracyMode.batterySaver => LocationAccuracy.medium,
      },
      distanceFilter: 0,
      // iOS pauses location updates when it decides the user has stopped.
      // For a bike computer that heuristic is actively harmful: a long
      // descent with no movement would end the ride silently.
      pauseLocationUpdatesAutomatically: false,
      activityType: ActivityType.otherNavigation,
      showBackgroundLocationIndicator: true,
      allowBackgroundLocationUpdates: background,
    );

    // `LocationSettings` is the fallback for desktop and web, where the
    // Android- and Apple-specific knobs do not exist. `defaultTargetPlatform`
    // rather than `dart:io`'s `Platform`, so this still compiles for web.
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      TargetPlatform.iOS || TargetPlatform.macOS => apple,
      _ => LocationSettings(
        accuracy: switch (mode) {
          GpsAccuracyMode.high => LocationAccuracy.best,
          GpsAccuracyMode.balanced => LocationAccuracy.high,
          GpsAccuracyMode.batterySaver => LocationAccuracy.medium,
        },
        distanceFilter: 0,
      ),
    };
  }

  static Duration _defaultInterval(GpsAccuracyMode mode) => switch (mode) {
    GpsAccuracyMode.high => const Duration(seconds: 1),
    GpsAccuracyMode.balanced => const Duration(seconds: 2),
    GpsAccuracyMode.batterySaver => const Duration(seconds: 5),
  };

  /// Satellite fixes are the speed source on Android except in the rider's
  /// own 省电 tier, which is allowed to leave the chip asleep.
  bool _preferSatelliteFixes(GpsAccuracyMode mode) =>
      defaultTargetPlatform == TargetPlatform.android &&
      mode != GpsAccuracyMode.batterySaver;

  /// How long a satellite fix keeps the geolocator copy out of the pipeline.
  static const Duration _satelliteHoldsFor = Duration(seconds: 3);

  /// Must match `MainActivity.GNSS_CHANNEL`.
  static const EventChannel _gnssChannel = EventChannel('app.purecycling/gnss');

  Stream<LocationFix> _satelliteFirst(
    Stream<LocationFix> fallback,
    Duration interval,
  ) {
    late final StreamController<LocationFix> controller;
    StreamSubscription<LocationFix>? fallbackSub;
    StreamSubscription<dynamic>? gnssSub;
    DateTime? lastGnssAt;

    void emit(LocationFix fix) {
      if (!controller.isClosed) controller.add(fix);
    }

    controller = StreamController<LocationFix>(
      onListen: () {
        fallbackSub = fallback.listen(
          (fix) {
            final seen = lastGnssAt;
            if (seen != null &&
                DateTime.now().difference(seen) < _satelliteHoldsFor) {
              return;
            }
            emit(fix);
          },
          onError: (Object error, StackTrace stack) {
            if (!controller.isClosed) controller.addError(error, stack);
          },
        );
        gnssSub = _gnssChannel
            .receiveBroadcastStream(interval.inMilliseconds)
            .listen(
              (event) {
                final fix = fixFromGnssEvent(event);
                if (fix == null) return;
                lastGnssAt = DateTime.now();
                emit(fix);
              },
              onError: (Object _, StackTrace _) {
                // The satellite request can fail (GPS off, permission, no
                // plugin). The geolocator stream is still open and becomes
                // the source; closing the merged stream would end the ride.
                lastGnssAt = null;
              },
              cancelOnError: false,
            );
      },
      onCancel: () async {
        await fallbackSub?.cancel();
        await gnssSub?.cancel();
        fallbackSub = null;
        gnssSub = null;
      },
    );
    return controller.stream;
  }

  static LocationFix _toFix(Position p) => LocationFix(
    latitude: p.latitude,
    longitude: p.longitude,
    timestamp: p.timestamp.toUtc(),
    altitude: p.altitude,
    altitudeAccuracy: p.altitudeAccuracy,
    accuracy: p.accuracy,
    speed: p.speed,
    speedAccuracy: p.speedAccuracy,
    heading: p.heading,
    headingAccuracy: p.headingAccuracy,
    isMocked: p.isMocked,
  );

  /// Distance between two fixes, for the pre-ride sanity check.
  static double distanceBetween(LocationFix a, LocationFix b) =>
      Geolocator.distanceBetween(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
}

/// Parses one event from the Android `app.purecycling/gnss` channel.
///
/// Returns null when the payload is not a fix. Callers skip those rather
/// than failing the ride.
LocationFix? fixFromGnssEvent(Object? event) {
  if (event is! Map) return null;
  final latitude = event['latitude'];
  final longitude = event['longitude'];
  final timestamp = event['timestamp'];
  if (latitude is! num || longitude is! num || timestamp is! num) return null;

  double? number(Object? value) => value is num ? value.toDouble() : null;

  return LocationFix(
    latitude: latitude.toDouble(),
    longitude: longitude.toDouble(),
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      timestamp.toInt(),
      isUtc: true,
    ),
    altitude: number(event['altitude']),
    altitudeAccuracy: number(event['altitude_accuracy']),
    accuracy: number(event['accuracy']) ?? 0,
    speed: number(event['speed']),
    speedAccuracy: number(event['speed_accuracy']),
    heading: number(event['heading']),
    headingAccuracy: number(event['heading_accuracy']),
    isMocked: event['is_mocked'] == true,
  );
}
