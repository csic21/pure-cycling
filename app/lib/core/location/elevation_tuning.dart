/// How much to trust an altitude reading, and what to do about it.
///
/// ## The problem this exists for
///
/// Altitude reaches the app from one of two places, and they are not remotely
/// equivalent:
///
/// * **A barometer.** Resolution around 0.1 m, noise essentially white. A
///   phone with one reports a flat road as flat, and a climb as a climb.
/// * **GPS alone.** Vertical error of 5–25 m, and — the part that matters —
///   it *drifts slowly*. Satellite geometry changes over tens of minutes, and
///   the error wanders with it. On a flat 9 km ride this is worth 30 m of
///   phantom climbing on a good day and over 100 m under tree cover.
///
/// No filter can separate that drift from a real climb: they occupy the same
/// frequency range. The only honest defences are to demand more evidence
/// before counting, and to say so in the UI when the figure is approximate.
///
/// ## What "more evidence" means here
///
/// Two knobs, both scaled by the reported vertical accuracy:
///
/// * **Deadband and smoothing** decide how much of the raw trace becomes the
///   smoothed profile. A noisy source is smoothed harder.
/// * **The gain threshold** decides how far the smoothed profile must move
///   before it counts as terrain rather than as the receiver wandering.
///
/// The threshold is the one that costs something: raising it suppresses
/// phantom climbing *and* discards real climbs smaller than the threshold. On
/// a GPS-only phone a 20 m roller genuinely cannot be distinguished from
/// noise, so it is not counted, and the total is marked as an estimate.
///
/// ## Why "unknown" is the pessimistic case
///
/// A device that reports no vertical accuracy is assumed to be GPS-only, not
/// assumed to be good. The opposite default would let an unlabelled poor
/// source produce a confident, wrong climb figure — and a rider has no way to
/// tell the difference between 300 m of climbing and 300 m of noise.
library;

/// How reliable a ride's elevation figures are.
enum ElevationQuality {
  /// A barometer is contributing, or the fix is unusually precise.
  precise('精确'),

  /// GPS altitude, with enough satellites for a usable figure.
  fair('良好'),

  /// GPS altitude that is noisy, or whose accuracy the device did not report.
  /// The climb total is an estimate.
  approximate('估算');

  const ElevationQuality(this.label);

  final String label;

  /// Whether the climb figure should be presented as approximate.
  bool get isApproximate => this == ElevationQuality.approximate;
}

/// The elevation parameters in force for a given level of vertical accuracy.
class ElevationTuning {
  const ElevationTuning({
    required this.deadbandMeters,
    required this.smoothingAlpha,
    required this.gainThresholdMeters,
    required this.quality,
  });

  /// What a phone barometer is worth, in metres.
  ///
  /// Resolution is around 0.1 m and the noise is white; what remains is the
  /// weather, which moves the reading by a few metres over hours. Within one
  /// ride, a metre is honest.
  ///
  /// Feeding this number anywhere a `verticalAccuracy` is expected is the
  /// entire integration: the thresholds below already know what to do with a
  /// source this good.
  static const double barometerAccuracyMeters = 1.0;

  /// How far the smoothed altitude must move before the raw value is followed.
  ///
  /// Keeps the displayed altitude — and the bar on a profile chart — from
  /// twitching while the rider is stationary.
  final double deadbandMeters;

  /// EMA weight for the newest sample.
  final double smoothingAlpha;

  /// How far the smoothed profile must move to count as terrain.
  final double gainThresholdMeters;

  final ElevationQuality quality;

  /// The parameters for a fix reporting [verticalAccuracyMeters].
  ///
  /// Null, zero and negative all mean "the platform did not tell us", which is
  /// treated as the pessimistic GPS-only case. Android returns 0 for
  /// `getVerticalAccuracyMeters()` when it has no estimate, and iOS returns a
  /// negative `verticalAccuracy` when the altitude is invalid.
  ///
  /// The thresholds below were tuned against synthetic traces matching each
  /// source's published noise characteristics — see
  /// `test/elevation_noise_probe_test.dart`, which measures the phantom climb
  /// each profile produces on a flat road.
  factory ElevationTuning.forVerticalAccuracy(double? verticalAccuracyMeters) {
    final accuracy = verticalAccuracyMeters;

    if (accuracy == null || !accuracy.isFinite || accuracy <= 0) {
      // Unknown. Assume the worst case rather than the best.
      return const ElevationTuning(
        deadbandMeters: 2.5,
        smoothingAlpha: 0.06,
        gainThresholdMeters: 10,
        quality: ElevationQuality.approximate,
      );
    }

    if (accuracy <= 3) {
      // A barometer is contributing, or the fix is exceptional.
      return const ElevationTuning(
        deadbandMeters: 0.3,
        smoothingAlpha: 0.15,
        gainThresholdMeters: 2,
        quality: ElevationQuality.precise,
      );
    }

    // The threshold tracks the reported accuracy one-for-one, because that is
    // what the measurement says. A threshold sweep against synthetic traces
    // for a ±15 m receiver — see `test/elevation_noise_probe_test.dart` —
    // found the flat-road phantom climbing falling from 27 m to 15 m between
    // thresholds 12 and 15, with no loss of real terrain at all; and then
    // rolling terrain collapsing from 182 m to 77 m between 15 and 18.
    //
    // So the useful window is narrow and centred on the accuracy figure
    // itself. Below it, noise gets counted; above it, real hills stop being
    // counted; at it, both are about as good as a GPS-only source allows.
    //
    // The 30 m ceiling is a sanity bound rather than a tuning choice: past
    // that the receiver is guessing, and no threshold makes its altitude
    // useful.
    final threshold = (accuracy * 1.0).clamp(6.0, 30.0);

    return ElevationTuning(
      deadbandMeters: accuracy <= 8 ? 1.0 : 3.0,
      smoothingAlpha: accuracy <= 8 ? 0.10 : 0.07,
      gainThresholdMeters: threshold,
      quality:
          accuracy <= 12 ? ElevationQuality.fair : ElevationQuality.approximate,
    );
  }

  /// The tuning assumed before any fix has reported an accuracy.
  static const ElevationTuning unknown = ElevationTuning(
    deadbandMeters: 2.5,
    smoothingAlpha: 0.06,
    gainThresholdMeters: 10,
    quality: ElevationQuality.approximate,
  );

  @override
  String toString() =>
      'ElevationTuning(${quality.label}, deadband=$deadbandMeters, '
      'alpha=$smoothingAlpha, threshold=$gainThresholdMeters)';
}
