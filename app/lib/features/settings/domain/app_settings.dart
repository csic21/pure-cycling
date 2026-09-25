import 'dart:convert';

import '../../../core/utils/units.dart';
import '../../dashboard/domain/dashboard_config.dart';

/// GPS sampling profile (spec §32).
///
/// The engine uses this to pick a `LocationAccuracy` and an update interval;
/// it is also allowed to *downgrade* the profile dynamically when the rider is
/// stationary, regardless of what is chosen here.
enum GpsAccuracyMode {
  high('high', '高精度', '每秒采样，骑行推荐'),
  balanced('balanced', '均衡', '省电与精度折中'),
  batterySaver('battery_saver', '省电', '长距离骑行或低电量');

  const GpsAccuracyMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static GpsAccuracyMode fromId(String? id) => GpsAccuracyMode.values.firstWhere(
        (m) => m.id == id,
        orElse: () => GpsAccuracyMode.high,
      );
}

/// Whether a start countdown runs before recording begins (spec §4).
enum StartCountdown {
  off('off', 0, '关闭'),
  threeSeconds('three', 3, '3 秒'),
  fiveSeconds('five', 5, '5 秒');

  const StartCountdown(this.id, this.seconds, this.label);

  final String id;
  final int seconds;
  final String label;

  static StartCountdown fromId(String? id) =>
      StartCountdown.values.firstWhere(
        (c) => c.id == id,
        orElse: () => StartCountdown.threeSeconds,
      );
}

/// Light or dark map tiles.
enum MapStyle {
  dark('dark', '深色'),
  light('light', '浅色');

  const MapStyle(this.id, this.label);

  final String id;
  final String label;

  static MapStyle fromId(String? id) => MapStyle.values.firstWhere(
        (s) => s.id == id,
        orElse: () => MapStyle.dark,
      );
}

/// Navigation behaviour (spec §8).
class NavigationConfig {
  const NavigationConfig({
    this.autoShowMap = true,
    this.voicePrompts = false,
    this.rerouteOnDeviation = true,
    this.minimalByDefault = true,
    this.rerouteThresholdMeters = 45,
    this.autoMapDismissSeconds = 8,
    this.approachingTurnMeters = 150,
  });

  /// Switch to the map automatically at complex junctions (§8.2).
  final bool autoShowMap;

  /// Spoken instructions. Off by default: voice eats battery, and on shared
  /// paths a talking phone is more intrusive than a glance at the screen.
  final bool voicePrompts;

  final bool rerouteOnDeviation;

  /// Start in minimal navigation rather than the map view.
  final bool minimalByDefault;

  /// How far off the route counts as a deviation.
  final double rerouteThresholdMeters;

  /// How long the map stays up after the junction is cleared (§8.2: 5–10s).
  final int autoMapDismissSeconds;

  /// Distance to a turn that triggers the map automatically.
  final double approachingTurnMeters;

  NavigationConfig copyWith({
    bool? autoShowMap,
    bool? voicePrompts,
    bool? rerouteOnDeviation,
    bool? minimalByDefault,
    double? rerouteThresholdMeters,
    int? autoMapDismissSeconds,
    double? approachingTurnMeters,
  }) {
    return NavigationConfig(
      autoShowMap: autoShowMap ?? this.autoShowMap,
      voicePrompts: voicePrompts ?? this.voicePrompts,
      rerouteOnDeviation: rerouteOnDeviation ?? this.rerouteOnDeviation,
      minimalByDefault: minimalByDefault ?? this.minimalByDefault,
      rerouteThresholdMeters:
          rerouteThresholdMeters ?? this.rerouteThresholdMeters,
      autoMapDismissSeconds: autoMapDismissSeconds ?? this.autoMapDismissSeconds,
      approachingTurnMeters: approachingTurnMeters ?? this.approachingTurnMeters,
    );
  }

  Map<String, dynamic> toJson() => {
        'auto_show_map': autoShowMap,
        'voice_prompts': voicePrompts,
        'reroute_on_deviation': rerouteOnDeviation,
        'minimal_by_default': minimalByDefault,
        'reroute_threshold_m': rerouteThresholdMeters,
        'auto_map_dismiss_s': autoMapDismissSeconds,
        'approaching_turn_m': approachingTurnMeters,
      };

  static NavigationConfig fromJson(Map<String, dynamic>? json) {
    if (json == null) return const NavigationConfig();
    return NavigationConfig(
      autoShowMap: json['auto_show_map'] as bool? ?? true,
      voicePrompts: json['voice_prompts'] as bool? ?? false,
      rerouteOnDeviation: json['reroute_on_deviation'] as bool? ?? true,
      minimalByDefault: json['minimal_by_default'] as bool? ?? true,
      rerouteThresholdMeters:
          (json['reroute_threshold_m'] as num?)?.toDouble() ?? 45,
      autoMapDismissSeconds:
          (json['auto_map_dismiss_s'] as num?)?.toInt() ?? 8,
      approachingTurnMeters:
          (json['approaching_turn_m'] as num?)?.toDouble() ?? 150,
    );
  }
}

/// The complete user-editable settings tree.
///
/// Immutable: every change produces a new instance which the repository
/// persists and republishes. Widgets therefore never observe a half-applied
/// settings update.
class AppSettings {
  const AppSettings({
    this.units = UnitSystem.metric,
    this.autoPause = true,
    this.startCountdown = StartCountdown.threeSeconds,
    this.gpsAccuracy = GpsAccuracyMode.high,
    this.dashboard = DashboardConfig.defaults,
    this.oledMode = true,
    this.pixelShift = true,
    this.dimOnStandstill = true,
    this.minimalOled = false,
    this.keepScreenOn = true,
    this.navigation = const NavigationConfig(),
    this.mapStyle = MapStyle.dark,
    this.routeElevation = false,
    this.cloudSync = false,
    this.wifiOnlyUpload = false,
    this.autoPauseSpeedThresholdKph = 2.0,
    this.autoPauseDelaySeconds = 5,
    this.autoResumeSpeedThresholdKph = 3.0,
    this.autoResumeDelaySeconds = 2,
    this.maxAcceptableAccuracyMeters = 50,
    this.gpsSignalLostSeconds = 15,
  });

  // ---- 骑行 ----

  final UnitSystem units;

  /// Auto-pause is on by default but always user-defeatable (spec §14).
  final bool autoPause;
  final StartCountdown startCountdown;
  final GpsAccuracyMode gpsAccuracy;

  /// Speed below which the auto-pause timer starts, in km/h.
  final double autoPauseSpeedThresholdKph;

  /// How long below threshold before auto-pausing. Five seconds, not
  /// instantaneous: GPS jitter at a standstill must not chatter the state.
  final int autoPauseDelaySeconds;

  final double autoResumeSpeedThresholdKph;
  final int autoResumeDelaySeconds;

  /// Fixes worse than this are excluded from distance accumulation.
  final double maxAcceptableAccuracyMeters;

  /// How long without a fix before the UI reports the signal as lost.
  final int gpsSignalLostSeconds;

  // ---- 码表 ----

  final DashboardConfig dashboard;

  // ---- OLED ----

  final bool oledMode;

  /// Anti burn-in offset drift (spec §7.2).
  final bool pixelShift;

  /// Dim and widen the shift when stopped for a while (spec §7.3).
  final bool dimOnStandstill;

  /// The stripped-down readout of §7.4.
  final bool minimalOled;

  final bool keepScreenOn;

  // ---- 导航 ----

  final NavigationConfig navigation;

  final MapStyle mapStyle;

  /// Whether a planned route may be sent to a public terrain service to get
  /// its elevation profile.
  ///
  /// Off by default, and deliberately: it is the only setting in the app that
  /// sends the rider's *coordinates* to a third party that is not the map
  /// provider they chose. A route's climb figure is nice to have; handing over
  /// where the route goes is not something to do on their behalf.
  final bool routeElevation;

  // ---- 数据 ----

  final bool cloudSync;
  final bool wifiOnlyUpload;

  AppSettings copyWith({
    UnitSystem? units,
    bool? autoPause,
    StartCountdown? startCountdown,
    GpsAccuracyMode? gpsAccuracy,
    DashboardConfig? dashboard,
    bool? oledMode,
    bool? pixelShift,
    bool? dimOnStandstill,
    bool? minimalOled,
    bool? keepScreenOn,
    NavigationConfig? navigation,
    MapStyle? mapStyle,
    bool? routeElevation,
    bool? cloudSync,
    bool? wifiOnlyUpload,
    double? autoPauseSpeedThresholdKph,
    int? autoPauseDelaySeconds,
    double? autoResumeSpeedThresholdKph,
    int? autoResumeDelaySeconds,
    double? maxAcceptableAccuracyMeters,
    int? gpsSignalLostSeconds,
  }) {
    return AppSettings(
      units: units ?? this.units,
      autoPause: autoPause ?? this.autoPause,
      startCountdown: startCountdown ?? this.startCountdown,
      gpsAccuracy: gpsAccuracy ?? this.gpsAccuracy,
      dashboard: dashboard ?? this.dashboard,
      oledMode: oledMode ?? this.oledMode,
      pixelShift: pixelShift ?? this.pixelShift,
      dimOnStandstill: dimOnStandstill ?? this.dimOnStandstill,
      minimalOled: minimalOled ?? this.minimalOled,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      navigation: navigation ?? this.navigation,
      mapStyle: mapStyle ?? this.mapStyle,
      routeElevation: routeElevation ?? this.routeElevation,
      cloudSync: cloudSync ?? this.cloudSync,
      wifiOnlyUpload: wifiOnlyUpload ?? this.wifiOnlyUpload,
      autoPauseSpeedThresholdKph:
          autoPauseSpeedThresholdKph ?? this.autoPauseSpeedThresholdKph,
      autoPauseDelaySeconds:
          autoPauseDelaySeconds ?? this.autoPauseDelaySeconds,
      autoResumeSpeedThresholdKph:
          autoResumeSpeedThresholdKph ?? this.autoResumeSpeedThresholdKph,
      autoResumeDelaySeconds:
          autoResumeDelaySeconds ?? this.autoResumeDelaySeconds,
      maxAcceptableAccuracyMeters:
          maxAcceptableAccuracyMeters ?? this.maxAcceptableAccuracyMeters,
      gpsSignalLostSeconds: gpsSignalLostSeconds ?? this.gpsSignalLostSeconds,
    );
  }

  // ---- Persistence ----

  /// Flat `key -> value` projection of this object.
  ///
  /// A KV layout means a newer build can add a setting without a schema
  /// migration, and an older build simply ignores keys it does not know.
  Map<String, String> toKeyValues() => {
        'units': units.id,
        'auto_pause': autoPause.toString(),
        'start_countdown': startCountdown.id,
        'gps_accuracy': gpsAccuracy.id,
        'auto_pause_speed_kph': autoPauseSpeedThresholdKph.toString(),
        'auto_pause_delay_s': autoPauseDelaySeconds.toString(),
        'auto_resume_speed_kph': autoResumeSpeedThresholdKph.toString(),
        'auto_resume_delay_s': autoResumeDelaySeconds.toString(),
        'max_accuracy_m': maxAcceptableAccuracyMeters.toString(),
        'gps_lost_s': gpsSignalLostSeconds.toString(),
        'dashboard_config': dashboard.encode(),
        'oled_mode': oledMode.toString(),
        'pixel_shift': pixelShift.toString(),
        'dim_on_standstill': dimOnStandstill.toString(),
        'minimal_oled': minimalOled.toString(),
        'keep_screen_on': keepScreenOn.toString(),
        // Nested as a JSON object rather than one key per option, so new
        // navigation options do not each need a top-level key.
        'navigation_config': jsonEncode(navigation.toJson()),
        'map_style': mapStyle.id,
        'route_elevation': routeElevation.toString(),
        'cloud_sync': cloudSync.toString(),
        'wifi_only_upload': wifiOnlyUpload.toString(),
      };

  static AppSettings fromKeyValues(Map<String, String> kv) {
    const d = AppSettings();
    return AppSettings(
      units: UnitSystem.fromId(kv['units']),
      autoPause: _bool(kv['auto_pause'], d.autoPause),
      startCountdown: StartCountdown.fromId(kv['start_countdown']),
      gpsAccuracy: GpsAccuracyMode.fromId(kv['gps_accuracy']),
      autoPauseSpeedThresholdKph:
          _double(kv['auto_pause_speed_kph'], d.autoPauseSpeedThresholdKph),
      autoPauseDelaySeconds:
          _int(kv['auto_pause_delay_s'], d.autoPauseDelaySeconds),
      autoResumeSpeedThresholdKph:
          _double(kv['auto_resume_speed_kph'], d.autoResumeSpeedThresholdKph),
      autoResumeDelaySeconds:
          _int(kv['auto_resume_delay_s'], d.autoResumeDelaySeconds),
      maxAcceptableAccuracyMeters:
          _double(kv['max_accuracy_m'], d.maxAcceptableAccuracyMeters),
      gpsSignalLostSeconds:
          _int(kv['gps_lost_s'], d.gpsSignalLostSeconds),
      dashboard: DashboardConfig.decode(kv['dashboard_config']),
      oledMode: _bool(kv['oled_mode'], d.oledMode),
      pixelShift: _bool(kv['pixel_shift'], d.pixelShift),
      dimOnStandstill: _bool(kv['dim_on_standstill'], d.dimOnStandstill),
      minimalOled: _bool(kv['minimal_oled'], d.minimalOled),
      keepScreenOn: _bool(kv['keep_screen_on'], d.keepScreenOn),
      navigation: NavigationConfig.fromJson(
        _nestedJson(kv['navigation_config']),
      ),
      mapStyle: MapStyle.fromId(kv['map_style']),
      routeElevation: _bool(kv['route_elevation'], d.routeElevation),
      cloudSync: _bool(kv['cloud_sync'], d.cloudSync),
      wifiOnlyUpload: _bool(kv['wifi_only_upload'], d.wifiOnlyUpload),
    );
  }

  /// Parses a stored boolean, falling back on anything unrecognised.
  ///
  /// Not `v == 'true'`: that maps every unparseable value to `false`, which
  /// silently *changes* the setting rather than preserving the default. For
  /// `auto_pause` that means a corrupted byte turns auto-pause off, and the
  /// rider discovers it as a wrong moving-time figure at the end of a ride.
  static bool _bool(String? v, bool fallback) {
    if (v == null) return fallback;
    return switch (v.trim().toLowerCase()) {
      'true' || '1' => true,
      'false' || '0' => false,
      _ => fallback,
    };
  }

  static int _int(String? v, int fallback) =>
      v == null ? fallback : (int.tryParse(v) ?? fallback);

  static double _double(String? v, double fallback) =>
      v == null ? fallback : (double.tryParse(v) ?? fallback);

  static Map<String, dynamic>? _nestedJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
