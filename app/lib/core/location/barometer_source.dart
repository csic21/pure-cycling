import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// One barometer reading.
class BarometerSample {
  const BarometerSample({
    required this.pressureHpa,
    required this.timestamp,
    this.relativeAltitudeMeters,
  });

  /// Atmospheric pressure in hectopascals, as the platform reported it.
  final double pressureHpa;

  final DateTime timestamp;

  /// Metres above the first sample of the stream this came from.
  ///
  /// Relative, not absolute, and that is deliberate: a barometer measures
  /// pressure, and turning that into a height above sea level needs the local
  /// sea-level pressure — which changes with the weather and is not something
  /// a phone knows. Deltas within a ride are excellent; the absolute number is
  /// anchored to the first GPS altitude instead (see `RideEngine`).
  final double? relativeAltitudeMeters;
}

/// Pressure → altitude, with the reference pinned to a known sample.
///
/// Pure and static so the arithmetic can be checked against numbers rather
/// than against a device. `test/barometer_test.dart` covers it.
abstract final class BarometricAltitude {
  /// The exponent in the barometric formula used by every phone barometer.
  static const double _exponent = 0.1903;

  /// The scale height of the standard atmosphere, in metres.
  static const double _scale = 44330.0;

  /// Metres between two pressures.
  ///
  /// The formula is `44330 · (1 − (p/p₀)^0.1903)` with `p₀` the pressure at
  /// the reference level. Feeding it the *first sample* rather than the local
  /// sea-level pressure is what makes this usable at all, and it costs almost
  /// nothing: the error is a fixed ratio of the delta, on the order of 0.4% —
  /// on a 100 m climb, 40 cm. What it cannot do is tell the rider how high
  /// above the sea they are.
  static double deltaMeters({
    required double pressureHpa,
    required double referenceHpa,
  }) {
    if (pressureHpa <= 0 || referenceHpa <= 0) return 0;
    final ratio = pressureHpa / referenceHpa;
    return _scale * (1 - math.pow(ratio, _exponent).toDouble());
  }
}

/// A source of barometric readings.
///
/// An interface because the ride engine must be testable without a barometer:
/// a fake feeds synthetic pressures, and everything above this line — the
/// smoothing, the climb total, the quality label — runs identically.
abstract interface class BarometerSource {
  /// Whether this device has one.
  ///
  /// Probed by listening rather than by a second platform channel: a device
  /// without a barometer reports an error immediately, and one with a
  /// barometer usually answers within a frame. The probe gives up after a
  /// short timeout and says no.
  Future<bool> isAvailable();

  /// Readings, relative to the first sample of *this* subscription.
  ///
  /// Errors are part of the contract: a device without a barometer, or one
  /// where the motion permission was refused, reports one. Callers treat any
  /// error as "no barometer" and carry on — recording never depends on it.
  Stream<BarometerSample> samples();
}

/// A source that never reports anything.
///
/// Used where there is no platform implementation behind the channel — macOS,
/// the desktop test host — so nothing ever asks a channel that does not
/// exist. A `MissingPluginException` on every ride start is not a crash, but
/// it is noise in the diagnostic log and a red herring for whoever reads it.
class NullBarometerSource implements BarometerSource {
  const NullBarometerSource();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Stream<BarometerSample> samples() => const Stream<BarometerSample>.empty();
}

/// The phone's own barometer, over an event channel.
///
/// Both platforms report **raw pressure in hPa**; the conversion lives in Dart
/// so it is one implementation instead of two, and so it is testable. iOS's
/// `CMAltimeter` also offers a relative altitude directly — deliberately
/// unused, for that reason.
class PlatformBarometerSource implements BarometerSource {
  const PlatformBarometerSource();

  static const String channelName = 'app.purecycling/barometer';

  /// How long [isAvailable] waits for a first reading.
  static const Duration _probeTimeout = Duration(seconds: 2);

  @override
  Future<bool> isAvailable() async {
    final probe = StreamController<bool>();
    StreamSubscription<BarometerSample>? sub;
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
  Stream<BarometerSample> samples() async* {
    // Local, so two subscriptions never share a baseline: the first sample of
    // each stream is its zero.
    double? reference;
    await for (final event in _channel.receiveBroadcastStream()) {
      final pressure = (event as num).toDouble();
      reference ??= pressure;
      yield BarometerSample(
        pressureHpa: pressure,
        // The platform's own clock would add a channel round trip's worth of
        // skew for no benefit: what matters is how long ago the reading
        // arrived, which is what staleness is measured against.
        timestamp: DateTime.now().toUtc(),
        relativeAltitudeMeters: BarometricAltitude.deltaMeters(
          pressureHpa: pressure,
          referenceHpa: reference,
        ),
      );
    }
  }

  static const EventChannel _channel = EventChannel(channelName);
}
