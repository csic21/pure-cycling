import 'dart:typed_data';

import '../domain/sensor.dart';

/// Decoders for the standard BLE cycling profiles.
///
/// Pure functions over byte arrays, with no Bluetooth stack in sight — which
/// is what makes them testable against captured packets from a real strap
/// rather than against a live device on a workbench.
///
/// The three profiles the app needs:
///
/// | Service | UUID   | Values                       |
/// |---------|--------|------------------------------|
/// | Heart Rate | 0x180D | bpm, RR intervals          |
/// | Cycling Speed and Cadence | 0x1816 | wheel and crank revolutions |
/// | Cycling Power | 0x1818 | watts, cadence             |
abstract final class GattParsers {
  // ---- Service and characteristic UUIDs ----

  static const String heartRateService = '180D';
  static const String heartRateMeasurement = '2A37';
  static const String bodySensorLocation = '2A38';

  static const String cscService = '1816';
  static const String cscMeasurement = '2A5B';
  static const String cscFeature = '2A5C';

  static const String cyclingPowerService = '1818';
  static const String cyclingPowerMeasurement = '2A63';

  static const String batteryService = '180F';
  static const String batteryLevel = '2A19';

  /// GATT services the app cares about, for scan filtering.
  static const List<String> supportedServices = [
    heartRateService,
    cscService,
    cyclingPowerService,
  ];

  /// Maps an advertised service UUID to the sensor type it provides.
  ///
  /// 0x1816 is one service carrying two measurements — a combined speed and
  /// cadence sensor advertises only this — so it maps to cadence here and the
  /// *measurement flags* decide what each packet actually contains. Labelling
  /// the device as a cadence sensor and reading wheel data from it if present
  /// is the behaviour riders expect from a two-in-one unit.
  /// Advertised service UUID (in either form) to the sensor it provides.
  static const Map<String, SensorType> _serviceTypes = {
    heartRateService: SensorType.heartRate,
    cscService: SensorType.cadence,
    cyclingPowerService: SensorType.power,
  };

  static SensorType? typeForService(String uuid) {
    // Compare in the normalized form on *both* sides. Matching a normalized
    // UUID against the short constants compares
    // `0000180D-0000-1000-8000-00805F9B34FB` with `180D`, which is never
    // equal — so the scan would find no devices at all, silently, and every
    // sensor would simply be missing from the list.
    final normalized = normalizeUuid(uuid);
    for (final entry in _serviceTypes.entries) {
      if (normalizeUuid(entry.key) == normalized) return entry.value;
    }
    return null;
  }

  /// Expands a short 16-bit UUID to the full 128-bit form and upper-cases it.
  ///
  /// Android reports `180D`, iOS reports
  /// `0000180D-0000-1000-8000-00805F9B34FB`, and the same device can appear
  /// differently across platforms.
  static String normalizeUuid(String uuid) {
    final upper = uuid.toUpperCase();
    if (upper.length == 4) {
      return '0000$upper-0000-1000-8000-00805F9B34FB';
    }
    return upper;
  }

  /// Whether a UUID matches a short 16-bit form.
  static bool matches(String uuid, String shortForm) =>
      normalizeUuid(uuid) == normalizeUuid(shortForm);

  // ---- Heart Rate (0x2A37) ----

  /// Decodes a heart rate measurement.
  ///
  /// Byte 0 is a flags field: bit 0 says whether the value is 8- or 16-bit,
  /// bits 1-2 the sensor contact state, bit 3 whether energy expended is
  /// present, bit 4 whether RR intervals follow.
  ///
  /// Reading the rate as a single byte unconditionally is the classic bug —
  /// it works on every chest strap (which all use 8-bit) and silently produces
  /// a value of 0 or 256+ on the straps that use the wider form.
  static int? parseHeartRate(Uint8List data) {
    if (data.isEmpty) return null;

    final flags = data[0];
    final isUint16 = (flags & 0x01) != 0;
    final hasEnergyExpended = (flags & 0x08) != 0;
    final hasRrIntervals = (flags & 0x10) != 0;

    var offset = 1;
    int bpm;

    if (isUint16) {
      if (data.length < offset + 2) return null;
      bpm = data[offset] | (data[offset + 1] << 8);
      offset += 2;
    } else {
      if (data.length < offset + 1) return null;
      bpm = data[offset];
      offset += 1;
    }

    if (bpm <= 0 || bpm > 260) return null;

    // The remaining fields are parsed only to document the layout and to
    // advance past them if RR data is ever needed. They are not used yet.
    if (hasEnergyExpended) offset += 2;
    if (hasRrIntervals) offset += 2;

    return bpm;
  }

  /// Decodes the body sensor location characteristic, for the settings list.
  static String? parseBodySensorLocation(Uint8List data) {
    if (data.isEmpty) return null;
    return switch (data[0]) {
      0 => '其他',
      1 => '胸部',
      2 => '手腕',
      3 => '手指',
      4 => '手掌',
      5 => '耳垂',
      6 => '脚',
      _ => null,
    };
  }

  // ---- Cycling Speed and Cadence (0x2A5B) ----

  /// Decodes a CSC measurement.
  ///
  /// Both fields are cumulative *revolution counts* paired with the time of
  /// the last revolution in 1/1024 s units — not rates. Converting to a
  /// cadence or a speed requires the previous packet and the wheel
  /// circumference, which is what [CscAccumulator] exists for.
  ///
  /// Bits shift depending on which fields are present, and the time values are
  /// 16-bit, so a stalled sensor wraps every 64 seconds. Handling the wrap is
  /// the difference between a cadence readout that works and one that shows
  /// 4000 rpm once a minute.
  static CscMeasurement? parseCsc(Uint8List data) {
    if (data.isEmpty) return null;

    final flags = data[0];
    final hasWheel = (flags & 0x01) != 0;
    final hasCrank = (flags & 0x02) != 0;

    var offset = 1;

    int? wheelRevolutions;
    int? wheelEventTime;

    if (hasWheel) {
      if (data.length < offset + 6) return null;
      wheelRevolutions = _uint32(data, offset);
      wheelEventTime = _uint16(data, offset + 4);
      offset += 6;
    }

    int? crankRevolutions;
    int? crankEventTime;

    if (hasCrank) {
      if (data.length < offset + 4) return null;
      crankRevolutions = _uint16(data, offset);
      crankEventTime = _uint16(data, offset + 2);
    }

    if (!hasWheel && !hasCrank) return null;

    return CscMeasurement(
      wheelRevolutions: wheelRevolutions,
      wheelEventTimeUnits: wheelEventTime,
      crankRevolutions: crankRevolutions,
      crankEventTimeUnits: crankEventTime,
    );
  }

  // ---- Cycling Power (0x2A63) ----

  /// Decodes a cycling power measurement.
  ///
  /// Byte 0-1 are flags. Instantaneous power is always present at offset 2.
  /// Crank revolution data (a cadence source) appears only when bit 5 is set,
  /// at an offset that depends on which optional fields precede it — which is
  /// why the offset has to be walked rather than assumed.
  static PowerMeasurement? parsePower(Uint8List data) {
    if (data.length < 4) return null;

    final flags = _uint16(data, 0);

    final hasPedalBalance = (flags & 0x0001) != 0;
    final hasPedalPower = (flags & 0x0400) != 0;
    final hasAccumulatedTorque = (flags & 0x0200) != 0;
    final hasWheelRev = (flags & 0x0100) != 0;
    final hasCrankRev = (flags & 0x0020) != 0;
    final hasExtremeMagnitudes = (flags & 0x0002) != 0;
    final hasExtremeAngles = (flags & 0x0004) != 0;
    final hasTopDeadSpot = (flags & 0x0008) != 0;
    final hasBottomDeadSpot = (flags & 0x0010) != 0;
    final hasAccumulatedEnergy = (flags & 0x0080) != 0;

    // Bit 0 and bit 1 conflict in some early firmware; prefer the balance
    // interpretation, which is the one the spec settled on.
    var offset = 2;

    final watts = _int16(data, offset);
    offset += 2;

    if (hasPedalBalance) offset += 1;
    if (hasPedalPower) offset += 2;
    if (hasAccumulatedTorque) offset += 2;

    int? crankRevolutions;
    int? crankEventTime;

    if (hasWheelRev) offset += 6;

    if (hasCrankRev) {
      if (data.length < offset + 4) {
        return PowerMeasurement(watts: watts);
      }
      crankRevolutions = _uint16(data, offset);
      crankEventTime = _uint16(data, offset + 2);
      offset += 4;
    }

    if (hasExtremeMagnitudes) offset += 4;
    if (hasExtremeAngles) offset += 3;
    if (hasTopDeadSpot) offset += 2;
    if (hasBottomDeadSpot) offset += 2;
    if (hasAccumulatedEnergy) offset += 2;

    return PowerMeasurement(
      watts: watts,
      crankRevolutions: crankRevolutions,
      crankEventTimeUnits: crankEventTime,
    );
  }

  // ---- Battery (0x2A19) ----

  static int? parseBatteryLevel(Uint8List data) {
    if (data.isEmpty) return null;
    final level = data[0];
    return level <= 100 ? level : null;
  }

  // ---- byte helpers ----

  static int _uint16(Uint8List d, int i) => d[i] | (d[i + 1] << 8);

  static int _int16(Uint8List d, int i) {
    final raw = _uint16(d, i);
    return raw >= 0x8000 ? raw - 0x10000 : raw;
  }

  static int _uint32(Uint8List d, int i) =>
      d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] << 24);
}

/// A raw CSC measurement: cumulative revolutions, not rates.
class CscMeasurement {
  const CscMeasurement({
    this.wheelRevolutions,
    this.wheelEventTimeUnits,
    this.crankRevolutions,
    this.crankEventTimeUnits,
  });

  final int? wheelRevolutions;

  /// 1/1024 second units, 16-bit and therefore wrapping.
  final int? wheelEventTimeUnits;

  final int? crankRevolutions;
  final int? crankEventTimeUnits;

  bool get hasWheel => wheelRevolutions != null && wheelEventTimeUnits != null;
  bool get hasCrank => crankRevolutions != null && crankEventTimeUnits != null;
}

/// A decoded cycling power measurement.
class PowerMeasurement {
  const PowerMeasurement({
    required this.watts,
    this.crankRevolutions,
    this.crankEventTimeUnits,
  });

  final int watts;
  final int? crankRevolutions;
  final int? crankEventTimeUnits;
}

/// Converts the cumulative counters in CSC and power packets into rates.
///
/// The counters are 16-bit and wrap. The event timestamps are in 1/1024 s and
/// also wrap — every 64 seconds. Both have to be handled by computing deltas
/// modulo their range rather than by subtracting.
class CscAccumulator {
  CscAccumulator({this.wheelCircumferenceMeters = 2.105});

  /// Default for a 700×25c tyre. Wrong for a mountain bike by about 5%, which
  /// is why the spec puts a wheel-size setting in V2 — until then this is a
  /// fallback, not an authority: the ride engine only trusts a speed sensor
  /// when GPS is weak.
  double wheelCircumferenceMeters;

  int? _lastWheelRevolutions;
  int? _lastWheelEventTime;
  int? _lastCrankRevolutions;
  int? _lastCrankEventTime;

  /// Cadence in rpm, or null when there is not yet a usable pair of samples.
  int? addCrank(int revolutions, int eventTimeUnits) {
    final lastRevs = _lastCrankRevolutions;
    final lastTime = _lastCrankEventTime;
    _lastCrankRevolutions = revolutions;
    _lastCrankEventTime = eventTimeUnits;

    if (lastRevs == null || lastTime == null) return null;

    final revDelta = _wrap16(revolutions - lastRevs);
    final timeDelta = _wrap16(eventTimeUnits - lastTime);

    // A delta of zero means the sensor re-sent the same revolution, which
    // happens at rest; reporting 0 rpm is correct, dividing is not.
    if (timeDelta == 0) return null;
    if (revDelta == 0) return 0;

    final seconds = timeDelta / 1024.0;
    final rpm = revDelta / seconds * 60.0;
    if (!rpm.isFinite || rpm < 0 || rpm > 250) return null;
    return rpm.round();
  }

  /// Speed in km/h from wheel revolutions.
  double? addWheel(int revolutions, int eventTimeUnits) {
    final lastRevs = _lastWheelRevolutions;
    final lastTime = _lastWheelEventTime;
    _lastWheelRevolutions = revolutions;
    _lastWheelEventTime = eventTimeUnits;

    if (lastRevs == null || lastTime == null) return null;

    final revDelta = _wrap16(revolutions - lastRevs);
    final timeDelta = _wrap16(eventTimeUnits - lastTime);

    if (timeDelta == 0) return null;
    if (revDelta == 0) return 0;

    final seconds = timeDelta / 1024.0;
    final metersPerSecond = revDelta * wheelCircumferenceMeters / seconds;
    if (!metersPerSecond.isFinite ||
        metersPerSecond < 0 ||
        metersPerSecond > 40) {
      return null;
    }
    return metersPerSecond * 3.6;
  }

  /// Unsigned wraparound of a 16-bit counter.
  static int _wrap16(int delta) {
    var d = delta & 0xFFFF;
    // A delta larger than half the range is a wrap in the other direction —
    // the counters only ever advance, so the small interpretation is right.
    if (d > 0x7FFF) d -= 0x10000;
    if (d < 0) d += 0x10000;
    return d;
  }

  void reset() {
    _lastWheelRevolutions = null;
    _lastWheelEventTime = null;
    _lastCrankRevolutions = null;
    _lastCrankEventTime = null;
  }
}
