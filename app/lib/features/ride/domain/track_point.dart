import '../../../core/utils/geo.dart';

/// A single accepted GPS sample plus any sensor values captured alongside it.
///
/// Only points that survived [GpsFilter] validation are ever constructed as a
/// `TrackPoint` — the raw fix is a separate type on purpose, so a rejected
/// sample cannot accidentally reach the database or the distance accumulator.
class TrackPoint {
  const TrackPoint({
    required this.timestamp,
    required this.lat,
    required this.lng,
    this.sequence = 0,
    this.rideId = '',
    this.altitude,
    this.speed,
    this.bearing,
    this.horizontalAccuracy,
    this.verticalAccuracy,
    this.heartRate,
    this.cadence,
    this.power,
  });

  /// Which ride this sample belongs to. Empty for points not yet persisted.
  final String rideId;

  /// Monotonic index within the ride, starting at 0. Ordering by sequence is
  /// stable even when two samples share a millisecond timestamp.
  final int sequence;

  /// Device time the fix was taken. Always UTC internally.
  final DateTime timestamp;

  final double lat;
  final double lng;

  /// Barometric or GPS altitude in meters above mean sea level, if available.
  final double? altitude;

  /// Smoothed ground speed in m/s. This is the engine's value, not the raw
  /// GPS-reported speed — see `GpsFilter`.
  final double? speed;

  /// Heading in degrees clockwise from north.
  final double? bearing;

  /// 68% confidence radius of the horizontal fix, in meters.
  final double? horizontalAccuracy;

  final double? verticalAccuracy;

  final int? heartRate;
  final int? cadence;
  final int? power;

  GeoPoint get geo => GeoPoint(lat, lng);

  /// A GPS read this inaccurate is unusable for distance; the filter drops it
  /// from accumulation but it may still be stored for the raw trace.
  bool get isUsableForDistance =>
      horizontalAccuracy == null || horizontalAccuracy! <= 50.0;

  TrackPoint copyWith({
    String? rideId,
    int? sequence,
    DateTime? timestamp,
    double? lat,
    double? lng,
    double? altitude,
    double? speed,
    double? bearing,
    double? horizontalAccuracy,
    double? verticalAccuracy,
    int? heartRate,
    int? cadence,
    int? power,
  }) {
    return TrackPoint(
      rideId: rideId ?? this.rideId,
      sequence: sequence ?? this.sequence,
      timestamp: timestamp ?? this.timestamp,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      altitude: altitude ?? this.altitude,
      speed: speed ?? this.speed,
      bearing: bearing ?? this.bearing,
      horizontalAccuracy: horizontalAccuracy ?? this.horizontalAccuracy,
      verticalAccuracy: verticalAccuracy ?? this.verticalAccuracy,
      heartRate: heartRate ?? this.heartRate,
      cadence: cadence ?? this.cadence,
      power: power ?? this.power,
    );
  }

  @override
  String toString() =>
      'TrackPoint(#$sequence ${timestamp.toIso8601String()} '
      '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)} '
      'v=${speed?.toStringAsFixed(2)} acc=${horizontalAccuracy?.toStringAsFixed(1)})';
}
