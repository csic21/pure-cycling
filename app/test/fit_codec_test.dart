import 'dart:typed_data';

import 'package:cycling_app/core/fit/fit_codec.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:fit_tool/fit_tool.dart';
import 'package:flutter_test/flutter_test.dart';

/// The FIT encoder, decoded with an independent parser.
///
/// `fit_tool` is a dev dependency from a different codebase (Stages Cycling's
/// implementation of the same profile). Decoding our output with it is the
/// point of these tests: a test that read back the bytes with the encoder's
/// own helpers would pass just as happily if a field number were wrong, and a
/// wrong field number is a file that parses cleanly and shows the wrong data —
/// or is rejected by Garmin Connect with no explanation.
///
/// The profile numbers themselves were taken from `fit_tool`'s generated
/// profile (21.60) and cross-checked against the FIT SDK's own `Activity.fit`,
/// which is also what the message order follows.
void main() {
  final startedAt = DateTime.utc(2026, 9, 23, 6, 30);
  final createdAt = DateTime.utc(2026, 9, 23, 7, 30);

  Ride buildRide({
    double distanceMeters = 20000,
    Duration elapsed = const Duration(minutes: 60),
    Duration moving = const Duration(minutes: 55),
    int? avgHeartRate = 142,
    int? avgCadence = 84,
    int? avgPower = 180,
  }) =>
      Ride(
        id: 'ride-1',
        name: '晨骑',
        startedAt: startedAt,
        endedAt: startedAt.add(elapsed),
        stats: RideStats(
          distanceMeters: distanceMeters,
          elapsed: elapsed,
          moving: moving,
          avgSpeedMps: distanceMeters / moving.inSeconds,
          maxSpeedMps: 11.2,
          elevationGainMeters: 320,
          elevationLossMeters: 310,
          avgHeartRate: avgHeartRate,
          avgCadence: avgCadence,
          avgPower: avgPower,
        ),
      );

  /// A ride heading due north at 5 m/s, one point per second.
  List<TrackPoint> buildTrace({bool sensors = true, int count = 100}) => [
        for (var i = 0; i < count; i++)
          TrackPoint(
            rideId: 'ride-1',
            sequence: i,
            timestamp: startedAt.add(Duration(seconds: i)),
            lat: 39.9042 + i * 5 / 111132.0,
            lng: 116.4074,
            altitude: 50 + i * 0.5,
            speed: 5,
            bearing: 0,
            heartRate: sensors ? 140 + (i % 5) : null,
            cadence: sensors ? 80 + (i % 7) : null,
            power: sensors ? 150 + (i % 11) : null,
          ),
      ];

  Future<List<Message>> decode(Uint8List bytes) async {
    final messages = <Message>[];
    await Stream<List<int>>.value(bytes)
        .transform(FitDecoder())
        .forEach(messages.add);
    return messages;
  }

  Uint8List encode({
    Ride? ride,
    List<TrackPoint>? trace,
  }) =>
      FitCodec.encode(
        ride ?? buildRide(),
        trace ?? buildTrace(),
        createdAt: createdAt,
      );

  group('file framing', () {
    test('header and CRCs are what the format requires', () {
      final bytes = encode();

      expect(bytes.length, greaterThan(14 + 2));
      expect(bytes[0], 14, reason: 'header size');
      expect(bytes.sublist(8, 12), [0x2E, 0x46, 0x49, 0x54], reason: '.FIT');

      // The declared data size is everything between the header and the file
      // CRC.
      final dataSize = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) |
          (bytes[7] << 24);
      expect(dataSize, bytes.length - 14 - 2);

      // Header CRC covers the first 12 bytes, file CRC everything before it.
      // Recomputed with fit_tool's implementation, not ours.
      final headerCrc = bytes[12] | (bytes[13] << 8);
      expect(headerCrc, crc16(bytes.sublist(0, 12)));

      final fileCrc = bytes[bytes.length - 2] | (bytes[bytes.length - 1] << 8);
      expect(fileCrc, crc16(bytes.sublist(0, bytes.length - 2)));
    });

    test('a corrupted byte is rejected by the decoder CRC check', () async {
      final bytes = encode();
      // Flip a bit in the middle of the record stream.
      bytes[bytes.length ~/ 2] ^= 0x01;

      await expectLater(
        decode(bytes),
        throwsA(anything),
        reason: 'the decoder verifies the file CRC',
      );
    });
  });

  group('activity structure', () {
    test('is an activity file with one lap, one session and one activity',
        () async {
      final messages = await decode(encode());

      final fileId = messages.whereType<FileIdMessage>().single;
      expect(fileId.type, FileType.activity);
      // 255 is the "development" manufacturer id: this app is not a
      // registered Garmin developer, and claiming a vendor id it does not own
      // would be a lie that services could act on.
      expect(fileId.manufacturer, 255);
      expect(fileId.timeCreated, createdAt.millisecondsSinceEpoch);

      final events = messages.whereType<EventMessage>().toList();
      expect(events, hasLength(2));
      expect(events.first.event, Event.timer);
      expect(events.first.eventType, EventType.start);
      expect(events.last.event, Event.timer);
      expect(events.last.eventType, EventType.stopAll);

      expect(messages.whereType<LapMessage>(), hasLength(1));
      expect(messages.whereType<SessionMessage>(), hasLength(1));

      final activity = messages.whereType<ActivityMessage>().single;
      expect(activity.numSessions, 1);
    });

    test('carries one record per track point, in order', () async {
      final trace = buildTrace();
      final records =
          (await decode(encode(trace: trace))).whereType<RecordMessage>().toList();

      expect(records, hasLength(trace.length));

      // Timestamps come back as Unix milliseconds, because that is how the
      // decoder presents FIT time.
      expect(records.first.timestamp, trace.first.timestamp.millisecondsSinceEpoch);
      expect(records.last.timestamp, trace.last.timestamp.millisecondsSinceEpoch);

      // Positions round-trip through semicircles to within a centimetre or so.
      expect(records.first.positionLat, closeTo(trace.first.lat, 1e-6));
      expect(records.last.positionLong, closeTo(trace.last.lng, 1e-6));
      expect(records.last.positionLat, closeTo(trace.last.lat, 1e-6));
    });

    test('record values survive the scaled integer fields', () async {
      final trace = buildTrace();
      final records =
          (await decode(encode(trace: trace))).whereType<RecordMessage>().toList();

      final second = records[1];
      expect(second.altitude, closeTo(trace[1].altitude!, 0.21));
      expect(second.speed, closeTo(trace[1].speed!, 0.001));
      expect(second.heartRate, trace[1].heartRate);
      expect(second.cadence, trace[1].cadence);
      expect(second.power, trace[1].power);

      // Cumulative distance: monotonic, and 99 steps of 5 m by the end.
      expect(records[0].distance, 0);
      for (var i = 1; i < records.length; i++) {
        expect(records[i].distance, greaterThanOrEqualTo(records[i - 1].distance!));
      }
      expect(records.last.distance, closeTo(5 * (trace.length - 1), 1));
    });

    test('summary messages carry the ride the rider saw', () async {
      final ride = buildRide();
      final messages = await decode(encode(ride: ride));

      final session = messages.whereType<SessionMessage>().single;
      expect(session.sport, Sport.cycling);
      expect(session.startTime, startedAt.millisecondsSinceEpoch);
      expect(session.totalElapsedTime, closeTo(ride.stats.elapsed.inSeconds, 0.01));
      expect(session.totalTimerTime, closeTo(ride.stats.moving.inSeconds, 0.01));
      expect(session.totalDistance, closeTo(ride.stats.distanceMeters, 0.01));
      expect(session.avgSpeed, closeTo(ride.stats.avgSpeedMps, 0.001));
      expect(session.maxSpeed, closeTo(ride.stats.maxSpeedMps, 0.001));
      expect(session.avgHeartRate, ride.stats.avgHeartRate);
      expect(session.maxHeartRate, 144);
      expect(session.avgCadence, ride.stats.avgCadence);
      expect(session.avgPower, ride.stats.avgPower);
      expect(session.totalAscent, 320);
      expect(session.totalDescent, 310);
      expect(session.numLaps, 1);
      expect(session.firstLapIndex, 0);
      expect(session.startPositionLat, closeTo(39.9042, 1e-6));

      final lap = messages.whereType<LapMessage>().single;
      expect(lap.sport, Sport.cycling);
      expect(lap.totalDistance, closeTo(ride.stats.distanceMeters, 0.01));
      expect(lap.startPositionLong, closeTo(116.4074, 1e-6));
      expect(lap.endPositionLat, greaterThan(lap.startPositionLat!));
    });

    test('an empty trace still produces a valid file', () async {
      final messages = await decode(
        encode(ride: buildRide(distanceMeters: 0), trace: const []),
      );

      expect(messages.whereType<RecordMessage>(), isEmpty);
      expect(messages.whereType<SessionMessage>().single.totalDistance, 0);
      expect(messages.whereType<LapMessage>(), hasLength(1));
    });
  });

  group('optional fields', () {
    test('sensor fields are omitted entirely when the ride has no sensors',
        () async {
      final messages = await decode(
        encode(
          ride: buildRide(
            avgHeartRate: null,
            avgCadence: null,
            avgPower: null,
          ),
          trace: buildTrace(sensors: false),
        ),
      );

      final record = messages.whereType<RecordMessage>().first;
      expect(record.heartRate, isNull);
      expect(record.cadence, isNull);
      expect(record.power, isNull);

      // Averages fall back to the trace, which is also empty, so the summary
      // omits them rather than writing a fabricated zero.
      final session = messages.whereType<SessionMessage>().single;
      expect(session.avgHeartRate, isNull);
      expect(session.maxHeartRate, isNull);
      expect(session.avgPower, isNull);
    });

    test('averages fall back to the trace when the stats do not have them',
        () async {
      // A ride restored from GPX has a trace but no engine-computed averages.
      final ride = Ride(
        id: 'imported',
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 100)),
        stats: const RideStats(distanceMeters: 500),
      );
      final messages = await decode(encode(ride: ride, trace: buildTrace()));

      final session = messages.whereType<SessionMessage>().single;
      expect(session.avgHeartRate, 142); // 140..144
      expect(session.maxHeartRate, 144);
      expect(session.avgCadence, 83); // 80..86, weighted by residue counts
      expect(session.avgPower, 155); // 150..160
    });

    test('a missing altitude is the invalid marker, not sea level', () async {
      final trace = [
        TrackPoint(
          sequence: 0,
          timestamp: startedAt,
          lat: 39.9042,
          lng: 116.4074,
          altitude: 120,
        ),
        TrackPoint(
          sequence: 1,
          timestamp: startedAt.add(const Duration(seconds: 1)),
          lat: 39.9042 + 5 / 111132.0,
          lng: 116.4074,
          // No altitude on this one, but the field is declared because the
          // first point has one.
        ),
      ];
      final records =
          (await decode(encode(trace: trace))).whereType<RecordMessage>().toList();

      expect(records[0].altitude, closeTo(120, 0.21));
      expect(records[1].altitude, isNull,
          reason: '0xFFFF means "no reading"; a zero would claim -500 m');
    });
  });
}
