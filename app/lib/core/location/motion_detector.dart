import 'dart:collection';

/// Turns a stream of accelerometer magnitudes into "is the bike moving".
///
/// ## Why a magnitude, and why vibration
///
/// The only question this answers is whether the bike is rolling, and the
/// signal that distinguishes rolling from parked is **vibration**: road buzz
/// arrives at the phone whatever pocket or mount it is in, while a parked bike
/// gives a phone nothing to feel. So the measurement is the RMS of the
/// residual after gravity is removed, not a speed and not a displacement.
///
/// Using the magnitude of the acceleration vector rather than its three axes
/// is deliberate: gravity contributes a constant 1 g to the magnitude at any
/// angle, so removing it is a matter of subtracting a slow average, and the
/// result does not depend on how the phone is oriented. A phone lying flat, on
/// its side in a jersey pocket, or clamped in a stem mount gives the same
/// answer for the same road.
///
/// ## Why two thresholds
///
/// The same argument as [AutoPauseController]'s two speed thresholds, and it
/// matters more here: a flag that chattered at the decision boundary would
/// keep the sampling policy from ever relaxing and the auto-pause from ever
/// firing. So it takes a higher reading to *start* moving than to *keep*
/// moving, and the RMS is taken over a window rather than per sample so a
/// single pothole cannot flip the state.
///
/// ## Why a fraction of samples rather than an RMS
///
/// The obvious statistic is the RMS of the residual, and it is the wrong one
/// here: squaring makes it dominated by the largest sample, so a single
/// pothole — or somebody nudging a parked bike — reads as "moving" for the
/// whole window. What is wanted is "is this a *sustained* vibration", which is
/// a question about how much of the window is shaking, not how hard the worst
/// instant was.
///
/// So the measure is the fraction of samples whose residual exceeds
/// [perSampleG]. A pothole is one sample out of ninety in a window and cannot
/// move that fraction much; rolling asphalt is most of them.
///
/// ## Where the numbers come from
///
/// From synthetic signatures (see `test/motion_test.dart`), not from a
/// measured ride — which makes them the numbers in this feature most likely to
/// need adjusting, and the first to revisit if auto-pause misbehaves on a real
/// bike. For noise of amplitude ±a, the fraction of samples past
/// [perSampleG] is `(a − perSampleG)/a`, which puts the two thresholds at
/// amplitudes of about 0.032 g and 0.043 g:
///
/// | what the phone is doing | amplitude | verdict |
/// |---|---|---|
/// | on a desk, or in a bag on a bike nobody is on | ≤ 0.01 g | still |
/// | a rider standing at a light, shifting weight | ~0.02 g | still |
/// | rough road, a phone in a jersey pocket | ≥ 0.05 g | moving |
/// | smooth asphalt, in a mount | ≥ 0.05 g | moving |
///
/// The band between them is deliberately wider than the spread of either
/// signature, because a verdict that flickered at the boundary would make both
/// consumers useless.
class MotionDetector {
  MotionDetector({
    this.window = const Duration(milliseconds: 1500),
    this.perSampleG = 0.03,
    this.movingFraction = 0.30,
    this.stillFraction = 0.05,
    this.gravityAlpha = 0.02,
  }) : assert(
          stillFraction < movingFraction,
          'the gap between them is the hysteresis',
        );

  /// How much history the fraction is taken over.
  ///
  /// Long enough to ride out a pothole, short enough that setting off is
  /// noticed inside a second or two.
  final Duration window;

  /// How large a residual one sample must have to count as vibration, in g.
  final double perSampleG;

  /// The fraction of the window that must be vibrating to count as moving.
  final double movingFraction;

  /// The fraction below which a moving bike counts as stopped again.
  final double stillFraction;

  /// Weight of the newest sample in the gravity average.
  ///
  /// Slow on purpose: this is what separates the 1 g that is always there from
  /// the vibration that is not, and a fast average would eat the vibration
  /// itself.
  final double gravityAlpha;

  final ListQueue<({DateTime at, double residual})> _recent = ListQueue();
  double? _gravity;
  bool _moving = false;

  /// Whether the bike is moving, by this detector's reading.
  bool get moving => _moving;

  /// Whether enough samples have arrived for [moving] to mean anything.
  ///
  /// A verdict needs a window to be measured over. Without this, the first
  /// sample after the stream opens — which has nothing to compare against —
  /// would read as "the bike is standing still", and both consumers would
  /// believe it: the sampling policy would drop to the frugal profile and
  /// auto-pause would shorten its delay, on the strength of one number.
  bool get hasReading => _gravity != null && _recent.length >= _minSamples;

  /// How many samples are needed before a verdict is worth anything.
  ///
  /// A third of a second at the rate the platform reports, which is long
  /// enough that the RMS is a measurement rather than a coincidence.
  static const int _minSamples = 5;

  /// Folds in one sample, in g. Returns the current verdict.
  ///
  /// A sample that is not finite is ignored rather than poisoning the average —
  /// the same rule as the ride engine's running averages, and for the same
  /// reason: one NaN would otherwise decide the answer for the rest of the ride.
  bool add(double magnitudeG, DateTime at) {
    if (!magnitudeG.isFinite || magnitudeG <= 0) return _moving;

    final gravity = _gravity;
    if (gravity == null) {
      // The first sample *is* the gravity estimate: there is nothing to
      // compare it against yet, and treating it as vibration would announce
      // that a parked bike had set off.
      _gravity = magnitudeG;
      return _moving;
    }

    final residual = magnitudeG - gravity;
    _gravity = gravity + gravityAlpha * residual;

    _recent.addLast((at: at, residual: residual));
    _trim(at);

    // No verdict until there is a window to take one over — see [hasReading].
    // Changing the answer on the strength of two samples is how the state
    // stream ends up publishing a verdict that was never really formed.
    if (_recent.length < _minSamples) return _moving;

    final shaking = _fractionShaking();
    if (_moving) {
      if (shaking <= stillFraction) _moving = false;
    } else {
      if (shaking >= movingFraction) _moving = true;
    }
    return _moving;
  }

  /// Forgets everything. Called at the start of a ride: the gravity estimate
  /// describes where the phone was, and the next ride may begin with it
  /// somewhere else entirely.
  void reset() {
    _recent.clear();
    _gravity = null;
    _moving = false;
  }

  void _trim(DateTime now) {
    final cutoff = now.subtract(window);
    while (_recent.isNotEmpty && _recent.first.at.isBefore(cutoff)) {
      _recent.removeFirst();
    }
  }

  double _fractionShaking() {
    if (_recent.isEmpty) return 0;
    var shaking = 0;
    for (final sample in _recent) {
      if (sample.residual.abs() > perSampleG) shaking++;
    }
    return shaking / _recent.length;
  }
}
