import 'package:cycling_app/core/system/ride_fullscreen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.purecycling/ride_fullscreen');

  test('Android hides bars for the ride and restores them on exit', () async {
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await RideFullscreen.enter();
    await RideFullscreen.exit();

    expect(calls, [
      isA<MethodCall>()
          .having((call) => call.method, 'method', 'setImmersive')
          .having((call) => call.arguments, 'enabled', true),
      isA<MethodCall>()
          .having((call) => call.method, 'method', 'setImmersive')
          .having((call) => call.arguments, 'enabled', false),
    ]);
  });
}
