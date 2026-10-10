import 'dart:async';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/location_service.dart';
import 'package:cycling_app/core/location/location_fix.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const gnss = MethodChannel('app.purecycling/gnss');
  const oneShot = MethodChannel('flutter.baseflow.com/geolocator_android');
  late GeolocatorPlatform oldPlatform;

  setUp(() {
    oldPlatform = GeolocatorPlatform.instance;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    GeolocatorPlatform.instance = oldPlatform;
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(gnss, null);
    messenger.setMockMethodCallHandler(oneShot, null);
  });

  test('one-shot timeout cancels the actual Android plugin request ID', () async {
    GeolocatorAndroid.registerWith();
    final pending = <String, Completer<Object?>>{};
    final cancelled = <String>[];
    messenger.setMockMethodCallHandler(oneShot, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final id = args['requestId'] as String;
      if (call.method == 'getCurrentPosition') {
        final result = Completer<Object?>();
        pending[id] = result;
        return result.future;
      }
      if (call.method == 'cancelGetCurrentPosition') {
        cancelled.add(id);
        pending.remove(id)!.completeError(PlatformException(code: 'cancelled'));
      }
      return null;
    });
    for (var i = 0; i < 3; i++) {
      expect(await LocationService().currentFix(timeout: const Duration(milliseconds: 5)), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(pending, isEmpty, reason: 'each timed-out native request must release its listener');
    }
    expect(cancelled.toSet(), hasLength(3));
  });

  for (final outcome in ['replace', 'background', 'dispose']) {
    test('GNSS real EventChannel waits for delayed fallback cancellation: $outcome', () async {
      final platform = _DelayedFallback();
      GeolocatorPlatform.instance = platform;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(gnss, (call) async {
        calls.add(call.method);
        return null;
      });
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final location = _GrantedLocationService();
      final recorder = RideRecorder(db: db, repository: RideRepository(db),
        locationService: location, watchdogInterval: const Duration(hours: 1));
      await recorder.startRide(const AppSettings(gpsAccuracy: GpsAccuracyMode.high));
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['listen']);
      recorder.applySettings(const AppSettings(gpsAccuracy: GpsAccuracyMode.balanced));
      await Future<void>.delayed(Duration.zero);
      expect(platform.cancelling, isTrue);
      expect(calls, ['listen'], reason: 'replacement cannot open while old cancellation is pending');
      // Repeated settings changes must converge without opening an intermediate receiver.
      recorder.applySettings(const AppSettings(gpsAccuracy: GpsAccuracyMode.high));
      recorder.applySettings(const AppSettings(gpsAccuracy: GpsAccuracyMode.balanced));
      Future<void>? disposing;
      if (outcome == 'background') recorder.setForeground(false);
      if (outcome == 'dispose') disposing = recorder.dispose();
      platform.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (outcome == 'dispose') {
        await disposing;
        expect(calls, ['listen', 'cancel']);
      } else {
        if (outcome == 'background') {
          expect(calls, ['listen', 'cancel']);
          recorder.setForeground(true);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(calls, ['listen', 'cancel', 'listen']);
        await messenger.handlePlatformMessage('app.purecycling/gnss',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'latitude': 31.0, 'longitude': 121.0,
            'timestamp': DateTime.utc(2026).millisecondsSinceEpoch,
            'accuracy': 3.0,
          }), null);
        await Future<void>.delayed(Duration.zero);
        expect(location.fixesReceived, 1, reason: 'replacement native receiver must still receive a real channel event');
        await recorder.dispose();
      }
      await db.close();
    });
  }
}

class _DelayedFallback extends GeolocatorPlatform {
  final release = Completer<void>();
  bool cancelling = false;
  int opens = 0;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    final first = opens++ == 0;
    return StreamController<Position>(onCancel: () async {
      if (first) { cancelling = true; await release.future; }
    }).stream;
  }
}

class _GrantedLocationService extends LocationService {
  int fixesReceived = 0;
  @override
  Future<LocationPermissionStatus> ensurePermission({bool requestBackground = true}) async =>
      LocationPermissionStatus.granted;
  @override
  Stream<LocationFix> fixes({GpsAccuracyMode mode = GpsAccuracyMode.high,
      bool background = true, Duration? interval}) =>
    super.fixes(mode: mode, background: background, interval: interval).map((fix) {
      fixesReceived++;
      return fix;
    });
}
