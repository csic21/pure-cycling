import '../../features/settings/domain/app_settings.dart';

/// What a location subscription is asking the platform for.
///
/// Accuracy and interval are separate because stopping changes only one of
/// them. Dropping accuracy to the power-balanced tier lets Android's fused
/// provider sleep the GNSS chip, and the next fix then arrives late enough
/// for the signal icon to turn red at a traffic light.
class SamplingRequest {
  const SamplingRequest({required this.accuracy, required this.interval});

  final GpsAccuracyMode accuracy;
  final Duration interval;

  @override
  bool operator ==(Object other) =>
      other is SamplingRequest &&
      other.accuracy == accuracy &&
      other.interval == interval;

  @override
  int get hashCode => Object.hash(accuracy, interval);
}

/// Decides how often to ask for a fix while a ride is in progress (spec §32).
///
/// The rule is one sentence: **a stationary rider does not need a fix every
/// second.** Parked at a café, a 1 Hz stream spends battery to learn that the
/// position has not changed. So the interval stretches to five seconds after
/// half a minute of not moving, and comes straight back when they set off.
/// The accuracy request stays whatever the rider chose.
///
/// Three properties are deliberate:
///
/// * **It never samples better than the rider asked for.** A rider who chose
///   省电 is not silently upgraded to high accuracy because they are moving.
/// * **The downgrade is slow and the upgrade is fast.** Missing the start of a
///   climb for thirty seconds is a real loss; noticing it late is not. So
///   stretching the interval needs 30 s of stillness, and coming back needs
///   5 s of movement.
/// * **It does not thrash.** Every change costs a platform re-subscription, and
///   a rider in city traffic stops and starts constantly. After any change the
///   policy holds its answer for a minute, so a red light produces at most one
///   round trip.
///
/// The clock is passed in rather than read, so the whole thing is testable
/// without timers — see `test/sampling_policy_test.dart`.
class SamplingPolicy {
  SamplingPolicy({required GpsAccuracyMode chosen}) : _chosen = chosen;

  /// Below this the rider is considered stopped. Slightly under the auto-pause
  /// threshold, so the policy reacts before the engine pauses.
  static const double stationaryBelowKph = 2.0;

  /// Above this they are definitely moving. Above the auto-resume threshold,
  /// for the same reason.
  static const double movingAboveKph = 3.0;

  /// How long stillness must last before the profile is relaxed.
  static const Duration stationaryFor = Duration(seconds: 30);

  /// How long stillness must last when the accelerometer agrees it is still.
  ///
  /// Much shorter, because the two answers are independent and the sensor's is
  /// the one that does not get confused by a bad fix. Thirty seconds is a
  /// deliberate wait for evidence that GPS alone cannot give; with the
  /// evidence in hand there is nothing left to wait for.
  static const Duration stationaryForWithMotion = Duration(seconds: 10);

  /// How long movement must last before it is restored.
  static const Duration movingFor = Duration(seconds: 5);

  /// The quiet period after any change.
  static const Duration minimumDwell = Duration(minutes: 1);

  /// How far apart fixes are asked for while the bike is stopped.
  ///
  /// Five seconds is the 省电 interval. The accuracy of that tier is not used:
  /// stopping keeps the rider's accuracy and only borrows the slower clock.
  static const Duration relaxedInterval = Duration(seconds: 5);

  /// The interval each rider-chosen tier asks for when the bike is moving.
  static Duration intervalFor(GpsAccuracyMode mode) => switch (mode) {
    GpsAccuracyMode.high => const Duration(seconds: 1),
    GpsAccuracyMode.balanced => const Duration(seconds: 2),
    GpsAccuracyMode.batterySaver => const Duration(seconds: 5),
  };

  GpsAccuracyMode _chosen;
  bool _relaxed = false;

  DateTime? _stationarySince;
  DateTime? _movingSince;
  DateTime? _lastChangeAt;

  /// Accuracy in force. Stopping does not change it.
  GpsAccuracyMode get effective => _chosen;

  /// Accuracy plus interval, which is what a resubscription has to compare.
  SamplingRequest get request {
    final chosenInterval = intervalFor(_chosen);
    final interval = _relaxed && chosenInterval < relaxedInterval
        ? relaxedInterval
        : chosenInterval;
    return SamplingRequest(accuracy: _chosen, interval: interval);
  }

  /// Whether the slower interval is in force.
  bool get isRelaxed => _relaxed;

  /// What the rider asked for.
  GpsAccuracyMode get chosen => _chosen;

  /// Applies a settings change: a rider who switches profile mid-ride gets the
  /// new one immediately, and the policy goes back to its default answer.
  void setChosen(GpsAccuracyMode mode) {
    if (mode == _chosen) return;
    _chosen = mode;
    _relaxed = false;
    _stationarySince = null;
    _movingSince = null;
    _lastChangeAt = null;
  }

  /// Feeds the current smoothed speed. Returns true when the profile changed.
  ///
  /// [motionDetected] is the accelerometer's verdict, or null when there is
  /// none — and null leaves the speed rule exactly as it was, which is what
  /// every device without a motion sensor sees.
  ///
  /// When it is present it decides the band the speed deliberately refuses to
  /// decide, and it decides stillness outright: speed at two kilometres an
  /// hour is the receiver's least trustworthy number, and "the phone is not
  /// being shaken at all" is a much better answer to "has the rider stopped".
  ///
  /// It still cannot upgrade past what the rider chose, still needs
  /// [minimumDwell] between changes, and still upgrades fast and downgrades
  /// slowly — the sensor changes *what* counts as evidence, never the shape of
  /// the rule.
  bool update({
    required double speedMps,
    required DateTime at,
    bool? motionDetected,
  }) {
    final kph = speedMps * 3.6;

    if (motionDetected == false) {
      _stationarySince ??= at;
      _movingSince = null;
    } else if (motionDetected == true) {
      _movingSince ??= at;
      _stationarySince = null;
    } else if (kph < stationaryBelowKph) {
      _stationarySince ??= at;
      _movingSince = null;
    } else if (kph > movingAboveKph) {
      _movingSince ??= at;
      _stationarySince = null;
    }
    // Between the two thresholds nothing is decided by speed: that band is a
    // slow crawl, and treating it as either state would flip the answer at a
    // red light. The motion sensor is the one input that can settle it.

    final dwellPassed = _lastChangeAt == null ||
        at.difference(_lastChangeAt!) >= minimumDwell;

    if (!_relaxed) {
      final stillSince = _stationarySince;
      final stillFor =
          motionDetected == false ? stationaryForWithMotion : stationaryFor;
      if (dwellPassed &&
          stillSince != null &&
          at.difference(stillSince) >= stillFor) {
        _relaxed = true;
        _lastChangeAt = at;
        return true;
      }
      return false;
    }

    final movingSince = _movingSince;
    if (movingSince != null && at.difference(movingSince) >= movingFor) {
      // The upgrade ignores the dwell: it is what stops a stationary profile
      // from missing the first kilometre of a climb.
      _relaxed = false;
      _lastChangeAt = at;
      return true;
    }
    return false;
  }
}
