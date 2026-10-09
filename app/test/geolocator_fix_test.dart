import 'package:cycling_app/core/location/gps_filter.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  final timestamp = DateTime.utc(2026, 10, 9).millisecondsSinceEpoch;
  Position position(Map<String, dynamic> fields) => Position.fromMap({
    'latitude': 0.0,
    'longitude': 0.0,
    'timestamp': timestamp,
    ...fields,
  });

  test(
    'absent platform values stay absent instead of becoming zero measurements',
    () {
      final raw = position({});
      expect(raw.heading, 0);
      expect(raw.hasHeading, isFalse);
      final fix = fixFromPosition(raw);
      expect(fix.heading, isNull);
      expect(fix.headingAccuracy, isNull);
      expect(fix.speed, isNull);
      expect(fix.speedAccuracy, isNull);
      expect(fix.altitude, isNull);
      expect(fix.altitudeAccuracy, isNull);
      expect(fix.hasSpeed, isFalse);
      expect(fix.hasAccuracy, isFalse);
    },
  );

  test('real due-north course and measured standstill are preserved', () {
    final north = fixFromPosition(
      position({
        'heading': 0.0,
        'heading_accuracy': 5.0,
        'speed': 5.0,
        'speed_accuracy': 0.5,
        'accuracy': 4.0,
      }),
    );
    expect(north.heading, 0);
    expect(north.headingAccuracy, 5);
    expect(GpsFilter().process(north).bearing, 0);
    final stopped = fixFromPosition(position({'speed': 0.0}));
    expect(stopped.hasSpeed, isTrue);
    expect(stopped.speed, 0);
  });

  test(
    'missing course at speed derives east from movement instead of inventing north',
    () {
      final filter = GpsFilter();
      final first = fixFromPosition(position({'speed': 5.0, 'accuracy': 4.0}));
      expect(filter.process(first).bearing, isNull);
      final second = fixFromPosition(
        position({
          'timestamp': timestamp + 2000,
          'longitude': 10 / 111195,
          'speed': 5.0,
          'accuracy': 4.0,
        }),
      );
      expect(filter.process(second).bearing, closeTo(90, 0.5));
    },
  );

  test('explicit false presence survives a serialized Position round trip', () {
    final raw = position({
      'heading': 0.0,
      'has_heading': false,
      'speed': 0.0,
      'has_speed': false,
    });
    final fix = fixFromPosition(Position.fromMap(raw.toJson()));
    expect(fix.heading, isNull);
    expect(fix.speed, isNull);
  });
}
