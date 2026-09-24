import 'dart:typed_data';

import '../../features/ride/domain/ride.dart';
import '../../features/ride/domain/track_point.dart';
import '../utils/geo.dart';

/// Garmin FIT activity files (spec §2.3).
///
/// Written by hand rather than through a FIT library, for the same reason the
/// GPX codec is: the file is a fixed, small message sequence, and the export
/// runs while the rider is standing next to the bike waiting to share it. A
/// dependency would have to be shipped in the app for one button; here the
/// format is in the repository and the tests decode it with an independent
/// parser (`fit_tool`, a dev dependency) so the bytes are not verified by the
/// code that produced them.
///
/// ## What the file contains
///
/// ```text
/// file_id     activity, manufacturer = development
/// event       timer / start
/// record *    one per accepted GPS sample
/// event       timer / stop_all
/// lap         one lap covering the whole ride
/// session     totals and averages, sport = cycling
/// activity    one session, local time
/// ```
///
/// The message order matches what Garmin devices write (verified against the
/// FIT SDK's own `Activity.fit`), which is what parsers are built to expect.
///
/// ## Two details that are easy to get wrong
///
/// **Positions are semicircles**, not degrees: `degrees * 2^31 / 180`, a
/// signed 32-bit integer. Writing degrees here produces a file that parses
/// cleanly and puts the rider in the wrong hemisphere.
///
/// **The record definition is fixed for the whole file.** A definition message
/// declares the fields every following data message carries, so a ride where
/// only some points have a heart rate still declares the field and writes the
/// invalid marker for the points without one. The field set is therefore
/// decided once, from the whole trace, not per point.
abstract final class FitCodec {
  /// Seconds between the Unix epoch and the FIT epoch (1989-12-31 00:00:00Z).
  static const int fitEpochOffsetSeconds = 631065600;

  /// Protocol 2.0. The profile version is the one the verification data was
  /// read from (FIT profile 21.60).
  static const int _protocolVersion = 0x20;
  static const int _profileVersion = 2160;

  static const int _enum = 0x00;
  static const int _uint8 = 0x02;
  static const int _uint16 = 0x84;
  static const int _sint32 = 0x85;
  static const int _uint32 = 0x86;

  static const int _invalid8 = 0xFF;
  static const int _invalid16 = 0xFFFF;

  static const double _semicirclesPerDegree = 2147483648.0 / 180.0;

  /// Serializes a ride and its trace to a FIT activity file.
  ///
  /// [createdAt] is only injectable so tests can produce a fixed byte stream;
  /// production callers leave it alone.
  static Uint8List encode(
    Ride ride,
    List<TrackPoint> points, {
    DateTime? createdAt,
  }) {
    final startedAt = ride.startedAt.toUtc();
    final endedAt =
        (ride.endedAt ?? (points.isNotEmpty ? points.last.timestamp : startedAt))
            .toUtc();

    // Which optional fields this ride has at all. See the class comment.
    final hasAltitude = points.any((p) => _finite(p.altitude));
    final hasSpeed = points.any((p) => _finite(p.speed) && p.speed! >= 0);
    final hasHeartRate = points.any((p) => p.heartRate != null);
    final hasCadence = points.any((p) => p.cadence != null);
    final hasPower = points.any((p) => p.power != null);

    final avgHeartRate =
        ride.stats.avgHeartRate ?? _average(points, (p) => p.heartRate);
    final avgCadence =
        ride.stats.avgCadence ?? _average(points, (p) => p.cadence);
    final avgPower = ride.stats.avgPower ?? _average(points, (p) => p.power);
    final maxHeartRate = _max(points, (p) => p.heartRate);
    final maxCadence = _max(points, (p) => p.cadence);
    final maxPower = _max(points, (p) => p.power);

    final startPosition = points.isNotEmpty
        ? (lat: points.first.lat, lng: points.first.lng)
        : null;
    final endPosition = points.isNotEmpty
        ? (lat: points.last.lat, lng: points.last.lng)
        : null;

    final body = BytesBuilder(copy: false);

    // ---- file_id ----
    _writeDefinition(
      body,
      localId: 0,
      globalId: 0,
      fields: const [
        (id: 0, size: 1, type: _enum), // type
        (id: 1, size: 2, type: _uint16), // manufacturer
        (id: 2, size: 2, type: _uint16), // product
        (id: 4, size: 4, type: _uint32), // time_created
      ],
    );
    _writeDataHeader(body, 0);
    _writeUint(body, 4, 1); // activity
    _writeUint(body, 255, 2); // development
    _writeUint(body, 0, 2); // product
    _writeUint(body, _fitSeconds(createdAt ?? DateTime.now()), 4);

    // ---- event: timer start ----
    _writeDefinition(
      body,
      localId: 1,
      globalId: 21,
      fields: const [
        (id: 253, size: 4, type: _uint32), // timestamp
        (id: 0, size: 1, type: _enum), // event
        (id: 1, size: 1, type: _enum), // event_type
      ],
    );
    _writeDataHeader(body, 1);
    _writeUint(body, _fitSeconds(startedAt), 4);
    _writeUint(body, 0, 1); // timer
    _writeUint(body, 0, 1); // start

    // ---- record ----
    _writeDefinition(
      body,
      localId: 2,
      globalId: 20,
      fields: [
        const (id: 253, size: 4, type: _uint32), // timestamp
        const (id: 0, size: 4, type: _sint32), // position_lat
        const (id: 1, size: 4, type: _sint32), // position_long
        if (hasAltitude) const (id: 2, size: 2, type: _uint16),
        if (hasHeartRate) const (id: 3, size: 1, type: _uint8),
        if (hasCadence) const (id: 4, size: 1, type: _uint8),
        const (id: 5, size: 4, type: _uint32), // distance
        if (hasSpeed) const (id: 6, size: 2, type: _uint16),
        if (hasPower) const (id: 7, size: 2, type: _uint16),
      ],
    );

    // Cumulative distance along the trace, in meters. Computed here rather
    // than taken from the ride stats so the record stream is self-consistent;
    // the summary messages use the stats, which are the same number the rider
    // saw on the screen.
    var cumulativeMeters = 0.0;
    TrackPoint? previous;
    for (final point in points) {
      if (previous != null) {
        cumulativeMeters += haversineMeters(
          previous.lat,
          previous.lng,
          point.lat,
          point.lng,
        );
      }
      previous = point;

      _writeDataHeader(body, 2);
      _writeUint(body, _fitSeconds(point.timestamp), 4);
      _writeInt(body, _semicircles(point.lat), 4);
      _writeInt(body, _semicircles(point.lng), 4);
      if (hasAltitude) _writeUint(body, _altitudeValue(point.altitude), 2);
      if (hasHeartRate) _writeUint(body, _byteValue(point.heartRate), 1);
      if (hasCadence) _writeUint(body, _byteValue(point.cadence), 1);
      _writeUint(body, _centiValue(cumulativeMeters), 4);
      if (hasSpeed) _writeUint(body, _speedValue(point.speed), 2);
      if (hasPower) _writeUint(body, _powerValue(point.power), 2);
    }

    // ---- event: timer stop_all (reuses the start definition) ----
    _writeDataHeader(body, 1);
    _writeUint(body, _fitSeconds(endedAt), 4);
    _writeUint(body, 0, 1); // timer
    _writeUint(body, 4, 1); // stop_all

    // ---- lap ----
    final lapFields = <({int id, int size, int type})>[
      const (id: 253, size: 4, type: _uint32), // timestamp
      const (id: 0, size: 1, type: _enum), // event
      const (id: 1, size: 1, type: _enum), // event_type
      const (id: 2, size: 4, type: _uint32), // start_time
      if (startPosition != null) ...[
        const (id: 3, size: 4, type: _sint32), // start_position_lat
        const (id: 4, size: 4, type: _sint32), // start_position_long
        const (id: 5, size: 4, type: _sint32), // end_position_lat
        const (id: 6, size: 4, type: _sint32), // end_position_long
      ],
      const (id: 7, size: 4, type: _uint32), // total_elapsed_time
      const (id: 8, size: 4, type: _uint32), // total_timer_time
      const (id: 9, size: 4, type: _uint32), // total_distance
      const (id: 13, size: 2, type: _uint16), // avg_speed
      const (id: 14, size: 2, type: _uint16), // max_speed
      if (avgHeartRate != null) const (id: 15, size: 1, type: _uint8),
      if (maxHeartRate != null) const (id: 16, size: 1, type: _uint8),
      if (avgCadence != null) const (id: 17, size: 1, type: _uint8),
      if (maxCadence != null) const (id: 18, size: 1, type: _uint8),
      if (avgPower != null) const (id: 19, size: 2, type: _uint16),
      if (maxPower != null) const (id: 20, size: 2, type: _uint16),
      const (id: 21, size: 2, type: _uint16), // total_ascent
      const (id: 22, size: 2, type: _uint16), // total_descent
      const (id: 25, size: 1, type: _enum), // sport
    ];
    _writeDefinition(body, localId: 3, globalId: 19, fields: lapFields);
    _writeDataHeader(body, 3);
    _writeUint(body, _fitSeconds(endedAt), 4);
    _writeUint(body, 9, 1); // lap
    _writeUint(body, 1, 1); // stop
    _writeUint(body, _fitSeconds(startedAt), 4);
    if (startPosition != null) {
      _writeInt(body, _semicircles(startPosition.lat), 4);
      _writeInt(body, _semicircles(startPosition.lng), 4);
      _writeInt(body, _semicircles(endPosition!.lat), 4);
      _writeInt(body, _semicircles(endPosition.lng), 4);
    }
    _writeUint(body, _milliValue(ride.stats.elapsed), 4);
    _writeUint(body, _milliValue(ride.stats.moving), 4);
    _writeUint(body, _centiValue(ride.stats.distanceMeters), 4);
    _writeUint(body, _speedValue(ride.stats.avgSpeedMps), 2);
    _writeUint(body, _speedValue(ride.stats.maxSpeedMps), 2);
    if (avgHeartRate != null) _writeUint(body, _byteValue(avgHeartRate), 1);
    if (maxHeartRate != null) _writeUint(body, _byteValue(maxHeartRate), 1);
    if (avgCadence != null) _writeUint(body, _byteValue(avgCadence), 1);
    if (maxCadence != null) _writeUint(body, _byteValue(maxCadence), 1);
    if (avgPower != null) _writeUint(body, _powerValue(avgPower), 2);
    if (maxPower != null) _writeUint(body, _powerValue(maxPower), 2);
    _writeUint(body, _gainValue(ride.stats.elevationGainMeters), 2);
    _writeUint(body, _gainValue(ride.stats.elevationLossMeters), 2);
    _writeUint(body, 2, 1); // cycling

    // ---- session ----
    final sessionFields = <({int id, int size, int type})>[
      const (id: 253, size: 4, type: _uint32), // timestamp
      const (id: 0, size: 1, type: _enum), // event
      const (id: 1, size: 1, type: _enum), // event_type
      const (id: 2, size: 4, type: _uint32), // start_time
      if (startPosition != null) ...[
        const (id: 3, size: 4, type: _sint32), // start_position_lat
        const (id: 4, size: 4, type: _sint32), // start_position_long
      ],
      const (id: 5, size: 1, type: _enum), // sport
      const (id: 7, size: 4, type: _uint32), // total_elapsed_time
      const (id: 8, size: 4, type: _uint32), // total_timer_time
      const (id: 9, size: 4, type: _uint32), // total_distance
      const (id: 14, size: 2, type: _uint16), // avg_speed
      const (id: 15, size: 2, type: _uint16), // max_speed
      if (avgHeartRate != null) const (id: 16, size: 1, type: _uint8),
      if (maxHeartRate != null) const (id: 17, size: 1, type: _uint8),
      if (avgCadence != null) const (id: 18, size: 1, type: _uint8),
      if (maxCadence != null) const (id: 19, size: 1, type: _uint8),
      if (avgPower != null) const (id: 20, size: 2, type: _uint16),
      if (maxPower != null) const (id: 21, size: 2, type: _uint16),
      const (id: 22, size: 2, type: _uint16), // total_ascent
      const (id: 23, size: 2, type: _uint16), // total_descent
      const (id: 25, size: 2, type: _uint16), // first_lap_index
      const (id: 26, size: 2, type: _uint16), // num_laps
    ];
    _writeDefinition(body, localId: 4, globalId: 18, fields: sessionFields);
    _writeDataHeader(body, 4);
    _writeUint(body, _fitSeconds(endedAt), 4);
    _writeUint(body, 9, 1); // lap (as written by Garmin devices)
    _writeUint(body, 1, 1); // stop
    _writeUint(body, _fitSeconds(startedAt), 4);
    if (startPosition != null) {
      _writeInt(body, _semicircles(startPosition.lat), 4);
      _writeInt(body, _semicircles(startPosition.lng), 4);
    }
    _writeUint(body, 2, 1); // cycling
    _writeUint(body, _milliValue(ride.stats.elapsed), 4);
    _writeUint(body, _milliValue(ride.stats.moving), 4);
    _writeUint(body, _centiValue(ride.stats.distanceMeters), 4);
    _writeUint(body, _speedValue(ride.stats.avgSpeedMps), 2);
    _writeUint(body, _speedValue(ride.stats.maxSpeedMps), 2);
    if (avgHeartRate != null) _writeUint(body, _byteValue(avgHeartRate), 1);
    if (maxHeartRate != null) _writeUint(body, _byteValue(maxHeartRate), 1);
    if (avgCadence != null) _writeUint(body, _byteValue(avgCadence), 1);
    if (maxCadence != null) _writeUint(body, _byteValue(maxCadence), 1);
    if (avgPower != null) _writeUint(body, _powerValue(avgPower), 2);
    if (maxPower != null) _writeUint(body, _powerValue(maxPower), 2);
    _writeUint(body, _gainValue(ride.stats.elevationGainMeters), 2);
    _writeUint(body, _gainValue(ride.stats.elevationLossMeters), 2);
    _writeUint(body, 0, 2); // first_lap_index
    _writeUint(body, 1, 2); // num_laps

    // ---- activity ----
    _writeDefinition(
      body,
      localId: 5,
      globalId: 34,
      fields: const [
        (id: 253, size: 4, type: _uint32), // timestamp
        (id: 0, size: 4, type: _uint32), // total_timer_time
        (id: 1, size: 2, type: _uint16), // num_sessions
        (id: 5, size: 4, type: _uint32), // local_timestamp
      ],
    );
    _writeDataHeader(body, 5);
    _writeUint(body, _fitSeconds(endedAt), 4);
    _writeUint(body, _milliValue(ride.stats.moving), 4);
    _writeUint(body, 1, 2);
    // Local time is the UTC instant plus the device's offset at the time of
    // the ride — not `DateTime.now()`'s offset, which is the same thing here
    // but would not be if the phone's time zone changed since.
    _writeUint(
      body,
      _fitSeconds(endedAt) + endedAt.toLocal().timeZoneOffset.inSeconds,
      4,
    );

    return _wrap(body.takeBytes());
  }

  // ---- File framing ----

  /// Prepends the 14-byte header and appends the file CRC.
  static Uint8List _wrap(Uint8List data) {
    final header = BytesBuilder(copy: false)
      ..addByte(14)
      ..addByte(_protocolVersion)
      ..addByte(_profileVersion & 0xFF)
      ..addByte((_profileVersion >> 8) & 0xFF)
      ..addByte(data.length & 0xFF)
      ..addByte((data.length >> 8) & 0xFF)
      ..addByte((data.length >> 16) & 0xFF)
      ..addByte((data.length >> 24) & 0xFF)
      ..add(const [0x2E, 0x46, 0x49, 0x54]); // ".FIT"

    final headerBytes = header.takeBytes();
    final headerCrc = _crc16(headerBytes);

    final file = BytesBuilder(copy: false)
      ..add(headerBytes)
      ..addByte(headerCrc & 0xFF)
      ..addByte((headerCrc >> 8) & 0xFF)
      ..add(data);

    // The file CRC covers everything before it, header CRC included.
    final fileBytes = file.takeBytes();
    final fileCrc = _crc16(fileBytes);

    return (BytesBuilder(copy: false)
          ..add(fileBytes)
          ..addByte(fileCrc & 0xFF)
          ..addByte((fileCrc >> 8) & 0xFF))
        .takeBytes();
  }

  /// CRC-16 with the nibble table from the FIT SDK.
  ///
  /// The same algorithm as CRC-16/ARC, but written in the SDK's form so it can
  /// be checked against the reference implementation byte for byte.
  static int _crc16(List<int> bytes) {
    var crc = 0;
    for (final byte in bytes) {
      var tmp = _crcTable[crc & 0xF];
      crc = (crc >> 4) & 0x0FFF;
      crc = crc ^ tmp ^ _crcTable[byte & 0xF];
      tmp = _crcTable[crc & 0xF];
      crc = (crc >> 4) & 0x0FFF;
      crc = crc ^ tmp ^ _crcTable[(byte >> 4) & 0xF];
    }
    return crc & 0xFFFF;
  }

  static const List<int> _crcTable = [
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
  ];

  // ---- Message writing ----

  static void _writeDefinition(
    BytesBuilder builder, {
    required int localId,
    required int globalId,
    required List<({int id, int size, int type})> fields,
  }) {
    builder.addByte(0x40 | localId); // definition, normal header
    builder.addByte(0); // reserved
    builder.addByte(0); // little endian
    _writeUint(builder, globalId, 2);
    builder.addByte(fields.length);
    for (final field in fields) {
      builder.addByte(field.id);
      builder.addByte(field.size);
      builder.addByte(field.type);
    }
  }

  static void _writeDataHeader(BytesBuilder builder, int localId) =>
      builder.addByte(localId);

  /// Writes [value] as [size] little-endian bytes. Negative values are two's
  /// complement, which is what `sint32` positions need.
  static void _writeUint(BytesBuilder builder, int value, int size) {
    for (var i = 0; i < size; i++) {
      builder.addByte((value >> (8 * i)) & 0xFF);
    }
  }

  static void _writeInt(BytesBuilder builder, int value, int size) =>
      _writeUint(builder, value, size);

  // ---- Field values ----

  static bool _finite(double? value) => value != null && value.isFinite;

  static int _fitSeconds(DateTime time) {
    final seconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
    final fit = seconds - fitEpochOffsetSeconds;
    return fit < 0 ? 0 : (fit > 0xFFFFFFFE ? 0xFFFFFFFE : fit);
  }

  /// Degrees to FIT semicircles.
  static int _semicircles(double degrees) {
    final value = (degrees * _semicirclesPerDegree).round();
    if (value > 2147483647) return 2147483647;
    if (value < -2147483648) return -2147483648;
    return value;
  }

  /// Meters to the scaled `altitude` field, invalid when absent.
  static int _altitudeValue(double? meters) {
    if (!_finite(meters)) return _invalid16;
    final value = ((meters! + 500) * 5).round();
    if (value < 0) return 0;
    return value > 65534 ? 65534 : value;
  }

  /// Meters per second to the scaled `speed` field.
  static int _speedValue(double? mps) {
    if (!_finite(mps) || mps! < 0) return _invalid16;
    final value = (mps * 1000).round();
    return value > 65534 ? 65534 : value;
  }

  /// Meters to the scaled `distance` field.
  static int _centiValue(double meters) {
    if (!meters.isFinite || meters < 0) return 0;
    final value = (meters * 100).round();
    return value > 0xFFFFFFFE ? 0xFFFFFFFE : value;
  }

  /// A duration to the scaled millisecond fields.
  static int _milliValue(Duration duration) {
    final value = duration.inMilliseconds;
    if (value < 0) return 0;
    return value > 0xFFFFFFFE ? 0xFFFFFFFE : value;
  }

  /// A one-byte sensor reading, invalid when absent. Zero is left as zero:
  /// the FIT profile reserves 255 for invalid, and a heart rate of zero is a
  /// reading the device actually produced.
  static int _byteValue(int? value) {
    if (value == null) return _invalid8;
    if (value < 0) return 0;
    return value > 254 ? 254 : value;
  }

  static int _powerValue(int? watts) {
    if (watts == null) return _invalid16;
    if (watts < 0) return 0;
    return watts > 65534 ? 65534 : watts;
  }

  static int _gainValue(double meters) {
    if (!meters.isFinite || meters <= 0) return 0;
    final value = meters.round();
    return value > 65534 ? 65534 : value;
  }

  static int? _average(
    List<TrackPoint> points,
    int? Function(TrackPoint) read,
  ) {
    var sum = 0;
    var count = 0;
    for (final point in points) {
      final value = read(point);
      if (value != null) {
        sum += value;
        count++;
      }
    }
    return count == 0 ? null : (sum / count).round();
  }

  static int? _max(List<TrackPoint> points, int? Function(TrackPoint) read) {
    int? best;
    for (final point in points) {
      final value = read(point);
      if (value == null) continue;
      if (best == null || value > best) best = value;
    }
    return best;
  }
}
