import 'package:cycling_app/core/location/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a GPS_PROVIDER event becomes a fix with mean-sea-level fields', () {
    final fix = fixFromGnssEvent({
      'latitude': 39.9,
      'longitude': 116.4,
      'timestamp': 1750000000000,
      'altitude': 48.5,
      'altitude_accuracy': 3.0,
      'accuracy': 4.0,
      'speed': 8.2,
      'speed_accuracy': 0.4,
      'heading': 90.0,
      'heading_accuracy': 5.0,
      'is_mocked': false,
    });

    expect(fix, isNotNull);
    expect(fix!.latitude, 39.9);
    expect(fix.longitude, 116.4);
    expect(fix.timestamp.isUtc, isTrue);
    expect(fix.timestamp.millisecondsSinceEpoch, 1750000000000);
    expect(fix.altitude, 48.5);
    expect(fix.speed, 8.2);
    expect(fix.speedAccuracy, 0.4);
    expect(fix.accuracy, 4);
    expect(fix.isMocked, isFalse);
  });

  test('a payload that is not a fix is skipped', () {
    expect(fixFromGnssEvent(null), isNull);
    expect(fixFromGnssEvent({'latitude': 1.0}), isNull);
  });
}
