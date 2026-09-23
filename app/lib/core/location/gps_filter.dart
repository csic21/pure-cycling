import 'dart:collection';

import '../utils/geo.dart';
import 'elevation_tuning.dart';
import 'location_fix.dart';

/// Why a sample was or was not used (spec §13).
enum FixRejection {
  /// The sample passed every gate.
  accepted,

  /// The device clock went backwards, or the fix predates the previous one.
  timestampRegression,

  /// Horizontal accuracy worse than the configured ceiling. Recorded for the
  /// GPS indicator, excluded from distance and speed.
  accuracyTooPoor,

  /// Implied or reported speed exceeds what a bicycle can do.
  impossibleSpeed,

  /// A jump no bicycle could have made in the elapsed time.
  teleport,

  /// Same instant as the previous accepted sample.
  duplicate,

  /// The platform flagged this as a mocked position.
  mocked,

  /// No previous fix to compare against — the very first sample.
  firstFix,
}

/// A fix after validation and smoothing.
class ProcessedFix {
  const ProcessedFix({
    required this.raw,
    required this.rejection,
    this.speedMps,
    this.altitudeMeters,
    this.gradePercent,
    this.bearing,
    this.distanceAddedMeters = 0,
  });

  final LocationFix raw;
  final FixRejection rejection;

  /// Smoothed ground speed in m/s.
  final double? speedMps;

  /// Smoothed altitude in meters.
  final double? altitudeMeters;

  /// Smoothed gradient in percent, over a rolling distance window.
  final double? gradePercent;

  final double? bearing;

  /// Distance this sample contributed to the ride total.
  final double distanceAddedMeters;

  bool get accepted => rejection == FixRejection.accepted;

  /// Rejected samples still update the UI's GPS indicator, so they are worth
  /// reporting — they are just not worth recording.
  bool get isUsable => rejection == FixRejection.accepted;
}

/// Tunables for [GpsFilter].
class GpsFilterConfig {
  const GpsFilterConfig({
    this.maxAccuracyMeters = 50.0,
    this.maxSpeedMps = 30.0,
    this.reportedSpeedCeilingMps = 27.8, // 100 km/h — spec §13
    this.longGapSeconds = 120,
    this.longGapMaxSpeedMps = 20.0,
    this.speedSmoothingAlpha = 0.25,
    this.gradeWindowMeters = 150.0,
    this.minSpeedToReportMps = 0.8,
    this.minAltitudeSmoothingAlpha = 0.05,
  });

  /// Fixes worse than this are excluded from distance accumulation.
  final double maxAccuracyMeters;

  /// Hard ceiling on plausible ground speed.
  final double maxSpeedMps;

  /// A *reported* speed above this is treated as a device fault (spec §13).
  final double reportedSpeedCeilingMps;

  /// A gap longer than this means the rider was out of reception. The
  /// segment across it is only accepted if it is clearly plausible.
  final int longGapSeconds;
  final double longGapMaxSpeedMps;

  /// EMA weight for the newest sample. Lower is smoother and laggier.
  final double speedSmoothingAlpha;

  /// Distance over which gradient is measured. Short windows are unusable —
  /// GPS altitude noise of ±3 m over 20 m looks like a 30% wall.
  final double gradeWindowMeters;

  /// Below this the reading is shown as zero rather than as a slow crawl.
  final double minSpeedToReportMps;

  /// How much altitude smoothing is forced when the platform reports no
  /// vertical accuracy at all.
  ///
  /// Smoothing is normally taken from [ElevationTuning], which scales it to
  /// the quality the receiver claims. When the receiver claims nothing, this
  /// is the floor — and it is deliberately the pessimistic value.
  final double minAltitudeSmoothingAlpha;

  GpsFilterConfig copyWith({
    double? maxAccuracyMeters,
    int? longGapSeconds,
    double? gradeWindowMeters,
  }) =>
      GpsFilterConfig(
        maxAccuracyMeters: maxAccuracyMeters ?? this.maxAccuracyMeters,
        maxSpeedMps: maxSpeedMps,
        reportedSpeedCeilingMps: reportedSpeedCeilingMps,
        longGapSeconds: longGapSeconds ?? this.longGapSeconds,
        longGapMaxSpeedMps: longGapMaxSpeedMps,
        speedSmoothingAlpha: speedSmoothingAlpha,
        gradeWindowMeters: gradeWindowMeters ?? this.gradeWindowMeters,
        minSpeedToReportMps: minSpeedToReportMps,
        minAltitudeSmoothingAlpha: minAltitudeSmoothingAlpha,
      );
}

/// Validation and smoothing in front of the distance calculator (spec §13).
///
/// Order matters and is fixed: validate, then smooth, then accumulate. A
/// smoothed value derived from an unvalidated sample would quietly launder a
/// bad fix into the ride's statistics.
class GpsFilter {
  GpsFilter([this.config = const GpsFilterConfig()]);

  GpsFilterConfig config;

  LocationFix? _lastAccepted;
  double? _smoothedSpeed;
  double? _smoothedAltitude;
  double? _bearing;

  /// Rolling window of (cumulative distance, altitude) for gradient.
  final ListQueue<({double distance, double altitude})> _gradeWindow =
      ListQueue();

  double _gradeWindowDistance = 0;

  /// Number of consecutive samples rejected for poor accuracy.
  int poorAccuracyStreak = 0;

  /// Total samples seen and rejected, for the GPS quality indicator.
  int totalFixes = 0;
  int rejectedFixes = 0;

  LocationFix? get lastAccepted => _lastAccepted;
  double? get smoothedAltitude => _smoothedAltitude;

  /// Validates and smooths one sample.
  ///
  /// [cumulativeDistanceMeters] is the ride distance *before* this sample,
  /// needed to place the sample in the gradient window.
  ProcessedFix process(
    LocationFix fix, {
    double cumulativeDistanceMeters = 0,
  }) {
    totalFixes++;

    final last = _lastAccepted;

    if (last == null) {
      return _acceptFirst(fix);
    }

    final dtMs =
        fix.timestamp.difference(last.timestamp).inMilliseconds;

    if (dtMs <= 0) {
      rejectedFixes++;
      return ProcessedFix(
        raw: fix,
        rejection: dtMs == 0
            ? FixRejection.duplicate
            : FixRejection.timestampRegression,
        // Report the previous smoothed values so the UI does not flicker to
        // zero on a single bad timestamp.
        speedMps: _smoothedSpeed,
        altitudeMeters: _smoothedAltitude,
        gradePercent: _currentGrade,
        bearing: _bearing,
      );
    }

    final dtSeconds = dtMs / 1000.0;
    final meters =
        haversineMeters(last.latitude, last.longitude, fix.latitude, fix.longitude);
    final impliedSpeed = meters / dtSeconds;

    if (fix.isMocked) {
      rejectedFixes++;
      return ProcessedFix(
        raw: fix,
        rejection: FixRejection.mocked,
        speedMps: _smoothedSpeed,
        altitudeMeters: _smoothedAltitude,
        gradePercent: _currentGrade,
        bearing: _bearing,
      );
    }

    if (impliedSpeed > config.maxSpeedMps) {
      rejectedFixes++;
      // Re-seat so the ride resumes from where the rider is now instead of
      // dragging the anchor behind forever.
      _lastAccepted = fix;
      return ProcessedFix(
        raw: fix,
        rejection: fix.accuracy > config.maxAccuracyMeters
            ? FixRejection.accuracyTooPoor
            : FixRejection.teleport,
        speedMps: _smoothedSpeed,
        altitudeMeters: _smoothedAltitude,
        gradePercent: _currentGrade,
        bearing: _bearing,
      );
    }

    // A long gap — a tunnel, a dead zone — hides whatever happened in
    // between. Only bridge it when the average speed across the gap is
    // comfortable; otherwise the rider may well have turned down a street and
    // the straight line would be fiction.
    if (dtSeconds > config.longGapSeconds &&
        impliedSpeed > config.longGapMaxSpeedMps) {
      rejectedFixes++;
      _lastAccepted = fix;
      return ProcessedFix(
        raw: fix,
        rejection: FixRejection.teleport,
        speedMps: _smoothedSpeed,
        altitudeMeters: _smoothedAltitude,
        gradePercent: _currentGrade,
        bearing: _bearing,
      );
    }

    if (fix.hasAccuracy && fix.accuracy > config.maxAccuracyMeters) {
      poorAccuracyStreak++;
      rejectedFixes++;
      // Keep the anchor at the last *good* fix rather than re-seating on a
      // bad one: the rider has probably not moved much, and re-seating here
      // is exactly how a 50 m error becomes 50 m of phantom distance.
      return ProcessedFix(
        raw: fix,
        rejection: FixRejection.accuracyTooPoor,
        speedMps: _smoothedSpeed,
        altitudeMeters: _smoothedAltitude,
        gradePercent: _currentGrade,
        bearing: _bearing,
      );
    }

    poorAccuracyStreak = 0;

    // ---- Accepted: smooth and accumulate ----

    _lastAccepted = fix;

    final bearing = _smoothBearing(
      fix.heading,
      last.latitude,
      last.longitude,
      fix.latitude,
      fix.longitude,
    );

    final speed = _smoothSpeed(
      reported: fix.hasSpeed ? fix.speed : null,
      derived: impliedSpeed,
      distanceMeters: meters,
      dtSeconds: dtSeconds,
      accuracy: fix.hasAccuracy ? fix.accuracy : null,
    );

    final altitude = _smoothAltitude(fix.altitude, fix.altitudeAccuracy);

    return ProcessedFix(
      raw: fix,
      rejection: FixRejection.accepted,
      speedMps: speed,
      altitudeMeters: altitude,
      gradePercent: _currentGrade,
      bearing: bearing,
    );
  }

  /// Folds the accepted sample's distance into the gradient window.
  ///
  /// Called by the engine after [DistanceCalculator] has decided how much
  /// distance this sample actually earned — a sample that contributed nothing
  /// must not skew the gradient.
  void noteDistance(double distanceAddedMeters) {
    if (distanceAddedMeters <= 0) return;
    final alt = _smoothedAltitude;
    if (alt == null) return;

    _gradeWindowDistance += distanceAddedMeters;
    _gradeWindow.add((distance: _gradeWindowDistance, altitude: alt));

    while (_gradeWindow.length > 2 &&
        _gradeWindowDistance - _gradeWindow.first.distance >
            config.gradeWindowMeters) {
      _gradeWindow.removeFirst();
    }
  }

  double? get _currentGrade {
    if (_gradeWindow.length < 2) return null;
    final first = _gradeWindow.first;
    final last = _gradeWindow.last;
    final dist = last.distance - first.distance;
    if (dist < 20.0) return null; // Below 20 m the estimate is noise.
    final climb = last.altitude - first.altitude;
    return (climb / dist * 100).clamp(-40.0, 40.0);
  }

  ProcessedFix _acceptFirst(LocationFix fix) {
    _lastAccepted = fix;
    _smoothedAltitude = fix.altitude;
    // The first sample has no predecessor, so there is no derived speed. Use
    // the reported one if it exists; otherwise report zero rather than
    // inventing motion.
    _smoothedSpeed = (fix.hasSpeed && fix.speed! < config.maxSpeedMps)
        ? fix.speed
        : 0.0;
    _bearing = fix.heading;
    _gradeWindow.clear();
    _gradeWindowDistance = 0;
    if (_smoothedAltitude != null) {
      _gradeWindow.add((distance: 0, altitude: _smoothedAltitude!));
    }
    return ProcessedFix(
      raw: fix,
      rejection: FixRejection.firstFix,
      speedMps: _smoothedSpeed,
      altitudeMeters: _smoothedAltitude,
      bearing: _bearing,
    );
  }

  /// Blends the platform's Doppler speed with the distance-derived one
  /// (spec §12 — neither alone is trustworthy).
  ///
  /// Doppler speed is smoother and unaffected by position noise, but some
  /// receivers report a stale or zero value. The derived speed is exact for
  /// the segment in hand but explodes when the time delta is tiny. When they
  /// agree, weight the platform value; when they disagree, take the smaller
  /// magnitude, because the failure mode of both is to over-report.
  double _smoothSpeed({
    required double? reported,
    required double derived,
    required double distanceMeters,
    required double dtSeconds,
    required double? accuracy,
  }) {
    double candidate;

    final reportedUsable = reported != null &&
        reported.isFinite &&
        reported >= 0 &&
        reported < config.reportedSpeedCeilingMps;

    // Derived speed is meaningless when the segment is shorter than the GPS
    // noise floor or the interval is too short to divide by.
    final derivedUsable =
        distanceMeters >= 3.0 && dtSeconds >= 0.5 && derived < config.maxSpeedMps;

    // ---- The stopped case, decided immediately ----
    //
    // When the position has not moved at all *and* the receiver agrees the
    // rider is barely moving, there is no ambiguity to smooth away: they are
    // stopped, and the reading should say so now.
    //
    // Without this, the exponential decay below takes several seconds to fall
    // from riding speed to a standstill, and every one of those seconds is
    // time the auto-pause rule is not yet counting toward its delay. A rider
    // who brakes at a red light would wait roughly ten seconds for a pause
    // configured at five.
    if (distanceMeters < 2.0 && reportedUsable && reported < 2.0) {
      _smoothedSpeed = reported;
      return _smoothedSpeed!;
    }

    if (reportedUsable && derivedUsable) {
      final diff = (reported - derived).abs();
      final tolerance = (reported * 0.35).clamp(1.5, 6.0);
      candidate = diff <= tolerance
          ? reported * 0.6 + derived * 0.4
          : (reported < derived ? reported : derived);
    } else if (reportedUsable) {
      candidate = reported;
    } else if (derivedUsable) {
      candidate = derived;
    } else {
      // Neither is usable this instant — hold the previous smoothed value and
      // decay it slightly, which reads as "coasting" rather than as a spike.
      candidate = (_smoothedSpeed ?? 0) * 0.9;
    }

    // Poor accuracy means noisy position, so lean harder on the previous
    // value; good accuracy means the new sample is worth more.
    var alpha = config.speedSmoothingAlpha;
    if (accuracy != null) {
      if (accuracy > 20) {
        alpha *= 0.6;
      } else if (accuracy < 6) {
        alpha = (alpha * 1.4).clamp(0.0, 0.6);
      }
    }

    final previous = _smoothedSpeed;

    // Asymmetric: fall fast, rise slow.
    //
    // A bicycle can brake hard but cannot accelerate instantly, so a falling
    // reading is more trustworthy than a rising one. Symmetric smoothing
    // would keep the display — and the auto-pause rule — reading a stale
    // cruising speed for several seconds after the rider has actually
    // stopped, which is exactly the moment the number matters most.
    if (previous != null && candidate < previous) {
      alpha = (alpha * 2.0).clamp(0.0, 0.7);
    }

    var smoothed =
        previous == null ? candidate : previous + alpha * (candidate - previous);

    // Snap to zero at a standstill. Without this the readout sits at
    // "0.6 km/h" at every red light, which reads as a bug.
    if (smoothed < config.minSpeedToReportMps && distanceMeters < 2.0) {
      smoothed = 0;
    }
    if (_smoothedSpeed != null &&
        _smoothedSpeed! == 0 &&
        smoothed < config.minSpeedToReportMps) {
      smoothed = 0;
    }

    _smoothedSpeed = smoothed < 0 ? 0 : smoothed;
    return _smoothedSpeed!;
  }

  /// Smooths the altitude series, scaled to how much the source can be
  /// trusted.
  ///
  /// A barometer and a bare GPS receiver need completely different treatment:
  /// the first has ~0.1 m of white noise, the second has metres of slow drift
  /// that no amount of filtering separates from real terrain. See
  /// [ElevationTuning].
  double? _smoothAltitude(double? rawAltitude, double? verticalAccuracy) {
    if (rawAltitude == null) return _smoothedAltitude;

    _noteVerticalAccuracy(verticalAccuracy);
    final tuning = this.tuning;

    final previous = _smoothedAltitude;
    if (previous == null) {
      _smoothedAltitude = rawAltitude;
      return _smoothedAltitude;
    }

    final delta = rawAltitude - previous;
    // Deadband: below the threshold, keep the previous value untouched so the
    // altitude readout does not twitch while the rider is stationary.
    if (delta.abs() < tuning.deadbandMeters) return previous;

    // Never smooth more slowly than the floor, whatever the source claims.
    // A receiver that reports a precise-looking accuracy while drifting would
    // otherwise get the lightest smoothing and the loosest threshold.
    final alpha = tuning.smoothingAlpha < config.minAltitudeSmoothingAlpha
        ? config.minAltitudeSmoothingAlpha
        : tuning.smoothingAlpha;

    _smoothedAltitude = previous + alpha * (rawAltitude - previous);
    return _smoothedAltitude;
  }

  /// Tracks the typical vertical accuracy this receiver is actually giving.
  ///
  /// An EMA rather than the latest value: a single fix can report an
  /// optimistic number, and the tuning should reflect the ride rather than
  /// one sample of it.
  void _noteVerticalAccuracy(double? verticalAccuracy) {
    if (verticalAccuracy == null || verticalAccuracy <= 0) return;
    final previous = _verticalAccuracyEstimate;
    _verticalAccuracyEstimate = previous == null
        ? verticalAccuracy
        : previous + 0.1 * (verticalAccuracy - previous);
    if (previous == null) return;
  }

  double? _verticalAccuracyEstimate;

  /// The elevation parameters currently in force.
  ///
  /// Derived from the running estimate of vertical accuracy, so a ride that
  /// starts under a bridge and emerges into open sky loosens its smoothing as
  /// the receiver improves.
  ElevationTuning get tuning =>
      ElevationTuning.forVerticalAccuracy(_verticalAccuracyEstimate);

  double? _smoothBearing(
    double? reported,
    double fromLat,
    double fromLng,
    double toLat,
    double toLng,
  ) {
    final moved = haversineMeters(fromLat, fromLng, toLat, toLng);
    final heading = (moved >= 3.0 && reported == null)
        ? initialBearingDegrees(fromLat, fromLng, toLat, toLng)
        : reported;

    if (heading == null) return _bearing;
    final previous = _bearing;
    if (previous == null) return _bearing = normalizeBearing(heading);

    // Bearing is circular: interpolating naively across 359°/1° would swing
    // the arrow the long way round.
    final delta = signedTurnAngle(previous, heading);
    return _bearing = normalizeBearing(previous + delta * 0.3);
  }

  /// Resets all state, e.g. after a long pause or a crash resume.
  void reset() {
    _lastAccepted = null;
    _smoothedSpeed = null;
    _smoothedAltitude = null;
    _bearing = null;
    _gradeWindow.clear();
    _gradeWindowDistance = 0;
    poorAccuracyStreak = 0;
    totalFixes = 0;
    rejectedFixes = 0;
    // The accuracy estimate is deliberately *not* cleared: it describes the
    // receiver, which has not changed, and discarding it would re-tighten the
    // elevation tuning to the pessimistic default for the next few minutes.
  }

  /// Restores smoothing state after a crash so the readout does not restart
  /// from zero.
  void seed({
    LocationFix? lastFix,
    double? smoothedSpeed,
    double? smoothedAltitude,
  }) {
    _lastAccepted = lastFix;
    _smoothedSpeed = smoothedSpeed;
    _smoothedAltitude = smoothedAltitude;
    _gradeWindow.clear();
    _gradeWindowDistance = 0;
    if (smoothedAltitude != null) {
      _gradeWindow.add((distance: 0, altitude: smoothedAltitude));
    }
  }

  /// Fraction of samples rejected, `0..1`, for the GPS quality indicator.
  double get rejectionRatio =>
      totalFixes == 0 ? 0 : rejectedFixes / totalFixes;
}
