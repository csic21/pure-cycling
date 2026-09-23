/// Accumulates total climbing and descending from a smoothed altitude series.
///
/// ## Why not just sum the positive differences
///
/// Summing every positive delta of a GPS altitude trace produces fantasy
/// numbers — a flat ride can "climb" 400 m on noise alone, because the ±2 m
/// wander of a consumer GPS altimeter is the same magnitude as a real short
/// rise. Some threshold is needed.
///
/// ## Why not threshold against a fixed reference
///
/// The obvious design is a reference that only moves when the profile pulls
/// away from it:
///
/// ```dart
/// if (alt > ref + T) { gain += alt - ref; ref = alt; }
/// if (alt < ref - T) { loss += ref - alt; ref = alt; }
/// ```
///
/// It works for a barometer. It is *broken* for rolling terrain, and the
/// failure is silent and total: once the reference lands in the middle of an
/// oscillation whose amplitude is within a factor of two of the threshold,
/// neither extreme ever pulls away from it again, and the accumulator counts
/// nothing for the rest of the ride.
///
/// Measured: a river path with ten 20 m rollers, on a phone reporting ±15 m
/// vertical accuracy, reported **12 m of climbing instead of 200**.
///
/// ## What this does instead
///
/// Peak and valley detection. The series is walked in whichever direction it
/// is currently going; a reversal is only *confirmed* once the profile has
/// retreated from its running extreme by more than the threshold. A confirmed
/// valley-to-peak pair is banked as climbing, a peak-to-valley pair as
/// descending.
///
/// That has the property the reference design lacks: a confirmed extreme is
/// always an actual turning point, so the state can never end up parked
/// between two extremes. Rolling terrain accumulates roller by roller, and
/// the sub-threshold wiggles of a stationary receiver still cancel out because
/// they never confirm a reversal.
///
/// ## The in-progress leg has to count
///
/// Peak detection alone is not enough, and the way it fails is worth stating
/// because it is the opposite of the bug above. A *monotonic* climb never
/// retreats, so no peak is ever confirmed and the total sits at zero for the
/// entire ascent. Measured: a 300 m alpine pass reported **0 m**.
///
/// So the leg currently in progress counts too — the distance from the last
/// confirmed turning point to the running extreme in the current direction.
/// The reported totals are the banked pairs plus that live leg, which is also
/// what makes the dashboard's climb figure tick upward during a climb rather
/// than jumping when the rider finally crests.
///
/// The trade is deliberate and unchanged from before: very short climbs are
/// sacrificed to keep the total honest. Riders compare total climb between
/// rides, and a number that swings by hundreds of metres run to run is worse
/// than one that misses a 5 m bump.
class ElevationAccumulator {
  ElevationAccumulator({this.thresholdMeters = 2.0});

  /// How far the smoothed profile must retreat from its extreme before a
  /// turning point is confirmed.
  ///
  /// Two meters sits below any climb a rider would name, and above the noise
  /// of a barometer. It is **not** a safe value for a GPS-only altitude
  /// source, whose error drifts by tens of metres over a ride — see
  /// `ElevationTuning`, which supplies this number scaled to what the receiver
  /// can actually deliver.
  ///
  /// Mutable because the correct value depends on the receiver, which is not
  /// known until fixes start arriving.
  double thresholdMeters;

  /// Totals from *confirmed* turning points.
  double _bankedGain = 0;
  double _bankedLoss = 0;

  bool _seeded = false;

  /// Extremes since the last confirmed turning point: the running maximum
  /// while rising, the running minimum while falling.
  double _peak = 0;
  double _valley = 0;

  /// Which way the profile is currently moving.
  bool _rising = true;

  /// Whether the profile is currently rising. Exposed for tests that want to
  /// assert on the state machine rather than only on the totals.
  bool get isRising => _rising;

  /// The leg in progress, from the last confirmed turning point to the running
  /// extreme. Zero before anything has been seen.
  double get currentLegMeters {
    final leg = _peak - _valley;
    return leg > 0 ? leg : 0;
  }

  /// Total climbing, including the ascent currently under way.
  ///
  /// The live leg is included because a climb in progress is climbing: a
  /// total that sat at zero until the rider crested would be worse than
  /// useless on a mountain pass.
  double get gainMeters => _bankedGain + (_rising ? currentLegMeters : 0);

  /// Total descending, including the descent currently under way.
  double get lossMeters => _bankedLoss + (_rising ? 0 : currentLegMeters);

  /// Feeds a smoothed altitude sample.
  void add(double altitudeMeters) {
    if (!altitudeMeters.isFinite) return;

    if (!_seeded) {
      _seeded = true;
      _peak = altitudeMeters;
      _valley = altitudeMeters;
      return;
    }

    if (_rising) {
      if (altitudeMeters > _peak) {
        _peak = altitudeMeters;
      } else if (_peak - altitudeMeters >= thresholdMeters) {
        // The retreat confirms the peak. The climb from the last valley to it
        // is banked, and the descent starts tracking from here.
        _bankedGain += _peak - _valley;
        _rising = false;
        _valley = altitudeMeters;
      }
    } else {
      if (altitudeMeters < _valley) {
        _valley = altitudeMeters;
      } else if (altitudeMeters - _valley >= thresholdMeters) {
        _bankedLoss += _peak - _valley;
        _rising = true;
        _peak = altitudeMeters;
      }
    }
  }

  void reset() {
    _bankedGain = 0;
    _bankedLoss = 0;
    _seeded = false;
    _peak = 0;
    _valley = 0;
    _rising = true;
  }

  /// Re-anchors the running extremes to [altitudeMeters].
  ///
  /// Called when the threshold changes, which only happens when the receiver's
  /// reported accuracy crosses a bucket boundary. The extremes have to move
  /// with it: leaving a peak recorded under the old threshold would bank the
  /// difference between the two thresholds as climbing, which is an artefact
  /// of the change rather than anything the rider did.
  ///
  /// The leg in progress is **banked first**, not discarded. An earlier
  /// version reset the extremes without doing so, which silently threw away
  /// the entire ascent on a monotonic climb — the one case where the live leg
  /// is the whole total. A 300 m pass would have reported 0 m if the
  /// receiver's accuracy estimate happened to cross a boundary partway up.
  void reseed(double altitudeMeters) {
    if (!altitudeMeters.isFinite) return;

    if (_seeded) {
      if (_rising) {
        _bankedGain += currentLegMeters;
      } else {
        _bankedLoss += currentLegMeters;
      }
    }

    _seeded = true;
    _peak = altitudeMeters;
    _valley = altitudeMeters;
  }

  /// Restores totals after a crash, re-seeding the extremes so the resume does
  /// not double-count the climb already banked.
  void seed({
    required double gain,
    required double loss,
    double? referenceAltitude,
  }) {
    _bankedGain = gain;
    _bankedLoss = loss;
    if (referenceAltitude != null && referenceAltitude.isFinite) {
      _seeded = true;
      _peak = referenceAltitude;
      _valley = referenceAltitude;
    }
  }
}
