import 'dart:async';

import 'package:flutter/services.dart';

/// One accelerometer reading.
class MotionSample {
  const MotionSample({required this.magnitudeG, required this.timestamp});

  /// The magnitude of the acceleration vector, in g.
  ///
  /// A scalar rather than three axes, and that is the contract rather than an
  /// economy: the only thing downstream needs is the vibration energy, and the
  /// magnitude is the one form of it that does not depend on how the phone is
  /// oriented. See `MotionDetector`.
  final double magnitudeG;

  final DateTime timestamp;
}

/// A source of accelerometer readings.
///
/// An interface for the same reason the barometer and compass are: the ride
/// engine must be testable without a phone that shakes, and the decision the
/// readings feed — which is where all the judgement lives — runs identically
/// against a fake.
abstract interface class MotionSource {
  /// Whether this device has an accelerometer it will report from.
  ///
  /// Probed by listening, as the other two sensors are: a device that will not
  /// report says so immediately.
  Future<bool> isAvailable();

  /// Readings, in g.
  ///
  /// Errors are part of the contract: a device with no accelerometer, or one
  /// where the platform refused, reports one. Callers treat any error as "no
  /// motion sensor" and carry on — recording never depends on it, and every
  /// consumer falls back to GPS speed, which is what it used before this
  /// existed.
  Stream<MotionSample> samples();
}

/// A source that never reports anything.
///
/// Used where there is no platform implementation behind the channel — macOS,
/// the desktop test host — so nothing ever asks a channel that does not exist.
class NullMotionSource implements MotionSource {
  const NullMotionSource();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Stream<MotionSample> samples() => const Stream<MotionSample>.empty();
}

/// The phone's own accelerometer, over an event channel.
///
/// The platform reports one number per sample — the magnitude, in g — and
/// nothing else. Deciding what counts as moving is deliberately not its job:
/// that is arithmetic with a right answer, it exists once in
/// `core/location/motion_detector.dart`, and it is tested against synthetic
/// signatures rather than against a bicycle.
///
/// No permission is needed on either platform. `NSMotionUsageDescription` is
/// already in `Info.plist` (it is required by `CMAltimeter`, which the
/// barometer uses), and the raw accelerometer does not require it at all.
class PlatformMotionSource implements MotionSource {
  const PlatformMotionSource();

  static const String channelName = 'app.purecycling/motion';

  /// How long [isAvailable] waits for a first reading.
  static const Duration _probeTimeout = Duration(seconds: 2);

  @override
  Future<bool> isAvailable() async {
    final probe = StreamController<bool>();
    StreamSubscription<MotionSample>? sub;
    sub = samples().listen(
      (_) {
        if (!probe.isClosed) probe.add(true);
      },
      onError: (_) {
        if (!probe.isClosed) probe.add(false);
      },
    );

    try {
      return await probe.stream.first.timeout(
        _probeTimeout,
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      await sub.cancel();
      await probe.close();
    }
  }

  @override
  Stream<MotionSample> samples() async* {
    await for (final event in _channel.receiveBroadcastStream()) {
      if (event is! num) continue;
      final magnitude = event.toDouble();
      // A negative or non-finite magnitude is a platform bug, not a reading,
      // and the detector would have to defend against it in every consumer.
      if (!magnitude.isFinite || magnitude < 0) continue;

      yield MotionSample(
        magnitudeG: magnitude,
        // The platform's own clock would add a channel round trip's worth of
        // skew for no benefit: what matters is the order and spacing of
        // samples, which is what the window is measured in.
        timestamp: DateTime.now().toUtc(),
      );
    }
  }

  static const EventChannel _channel = EventChannel(channelName);
}
