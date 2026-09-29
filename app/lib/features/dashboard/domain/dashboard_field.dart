import '../../../core/utils/units.dart';
import '../../navigation/domain/navigation_state.dart';
import '../../ride/domain/ride.dart';

/// Everything a dashboard tile may need to render itself.
///
/// Passing one aggregate down rather than a dozen arguments keeps
/// [DashboardField] formatting pure and testable — a field is a function from
/// this snapshot to a string, with no widget or engine in sight.
class DashboardData {
  const DashboardData({
    this.stats = RideStats.empty,
    this.navigation,
    this.headingDegrees,
    this.gpsAccuracyMeters = 0,
    this.gpsSignalLost = false,
    this.speedAvailable = true,
    this.batteryPercent,
    this.now,
  });

  final RideStats stats;
  final NavigationSnapshot? navigation;

  /// The direction of travel in degrees clockwise from north, when there is
  /// one to report.
  ///
  /// Carried separately from [RideStats] because the compass can move it
  /// between fixes — at a standstill there may be no fix to derive a course
  /// from, and that is exactly when a rider looks at it. Null before any
  /// direction has been established.
  final double? headingDegrees;

  /// Horizontal accuracy of the most recent fix, in meters.
  final double gpsAccuracyMeters;

  /// True when no fix has arrived for a while — shown distinctly from a merely
  /// imprecise one, because the rider's response differs.
  final bool gpsSignalLost;
  final bool speedAvailable;

  final double? batteryPercent;
  final DateTime? now;

  DashboardData copyWith({
    RideStats? stats,
    NavigationSnapshot? navigation,
    double? headingDegrees,
    double? gpsAccuracyMeters,
    bool? gpsSignalLost,
    bool? speedAvailable,
    double? batteryPercent,
    DateTime? now,
  }) {
    return DashboardData(
      stats: stats ?? this.stats,
      navigation: navigation ?? this.navigation,
      headingDegrees: headingDegrees ?? this.headingDegrees,
      gpsAccuracyMeters: gpsAccuracyMeters ?? this.gpsAccuracyMeters,
      gpsSignalLost: gpsSignalLost ?? this.gpsSignalLost,
      speedAvailable: speedAvailable ?? this.speedAvailable,
      batteryPercent: batteryPercent ?? this.batteryPercent,
      now: now ?? this.now,
    );
  }
}

/// A single selectable data field for a dashboard tile.
///
/// Each value knows its own label, unit, and formatting, so adding a field is
/// one enum entry plus one `switch` arm — and the editor, the renderer, and
/// the persistence layer all pick it up automatically.
enum DashboardField {
  speed('speed', '速度', heroCapable: true),
  avgSpeed('avg_speed', '平均速度', heroCapable: true),
  maxSpeed('max_speed', '最大速度'),
  distance('distance', '距离', heroCapable: true),
  elapsedTime('elapsed_time', '骑行时间', heroCapable: true),
  movingTime('moving_time', '移动时间', heroCapable: true),
  altitude('altitude', '海拔'),
  elevationGain('elevation_gain', '爬升', heroCapable: true),
  elevationLoss('elevation_loss', '下降'),
  grade('grade', '坡度'),
  heading('heading', '方向'),
  heartRate('heart_rate', '心率', heroCapable: true, requiresSensor: true),
  avgHeartRate('avg_heart_rate', '平均心率', requiresSensor: true),
  cadence('cadence', '踏频', requiresSensor: true),
  avgCadence('avg_cadence', '平均踏频', requiresSensor: true),
  power('power', '功率', heroCapable: true, requiresSensor: true),
  avgPower('avg_power', '平均功率', requiresSensor: true),
  gpsAccuracy('gps_accuracy', 'GPS 精度'),
  battery('battery', '电量'),
  currentTime('current_time', '当前时间'),
  distanceToDestination('distance_to_destination', '剩余距离', requiresRoute: true),
  eta('eta', '预计到达', requiresRoute: true),
  distanceToNextTurn('distance_to_next_turn', '距转向', requiresRoute: true);

  const DashboardField(
    this.id,
    this.label, {
    this.heroCapable = false,
    this.requiresSensor = false,
    this.requiresRoute = false,
  });

  /// Stable identifier persisted in `dashboard_config` JSON and in the
  /// `user_settings` row. Never rename without a migration.
  final String id;

  /// Chinese display label, matching the spec's mock-ups.
  final String label;

  /// Whether this field is meaningful as the single huge number. A timestamp
  /// or a battery percentage is not.
  final bool heroCapable;

  /// Only populated when a BLE sensor of the matching type is connected.
  final bool requiresSensor;

  /// Only populated while navigating.
  final bool requiresRoute;

  static DashboardField? fromId(String id) {
    for (final f in DashboardField.values) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// The formatted value, without its unit.
  String format(DashboardData d, UnitFormatter u) {
    final s = d.stats;
    return switch (this) {
      DashboardField.speed =>
        d.speedAvailable ? u.speed(s.currentSpeedMps) : '--',
      DashboardField.avgSpeed => u.speed(s.avgSpeedMps),
      DashboardField.maxSpeed => u.speed(s.maxSpeedMps),
      DashboardField.distance => u.distance(s.distanceMeters),
      DashboardField.elapsedTime => UnitFormatter.duration(s.elapsed),
      DashboardField.movingTime => UnitFormatter.duration(s.moving),
      DashboardField.altitude => u.elevation(s.altitudeMeters),
      DashboardField.elevationGain => u.elevation(
        s.elevationGainMeters,
        withSign: true,
      ),
      DashboardField.elevationLoss => u.elevation(s.elevationLossMeters),
      DashboardField.grade => u.grade(s.gradePercent),
      DashboardField.heading => _degreesOrDash(d.headingDegrees),
      DashboardField.heartRate => _intOrDash(s.heartRate),
      DashboardField.avgHeartRate => _intOrDash(s.avgHeartRate),
      DashboardField.cadence => _intOrDash(s.cadence),
      DashboardField.avgCadence => _intOrDash(s.avgCadence),
      DashboardField.power => _intOrDash(s.power),
      DashboardField.avgPower => _intOrDash(s.avgPower),
      DashboardField.gpsAccuracy =>
        d.gpsSignalLost || d.gpsAccuracyMeters <= 0
            ? '--'
            : '±${d.gpsAccuracyMeters.round()}',
      DashboardField.battery =>
        d.batteryPercent == null ? '--' : d.batteryPercent!.round().toString(),
      DashboardField.currentTime =>
        d.now == null ? '--' : UnitFormatter.clock(d.now!),
      DashboardField.distanceToDestination =>
        d.navigation == null
            ? '--'
            : u.distanceKm(d.navigation!.distanceToDestinationMeters),
      DashboardField.eta =>
        (d.navigation?.eta) == null
            ? '--'
            : UnitFormatter.clock(d.navigation!.eta!),
      DashboardField.distanceToNextTurn => _formatDistanceToTurn(
        d.navigation?.distanceToNextTurnMeters,
        u,
      ),
    };
  }

  /// Degrees clockwise from north, always three digits.
  ///
  /// Zero-padded so the tile keeps its width across the whole circle — the
  /// same reason every other field has a fixed shape, and the reason the
  /// rounding wraps before it can print `360`.
  static String _degreesOrDash(double? degrees) {
    if (degrees == null || !degrees.isFinite) return '--';
    return (degrees.round() % 360).toString().padLeft(3, '0');
  }

  /// Under a kilometre the rider needs meters; above it, a single decimal is
  /// as much precision as is honest at speed.
  static String _formatDistanceToTurn(double? meters, UnitFormatter u) {
    if (meters == null) return '--';
    if (u.system.isMetric) {
      return meters < 1000
          ? meters.round().toString()
          : (meters / 1000).toStringAsFixed(1);
    }
    final feet = meters * 3.280839895;
    return feet < 1000
        ? feet.round().toString()
        : (meters / 1609.344).toStringAsFixed(1);
  }

  /// The unit shown beneath the value, or `''` when the value implies none.
  String unitLabel(DashboardData d, UnitFormatter u) {
    return switch (this) {
      DashboardField.speed ||
      DashboardField.avgSpeed ||
      DashboardField.maxSpeed => u.system.speedSuffix,
      // Adaptive, not fixed: `format` renders 135 metres as `135`, and a
      // fixed `km` label turns that into "135 km".
      DashboardField.distance => u.distanceUnit(d.stats.distanceMeters),
      DashboardField.elapsedTime || DashboardField.movingTime => '',
      DashboardField.altitude ||
      DashboardField.elevationGain ||
      DashboardField.elevationLoss => u.system.elevationSuffix,
      DashboardField.grade => '',
      DashboardField.heading => '°',
      DashboardField.heartRate || DashboardField.avgHeartRate => 'bpm',
      DashboardField.cadence || DashboardField.avgCadence => 'rpm',
      DashboardField.power || DashboardField.avgPower => 'W',
      DashboardField.gpsAccuracy => 'm',
      DashboardField.battery => '%',
      DashboardField.currentTime => '',
      DashboardField.distanceToDestination => u.system.isMetric ? 'km' : 'mi',
      DashboardField.eta => '',
      DashboardField.distanceToNextTurn => 'm',
    };
  }

  /// Whether this field has a live value right now. Unavailable fields are
  /// shown as `--` rather than hidden, so the layout does not reflow mid-ride.
  bool isAvailable(DashboardData d) {
    if (requiresSensor) {
      final s = d.stats;
      final has = switch (this) {
        DashboardField.heartRate || DashboardField.avgHeartRate =>
          s.heartRate != null || s.avgHeartRate != null,
        DashboardField.cadence ||
        DashboardField.avgCadence => s.cadence != null || s.avgCadence != null,
        DashboardField.power ||
        DashboardField.avgPower => s.power != null || s.avgPower != null,
        _ => false,
      };
      if (!has) return false;
    }
    if (requiresRoute && d.navigation == null) return false;
    if (this == DashboardField.battery && d.batteryPercent == null) {
      return false;
    }
    // No direction has been established yet — the usual case in the first
    // seconds of a ride, before any fix has said which way the bike is going.
    if (this == DashboardField.heading && d.headingDegrees == null) {
      return false;
    }
    return true;
  }

  static String _intOrDash(int? v) => v == null ? '--' : v.toString();
}
