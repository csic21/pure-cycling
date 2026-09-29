/// The kinds of BLE sensor the app understands.
///
/// Mirrors the standard GATT services: Heart Rate (0x180D), Cycling Speed and
/// Cadence (0x1816), and Cycling Power (0x1818). The UI never sees a brand or
/// a service UUID — only one of these types and a [SensorReading].
enum SensorType {
  heartRate('heart_rate', '心率带', 'bpm'),
  cadence('cadence', '踏频器', 'rpm'),
  speed('speed', '速度传感器', 'km/h'),
  power('power', '功率计', 'W');

  const SensorType(this.id, this.label, this.unit);

  final String id;
  final String label;
  final String unit;

  static SensorType? fromId(String id) {
    for (final t in SensorType.values) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// A device the user has paired.
class PairedSensor {
  const PairedSensor({
    required this.id,
    required this.name,
    required this.type,
    this.enabled = true,
    this.lastConnectedAt,
  });

  final String id;
  final String name;
  final SensorType type;
  final bool enabled;
  final DateTime? lastConnectedAt;

  PairedSensor copyWith({
    String? name,
    bool? enabled,
    DateTime? lastConnectedAt,
  }) => PairedSensor(
    id: id,
    name: name ?? this.name,
    type: type,
    enabled: enabled ?? this.enabled,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
  );
}

/// A single value from a sensor, normalized across devices.
///
/// Every device driver funnels into this shape (spec §35), which is what lets
/// the ride engine and the dashboard stay brand-agnostic — and lets a future
/// ANT+ or mock source plug in without touching either.
class SensorReading {
  const SensorReading({
    required this.type,
    required this.value,
    required this.timestamp,
    this.sensorId,
  });

  final SensorType type;
  final double value;
  final DateTime timestamp;
  final String? sensorId;

  /// Instantaneous cadence in rpm, if this is a cadence reading.
  int? get cadence => type == SensorType.cadence ? value.round() : null;

  int? get heartRate => type == SensorType.heartRate ? value.round() : null;

  int? get power => type == SensorType.power ? value.round() : null;

  /// Speed sensors report km/h; the engine works in m/s throughout.
  double? get speedMps => type == SensorType.speed ? value / 3.6 : null;

  Map<String, dynamic> toJson() => {
    'type': type.id,
    'value': value,
    'timestamp': timestamp.toUtc().millisecondsSinceEpoch ~/ 1000,
    if (sensorId != null) 'sensor_id': sensorId,
  };
}

/// Connection state of one sensor, for the settings list.
enum SensorConnectionState { disconnected, connecting, connected }

/// A sensor plus its live connection state.
class SensorStatus {
  const SensorStatus({
    required this.sensor,
    this.state = SensorConnectionState.disconnected,
    this.batteryPercent,
    this.lastValue,
    this.error,
  });

  final PairedSensor sensor;
  final SensorConnectionState state;
  final int? batteryPercent;
  final double? lastValue;
  final String? error;

  SensorStatus copyWith({
    PairedSensor? sensor,
    SensorConnectionState? state,
    int? batteryPercent,
    double? lastValue,
    String? error,
    bool clearError = false,
  }) => SensorStatus(
    sensor: sensor ?? this.sensor,
    state: state ?? this.state,
    batteryPercent: batteryPercent ?? this.batteryPercent,
    lastValue: lastValue ?? this.lastValue,
    error: clearError ? null : (error ?? this.error),
  );
}
