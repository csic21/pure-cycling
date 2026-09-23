import '../utils/geo.dart';

/// A raw position sample, straight from the platform.
///
/// Deliberately distinct from `TrackPoint`: a fix has not been validated yet,
/// and keeping the two types apart means an unfiltered sample cannot reach the
/// database or the distance accumulator by accident. The compiler enforces the
/// pipeline in spec §13 — raw GPS, validation, smoothing, distance, stats.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.altitude,
    this.altitudeAccuracy,
    this.accuracy = 0,
    this.speed,
    this.speedAccuracy,
    this.heading,
    this.headingAccuracy,
    this.isMocked = false,
  });

  final double latitude;
  final double longitude;

  /// Device time the fix was produced. UTC.
  final DateTime timestamp;

  /// Meters above mean sea level. GPS altitude is noisy; a barometer-backed
  /// value from the platform is preferred when the device has one.
  final double? altitude;
  final double? altitudeAccuracy;

  /// Horizontal accuracy in meters — the radius of 68% confidence.
  ///
  /// Zero means the platform did not report one, which is treated as "unknown"
  /// rather than "perfect".
  final double accuracy;

  final double? speed;
  final double? speedAccuracy;

  /// Degrees clockwise from north.
  final double? heading;
  final double? headingAccuracy;

  /// Android reports location spoofing; such a fix is recorded but flagged.
  final bool isMocked;

  GeoPoint get geo => GeoPoint(latitude, longitude);

  /// Whether the platform actually supplied an accuracy radius.
  bool get hasAccuracy => accuracy > 0;

  /// Whether the platform supplied a usable ground speed.
  bool get hasSpeed => speed != null && speed! >= 0;

  @override
  String toString() =>
      'LocationFix(${timestamp.toIso8601String()} '
      '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)} '
      'acc=${accuracy.toStringAsFixed(1)} spd=${speed?.toStringAsFixed(2)})';
}
