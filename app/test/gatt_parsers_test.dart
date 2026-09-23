import 'dart:typed_data';

import 'package:cycling_app/features/sensors/data/gatt_parsers.dart';
import 'package:cycling_app/features/sensors/domain/sensor.dart';
import 'package:flutter_test/flutter_test.dart';

/// The GATT parsers are the one part of the sensor stack that cannot be
/// checked by looking at the app — a wrong shift produces a plausible number
/// rather than a crash. These tests use byte sequences built to the spec
/// rather than captured from a device, so the flags, widths and wraparounds
/// are each exercised explicitly.
void main() {
  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  group('UUID handling', () {
    test('expands a short 16-bit form to the full 128-bit form', () {
      expect(
        GattParsers.normalizeUuid('180D'),
        '0000180D-0000-1000-8000-00805F9B34FB',
      );
      expect(
        GattParsers.normalizeUuid('0000180d-0000-1000-8000-00805f9b34fb'),
        '0000180D-0000-1000-8000-00805F9B34FB',
      );
    });

    test('matches across the two forms, which platforms report differently',
        () {
      // Android reports the short form for standard services; iOS reports the
      // full one. Both refer to the same service.
      expect(GattParsers.matches('180D', GattParsers.heartRateService), isTrue);
      expect(
        GattParsers.matches(
          '0000180D-0000-1000-8000-00805F9B34FB',
          GattParsers.heartRateService,
        ),
        isTrue,
      );
      expect(GattParsers.matches('1816', GattParsers.heartRateService), isFalse);
    });

    test('maps services to sensor types', () {
      expect(GattParsers.typeForService('180D'), SensorType.heartRate);
      expect(GattParsers.typeForService('1816'), SensorType.cadence);
      expect(GattParsers.typeForService('1818'), SensorType.power);
      expect(GattParsers.typeForService('180F'), isNull);
    });
  });

  group('heart rate (0x2A37)', () {
    test('reads an 8-bit value, which is what every chest strap sends', () {
      // Flags 0x00: 8-bit rate, no contact, no energy, no RR.
      expect(GattParsers.parseHeartRate(bytes([0x00, 72])), 72);
    });

    test('reads a 16-bit value when the flags say so', () {
      // Flags 0x01: UINT16 rate. 0x0100 is 256 — only reachable from the wide
      // form, and a naive single-byte read would see the low byte, 0, and
      // reject the packet entirely.
      expect(GattParsers.parseHeartRate(bytes([0x01, 0x00, 0x01])), 256);

      // A normal value in the wide form must not be misread either.
      expect(GattParsers.parseHeartRate(bytes([0x01, 0x46, 0x00])), 70);
    });

    test('skips the optional energy-expended field', () {
      // Flags 0x08: 8-bit rate plus a 2-byte energy field.
      expect(
        GattParsers.parseHeartRate(bytes([0x08, 88, 0x10, 0x27])),
        88,
      );
    });

    test('tolerates a truncated packet instead of throwing', () {
      expect(GattParsers.parseHeartRate(bytes([])), isNull);
      expect(GattParsers.parseHeartRate(bytes([0x01, 0x46])), isNull);
    });

    test('rejects a physiologically impossible rate', () {
      // 0 bpm is a disconnected strap, not a stopped heart.
      expect(GattParsers.parseHeartRate(bytes([0x00, 0])), isNull);
      expect(GattParsers.parseHeartRate(bytes([0x01, 0xFF, 0x7F])), isNull);
    });

    test('decodes the body sensor location', () {
      expect(GattParsers.parseBodySensorLocation(bytes([1])), '胸部');
      expect(GattParsers.parseBodySensorLocation(bytes([2])), '手腕');
      expect(GattParsers.parseBodySensorLocation(bytes([])), isNull);
    });
  });

  group('cycling speed and cadence (0x2A5B)', () {
    test('parses a crank-only packet, which is what a cadence sensor sends',
        () {
      // Flags 0x02: crank revolution data only.
      final measurement = GattParsers.parseCsc(
        bytes([0x02, 0x64, 0x00, 0x00, 0x04]),
      );

      expect(measurement, isNotNull);
      expect(measurement!.hasCrank, isTrue);
      expect(measurement.hasWheel, isFalse);
      expect(measurement.crankRevolutions, 100);
      expect(measurement.crankEventTimeUnits, 1024);
    });

    test('parses a combined packet with both fields, in the right order', () {
      // Flags 0x03: wheel first (4-byte revs + 2-byte time), then crank.
      final measurement = GattParsers.parseCsc(
        bytes([
          0x03,
          0x10, 0x27, 0x00, 0x00, // wheel revolutions: 10000
          0x00, 0x08, // wheel event time: 2048
          0xC8, 0x00, // crank revolutions: 200
          0x00, 0x04, // crank event time: 1024
        ]),
      );

      expect(measurement!.wheelRevolutions, 10000);
      expect(measurement.wheelEventTimeUnits, 2048);
      expect(measurement.crankRevolutions, 200);
      expect(measurement.crankEventTimeUnits, 1024);
    });

    test('returns null for a packet carrying neither field', () {
      expect(GattParsers.parseCsc(bytes([0x00])), isNull);
    });
  });

  group('CSC accumulator', () {
    test('converts revolution counts into cadence', () {
      final acc = CscAccumulator();

      // First packet only establishes the reference.
      expect(acc.addCrank(100, 0), isNull);

      // One crank revolution in one second is 60 rpm.
      expect(acc.addCrank(101, 1024), 60);
      expect(acc.addCrank(102, 2048), 60);
    });

    test('handles both 16-bit counters wrapping', () {
      final acc = CscAccumulator();

      // One revolution before the revolution counter wraps, one second before
      // the event timer wraps. Both are 16-bit; a naive subtraction gives
      // -65535 revolutions and a nonsensical rpm.
      acc.addCrank(65535, 65500);

      // 65500 + 1024 = 66524, which wraps to 988.
      final rpm = acc.addCrank(0, 988);

      expect(rpm, isNotNull);
      expect(
        rpm,
        60,
        reason: 'one revolution in one second, across both wraps',
      );
    });

    test('reports zero rather than dividing when the sensor repeats itself',
        () {
      final acc = CscAccumulator();
      acc.addCrank(100, 0);

      // Same revolution count, same timestamp: the sensor re-sent a packet.
      expect(acc.addCrank(100, 0), isNull);
      // Same count, later timestamp: the rider is coasting.
      expect(acc.addCrank(100, 1024), 0);
    });

    test('converts wheel revolutions into speed', () {
      final acc = CscAccumulator(wheelCircumferenceMeters: 2.0);
      acc.addWheel(0, 0);

      // Two revolutions in one second at 2 m circumference is 4 m/s.
      final kph = acc.addWheel(2, 1024);
      expect(kph, closeTo(14.4, 0.2));
    });

    test('rejects an implausible wheel speed', () {
      final acc = CscAccumulator();
      acc.addWheel(0, 0);

      // 200 revolutions in one second on a bicycle is not a bicycle.
      expect(acc.addWheel(200, 1024), isNull);
    });

    test('reset clears the reference so a reconnect starts clean', () {
      final acc = CscAccumulator();
      acc.addCrank(100, 0);
      acc.reset();

      expect(acc.addCrank(500, 2048), isNull);
    });
  });

  group('cycling power (0x2A63)', () {
    test('reads instantaneous power from a minimal packet', () {
      // Flags 0x0000: only power present. 250 W little-endian.
      final measurement = GattParsers.parsePower(bytes([0x00, 0x00, 0xFA, 0x00]));

      expect(measurement, isNotNull);
      expect(measurement!.watts, 250);
      expect(measurement.crankRevolutions, isNull);
    });

    test('reads a negative power value', () {
      // Bit 15 of the 16-bit power field is the sign.
      final measurement =
          GattParsers.parsePower(bytes([0x00, 0x00, 0x9C, 0xFF]));
      expect(measurement!.watts, -100);
    });

    test('walks past the optional fields to reach crank data', () {
      // Flags 0x0021: pedal balance (1 byte) + crank revolution data
      // (4 bytes) + a 1-bit... the balance byte is what most parsers get
      // wrong, because the offset it introduces shifts everything after it.
      final measurement = GattParsers.parsePower(bytes([
        0x21, 0x00, // flags: 0x0020 crank data | 0x0001 pedal balance
        0xC8, 0x00, // power: 200 W
        0x40, // pedal balance
        0x64, 0x00, // crank revolutions: 100
        0x00, 0x04, // crank event time: 1024
      ]));

      expect(measurement!.watts, 200);
      expect(measurement.crankRevolutions, 100);
      expect(measurement.crankEventTimeUnits, 1024);
    });

    test('walks past accumulated torque, which is two bytes', () {
      // Flags 0x0200: accumulated torque present, no crank data.
      final measurement = GattParsers.parsePower(bytes([
        0x00, 0x02,
        0x96, 0x00, // 150 W
        0x34, 0x12, // accumulated torque
      ]));

      expect(measurement!.watts, 150);
      expect(measurement.crankRevolutions, isNull);
    });

    test('handles a truncated packet without throwing', () {
      expect(GattParsers.parsePower(bytes([0x00, 0x00, 0xFA])), isNull);
      // Flags promise crank data that is not there: report the power, which
      // is the part that did arrive.
      final partial = GattParsers.parsePower(
        bytes([0x20, 0x00, 0xFA, 0x00]),
      );
      expect(partial!.watts, 250);
    });
  });

  group('battery (0x2A19)', () {
    test('reads a percentage', () {
      expect(GattParsers.parseBatteryLevel(bytes([87])), 87);
    });

    test('rejects an out-of-range value', () {
      expect(GattParsers.parseBatteryLevel(bytes([200])), isNull);
      expect(GattParsers.parseBatteryLevel(bytes([])), isNull);
    });
  });
}
