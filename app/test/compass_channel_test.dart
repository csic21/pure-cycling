import 'package:cycling_app/core/location/compass_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native display frame reaches all listeners without a second rotation',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel(PlatformCompassSource.channelName);
      var listens = 0;
      var cancels = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'listen') listens++;
        if (call.method == 'cancel') cancels++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const source = PlatformCompassSource();
      final received = <CompassSample>[];
      final sub = source.samples().listen(received.add);
      await Future<void>.delayed(Duration.zero);
      final probe = source.isAvailable();
      await Future<void>.delayed(Duration.zero);

      Future<void> emit(int frame, double heading) async {
        await messenger.handlePlatformMessage(
          PlatformCompassSource.channelName,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'heading': heading,
            'accuracy': 5.0,
            'orientationQuarterTurns': frame,
          }),
          null,
        );
        await Future<void>.delayed(Duration.zero);
      }

      await emit(0, 90);
      expect(
        await probe.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw StateError('probe cancellation stalled'),
        ),
        isTrue,
      );
      expect(
        listens,
        1,
        reason: 'availability probe shares the active ride stream',
      );
      expect(
        cancels,
        0,
        reason: 'finishing the probe must not cancel recording',
      );
      for (final frame in [1, 2, 3]) {
        await emit(frame, 90);
        expect(received.last.orientationQuarterTurns, frame);
        expect(
          received.last.headingDegrees,
          90,
          reason: 'native orientation is already compensated',
        );
      }
      await sub.cancel().timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('ride cancellation stalled'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cancels, 1);
    },
  );
}
