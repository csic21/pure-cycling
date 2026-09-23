import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:geolocator/geolocator.dart';

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

  bool get isUsable =>
      this == LocationPermissionStatus.granted;

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
  /// Requests the *always* (background) grant, and accepts `whileInUse` as a
  /// working state: a ride recorded with the screen on is still a ride, and
  /// refusing to start because background access was withheld would be worse
  /// than starting with a warning.
  Future<LocationPermissionStatus> ensurePermission({
    bool requestBackground = true,
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionStatus.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      return LocationPermissionStatus.denied;
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationPermissionStatus.deniedForever;
    }

    // Android 10+ and iOS 13+ split foreground from background. Asking for
    // the upgrade only after foreground is granted is the sequence both
    // platforms expect.
    if (requestBackground && permission == LocationPermission.whileInUse) {
      final upgraded = await Geolocator.requestPermission();
      if (upgraded == LocationPermission.always) {
        return LocationPermissionStatus.granted;
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
      LocationPermission.whileInUse =>
        LocationPermissionStatus.granted,
      LocationPermission.deniedForever =>
        LocationPermissionStatus.deniedForever,
      LocationPermission.denied => LocationPermissionStatus.denied,
      LocationPermission.unableToDetermine =>
        LocationPermissionStatus.notDetermined,
    };
  }

  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

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
  Stream<LocationFix> fixes({
    GpsAccuracyMode mode = GpsAccuracyMode.high,
    bool background = true,
  }) {
    return Geolocator.getPositionStream(
      locationSettings: _settingsFor(mode, background: background),
    ).map(_toFix);
  }

  /// Location settings for a sampling profile (spec §32).
  ///
  /// One hertz is the target while riding — a bicycle at 30 km/h moves 8 m
  /// between fixes, which is the right resolution for both distance and a
  /// smooth map. `distanceFilter: 0` is essential: the platform's default
  /// distance-based filter would silently drop fixes at low speed, which is
  /// exactly where the auto-pause rule needs them.
  LocationSettings _settingsFor(
    GpsAccuracyMode mode, {
    required bool background,
  }) {
    final android = AndroidSettings(
      accuracy: switch (mode) {
        GpsAccuracyMode.high => LocationAccuracy.best,
        GpsAccuracyMode.balanced => LocationAccuracy.high,
        GpsAccuracyMode.batterySaver => LocationAccuracy.medium,
      },
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 1),
      // Fused provider: better accuracy and materially better battery than
      // the raw LocationManager on every Android device with Play Services.
      forceLocationManager: false,
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
        GpsAccuracyMode.high => LocationAccuracy.best,
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
