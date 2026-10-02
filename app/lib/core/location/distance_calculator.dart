import '../utils/geo.dart';

/// Accumulates ride distance from validated fixes.
///
/// Distance is *not* `sum(haversine(p[n], p[n-1]))` (spec §13). Raw summation
/// of consecutive GPS samples inflates a ride badly: at a red light, a few
/// meters of jitter at 1 Hz adds hundreds of meters of phantom distance per
/// minute of standing still.
///
/// ## Why the gate is a radius, not a per-sample threshold
///
/// The obvious fix — "ignore a sample closer than N meters to the previous
/// one" — does not work, and it is worth saying why, because it is the
/// intuitive design.
///
/// A stationary receiver does not emit a tight cluster. It *oscillates*: the
/// position estimate swings back and forth across several metres as the
/// solution drifts. Consecutive samples 10 m apart are entirely normal for a
/// parked bicycle, so any per-sample threshold small enough to preserve real
/// riding lets that oscillation straight through — and because it alternates
/// in sign, it adds up.
///
/// The gate here is therefore a **radius around a held anchor**. A sample
/// inside the radius is not counted and, crucially, does not move the anchor;
/// oscillation around a fixed point never escapes and contributes nothing,
/// no matter how large the swing or how long it continues.
///
/// The property that makes this safe is that it *defers* rather than discards.
/// When a sample finally clears the radius, the full distance from the anchor
/// is banked — so a rider who genuinely moved 15 m gets their 15 m, just not
/// until the third second of it. The only thing lost is the last few metres of
/// a ride that stops mid-radius, which is below the resolution of any
/// consumer GPS receiver.
///
/// A second gate rejects slow drift: a fix that clears the radius but implies
/// a speed below [minSpeedForDistanceMps] holds the anchor rather than
/// banking. A receiver that wanders 40 m over a minute does not get to
/// manufacture 40 m of riding.
///
/// A third rejects the impossible: a sample implying more than [maxSpeedMps]
/// re-seats the anchor at the new position, so the ride continues from where
/// the rider actually is instead of dragging a stale reference behind it.
class DistanceCalculator {
  DistanceCalculator({
    this.noiseFloorMeters = 12.0,
    this.minSpeedForDistanceMps = 0.7,
    this.maxSpeedMps = 30.0,
    this.maxRadiusMeters = 25.0,
  });

  /// The smallest radius the anchor will use, in meters.
  ///
  /// Twelve meters: comfortably above the several-metre swing of a stationary
  /// receiver, and far below any distance a rider would miss — at 20 km/h it
  /// is two seconds of riding, banked in full on the third.
  final double noiseFloorMeters;

  /// ~2.5 km/h. Below this, movement across the radius is indistinguishable
  /// from the receiver slowly drifting.
  final double minSpeedForDistanceMps;

  /// ~108 km/h. A bicycle does not exceed this; a GPS glitch does.
  final double maxSpeedMps;

  /// The largest radius the anchor will use, in meters.
  ///
  /// Caps the accuracy-scaled radius. Without a cap, a fix reported at ±40 m
  /// would demand an 80 m radius and swallow most of a city block before
  /// counting anything.
  final double maxRadiusMeters;

  double _totalMeters = 0;
  GeoPoint? _anchor;
  DateTime? _anchorTime;

  double get totalMeters => _totalMeters;

  GeoPoint? get anchor => _anchor;
  DateTime? get anchorTime => _anchorTime;

  /// The radius currently in force for a fix of the given accuracy.
  ///
  /// Scaled by accuracy because a bad fix is not merely less precise — it is
  /// *less certain*, and the honest response is to demand more evidence before
  /// believing it. Twice the reported accuracy is the same factor
  /// [GpsFilter] uses when it decides how much to trust a sample.
  double radiusFor(double? accuracyMeters) {
    if (accuracyMeters == null || accuracyMeters <= 0) return noiseFloorMeters;
    return (accuracyMeters * 2.0)
        .clamp(noiseFloorMeters, maxRadiusMeters)
        .toDouble();
  }

  /// Feeds a validated fix. Returns the distance banked by this sample, which
  /// is usually zero.
  ///
  /// [accuracyMeters] widens the radius for an imprecise fix. Passing null
  /// uses the [noiseFloorMeters] default.
  ///
  /// [headingDegrees] and [previousAccuracyMeters] feed the urban multipath
  /// soft gate: when course and displacement disagree sharply *and* accuracy
  /// has just spiked, the sample is held rather than banked. The anchor does
  /// not move — same philosophy as the noise radius — so a later honest fix
  /// still credits the full travel from here. UI consumers keep seeing the
  /// raw point; only mileage waits.
  double add(
    GeoPoint point,
    DateTime timestamp, {
    double? accuracyMeters,
    double? headingDegrees,
    double? previousAccuracyMeters,
  }) {
    final anchor = _anchor;
    final anchorTime = _anchorTime;

    if (anchor == null || anchorTime == null) {
      _anchor = point;
      _anchorTime = timestamp;
      return 0;
    }

    final dt = timestamp.difference(anchorTime).inMilliseconds / 1000.0;
    if (dt <= 0) {
      // A non-advancing clock cannot produce a rate; ignore this sample and
      // keep the existing anchor.
      return 0;
    }

    final meters = haversineMeters(anchor.lat, anchor.lng, point.lat, point.lng);

    if (meters < radiusFor(accuracyMeters)) {
      // Inside the noise radius. Hold the anchor — this is the gate that makes
      // a stationary receiver contribute nothing at all.
      return 0;
    }

    final impliedSpeed = meters / dt;

    if (impliedSpeed > maxSpeedMps) {
      // Not a bicycle. Drop the segment and re-seat the anchor at the new
      // position so the ride continues from wherever the rider actually is
      // rather than from a stale point.
      _anchor = point;
      _anchorTime = timestamp;
      return 0;
    }

    if (impliedSpeed < minSpeedForDistanceMps) {
      // Slow drift. Hold the anchor, so this distance is still counted later
      // if the rider really did move.
      return 0;
    }

    if (looksLikeMultipath(
      meters: meters,
      from: anchor,
      to: point,
      headingDegrees: headingDegrees,
      accuracyMeters: accuracyMeters,
      previousAccuracyMeters: previousAccuracyMeters,
    )) {
      // Urban canyon reflection. Hold the anchor; do not bank and do not
      // reseat — a later clean fix still measures from the last honest point.
      return 0;
    }

    _totalMeters += meters;
    _anchor = point;
    _anchorTime = timestamp;
    return meters;
  }

  /// Heading vs displacement disagree sharply, and accuracy just worsened.
  ///
  /// Either alone is common (a real corner; a brief sky obstruction). Together
  /// they are the multipath signature that would otherwise walk the anchor
  /// sideways between buildings. Pure function so the gate is unit-testable
  /// without a full ride.
  static bool looksLikeMultipath({
    required double meters,
    required GeoPoint from,
    required GeoPoint to,
    required double? headingDegrees,
    required double? accuracyMeters,
    required double? previousAccuracyMeters,
  }) {
    if (headingDegrees == null) return false;
    // Inside the noise floor the radius gate already held; nothing to soft-gate.
    if (meters < 12) return false;
    final displacement = initialBearingDegrees(
      from.lat,
      from.lng,
      to.lat,
      to.lng,
    );
    final disagreement = bearingDelta(headingDegrees, displacement);
    // A real hard turn moves heading and displacement together. Multipath
    // jumps the position while the reported course stays on the previous
    // street — that is the 75°+ disagreement.
    if (disagreement < 75) return false;
    final accuracy = accuracyMeters;
    final previous = previousAccuracyMeters;
    if (accuracy == null || previous == null) return false;
    // Sudden worsening, not merely "still poor": a canyon reflection arrives
    // as a spike on top of whatever the last epoch reported.
    return accuracy >= 15 && accuracy >= previous + 6;
  }

  /// Restores state after a crash, so the ride continues from its checkpoint
  /// without a phantom segment across the gap.
  void seed({
    required double totalMeters,
    GeoPoint? anchor,
    DateTime? anchorTime,
  }) {
    _totalMeters = totalMeters;
    _anchor = anchor;
    _anchorTime = anchorTime;
  }

  void reset() {
    _totalMeters = 0;
    _anchor = null;
    _anchorTime = null;
  }
}
