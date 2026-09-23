/// Distance / elevation / speed unit system.
enum UnitSystem {
  metric('metric', 'km / m'),
  imperial('imperial', 'mile / ft');

  const UnitSystem(this.id, this.label);

  final String id;
  final String label;

  static UnitSystem fromId(String? id) => UnitSystem.values.firstWhere(
        (u) => u.id == id,
        orElse: () => UnitSystem.metric,
      );

  bool get isMetric => this == UnitSystem.metric;

  String get distanceSuffix => isMetric ? 'km' : 'mi';
  String get shortDistanceSuffix => isMetric ? 'm' : 'ft';
  String get speedSuffix => isMetric ? 'km/h' : 'mph';
  String get elevationSuffix => isMetric ? 'm' : 'ft';
}

const double _metersPerMile = 1609.344;
const double _feetPerMeter = 3.280839895;

/// Formats raw SI values (meters, m/s, seconds) for display.
///
/// Every displayed number in the app goes through here so unit switching is a
/// single setting rather than a formatting concern scattered across widgets.
class UnitFormatter {
  const UnitFormatter(this.system);

  final UnitSystem system;

  /// Distance with an adaptive unit: meters below 1 km, else km.
  ///
  /// `decimals` controls precision in the large unit; the small unit is always
  /// rendered as a whole number.
  String distance(double meters, {int decimals = 2}) {
    if (!meters.isFinite) return '--';
    if (system.isMetric) {
      if (meters.abs() < 1000) return '${meters.round()}';
      return (meters / 1000).toStringAsFixed(decimals);
    }
    final miles = meters / _metersPerMile;
    if (miles.abs() < 0.1) return (meters * _feetPerMeter).round().toString();
    return miles.toStringAsFixed(decimals);
  }

  /// The unit label matching [distance]'s adaptive choice.
  String distanceUnit(double meters) {
    if (!meters.isFinite) return system.distanceSuffix;
    if (system.isMetric) {
      return meters.abs() < 1000 ? 'm' : 'km';
    }
    return (meters / _metersPerMile).abs() < 0.1 ? 'ft' : 'mi';
  }

  /// Distance always expressed in the large unit (km / mi).
  String distanceKm(double meters, {int decimals = 2}) {
    if (!meters.isFinite) return '--';
    final v =
        system.isMetric ? meters / 1000 : meters / _metersPerMile;
    return v.toStringAsFixed(decimals);
  }

  /// Speed from meters per second.
  String speed(double metersPerSecond, {int decimals = 1}) {
    if (!metersPerSecond.isFinite) return '--';
    final v = system.isMetric
        ? metersPerSecond * 3.6
        : metersPerSecond * 3600 / _metersPerMile;
    return v.toStringAsFixed(decimals);
  }

  /// Speed as a whole number — used by the hero readout, which has no room
  /// for a decimal and is read at a glance while riding.
  String speedWhole(double metersPerSecond) => speed(metersPerSecond, decimals: 0);

  /// Elevation from meters, always a whole number.
  String elevation(double meters, {bool withSign = false}) {
    if (!meters.isFinite) return '--';
    final v = system.isMetric ? meters : meters * _feetPerMeter;
    final rounded = v.round();
    if (withSign && rounded > 0) return '+$rounded';
    return '$rounded';
  }

  /// Elevation with its unit appended, for standalone labels.
  String elevationWithUnit(double meters, {bool withSign = false}) =>
      '${elevation(meters, withSign: withSign)} ${system.elevationSuffix}';

  /// Gradient as a percentage.
  String grade(double percent, {int decimals = 1}) {
    if (!percent.isFinite) return '--';
    return '${percent.toStringAsFixed(decimals)}%';
  }

  /// `H:MM:SS`, or `M:SS` under an hour.
  ///
  /// Elapsed time is a duration, not a clock reading, so it is formatted the
  /// way a bike computer shows it.
  static String duration(Duration d) {
    final total = d.inSeconds.abs();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Compact duration for dense rows: `1h 52m`, `48m`, `32s`.
  static String durationCompact(Duration d) {
    final total = d.inSeconds.abs();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    if (hours > 0) {
      return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
    }
    if (minutes > 0) return '${minutes}m';
    return '${total}s';
  }

  /// Minutes remaining, for ETAs — never shows seconds, which would be false
  /// precision on a bike.
  static String durationMinutes(Duration d) {
    final minutes = (d.inSeconds / 60).round();
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return rem > 0 ? '${hours}h ${rem}m' : '${hours}h';
  }

  /// Local wall-clock time as `HH:MM`.
  static String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Short date as `MM/DD`.
  static String shortDate(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')}';

  /// Date heading as `9 月 23 日`.
  static String dateHeading(DateTime t) => '${t.month} 月 ${t.day} 日';

  /// Month heading as `2026 / 09`.
  static String monthHeading(DateTime t) =>
      '${t.year} / ${t.month.toString().padLeft(2, '0')}';
}
