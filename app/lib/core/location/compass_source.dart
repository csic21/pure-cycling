import 'dart:async';

import 'package:flutter/services.dart';

/// One compass reading.
class CompassSample {
  const CompassSample({
    required this.headingDegrees,
    required this.timestamp,
    this.accuracyDegrees,
  });

  /// Degrees clockwise from north — the direction the **phone** is pointing.
  ///
  /// Not the direction the rider is travelling. On a bike those are the same
  /// thing only while the phone is mounted the way the bike is facing, which
  /// is the case this app is built for and the reason the heading is only ever
  /// allowed to *stand in* for GPS course, never to override it.
  final double headingDegrees;

  final DateTime timestamp;

  /// How far the reading could be out, in degrees, when the platform says.
  ///
  /// Android reports a quality band rather than a figure and iOS reports a
  /// real number; the platform layer maps both onto this one field so the
  /// decision to trust a reading exists once, in Dart. Null means the platform
  /// declined to say, which is treated as "trust it" — the alternative is
  /// ignoring a working compass because it would not quantify itself.
  final double? accuracyDegrees;
}

/// A source of compass readings.
///
/// An interface for the same reason `BarometerSource` is one: the ride engine
/// must be testable without a magnetometer, and everything above this line —
/// the smoothing, the anchoring to GPS course, the dashboard field — runs
/// identically against a fake.
abstract interface class CompassSource {
  /// Whether this device has one.
  ///
  /// Probed by listening rather than by a second platform channel: a device
  /// without a compass reports an error immediately, and one with a compass
  /// usually answers within a frame. The probe gives up after a short timeout
  /// and says no.
  Future<bool> isAvailable();

  /// Readings, in degrees clockwise from north.
  ///
  /// Errors are part of the contract: a device with no magnetometer reports
  /// one. Callers treat any error as "no compass" and carry on — recording
  /// never depends on it.
  Stream<CompassSample> samples();
}

/// A source that never reports anything.
///
/// Used where there is no platform implementation behind the channel — macOS,
/// the desktop test host — so nothing ever asks a channel that does not exist.
class NullCompassSource implements CompassSource {
  const NullCompassSource();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Stream<CompassSample> samples() => const Stream<CompassSample>.empty();
}

/// The phone's own compass, over an event channel.
///
/// The platform reports a heading in degrees and an optional accuracy, and
/// nothing else. Deciding *when* to believe it is deliberately not the
/// platform's job: that is the interesting part, it differs per platform, and
/// it lives in `GpsFilter` where it can be tested against numbers.
///
/// ## Why the platform does the arithmetic here
///
/// The barometer's conversion lives in Dart because it is pure arithmetic on a
/// single number. A heading is not: turning a rotation vector into an azimuth
/// means knowing which device axis the screen treats as "forward" and how the
/// display is rotated, which is per-platform sensor plumbing rather than
/// mathematics. So the platform hands over degrees, and the *fusion* — which is
/// the part with a right answer that can be tested — happens here.
class PlatformCompassSource implements CompassSource {
  const PlatformCompassSource();

  static const String channelName = 'app.purecycling/compass';

  /// How long [isAvailable] waits for a first reading.
  static const Duration _probeTimeout = Duration(seconds: 2);

  @override
  Future<bool> isAvailable() async {
    final probe = StreamController<bool>();
    StreamSubscription<CompassSample>? sub;
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
  Stream<CompassSample> samples() async* {
    await for (final event in _channel.receiveBroadcastStream()) {
      final map = (event as Map).cast<Object?, Object?>();
      final heading = map['heading'];
      if (heading is! num) continue;

      final degrees = heading.toDouble();
      // A heading outside the circle is a platform bug, not a direction.
      // Dropping it here keeps every consumer free of the range check.
      if (!degrees.isFinite) continue;

      final accuracy = map['accuracy'];
      yield CompassSample(
        headingDegrees: degrees % 360,
        // The platform's own clock would add a channel round trip's worth of
        // skew for no benefit: what matters is how long ago the reading
        // arrived, which is what staleness is measured against.
        timestamp: DateTime.now().toUtc(),
        accuracyDegrees:
            (accuracy is num && accuracy.isFinite) ? accuracy.toDouble() : null,
      );
    }
  }

  static const EventChannel _channel = EventChannel(channelName);
}
