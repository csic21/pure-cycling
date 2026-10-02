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
    this.altitudeAccuracyMeters,
    this.gradePercent,
    this.bearing,
    this.distanceAddedMeters = 0,
  });

  final LocationFix raw;
  final FixRejection rejection;

  /// Smoothed ground speed in m/s.
  final double? speedMps;

  /// Smoothed altitude in meters.
  ///
  /// When a barometer is reporting this is the barometric series, not the GPS
  /// one — see [GpsFilter.onBarometricAltitude].
  final double? altitudeMeters;

  /// How much to trust [altitudeMeters], for the track point that stores it.
  ///
  /// Normally the fix's own `altitudeAccuracy`, but a barometer overrides it:
  /// the point carries the barometric altitude, so it has to carry the
  /// barometric accuracy too, or the ride detail would label a measured climb
  /// as an estimate.
  final double? altitudeAccuracyMeters;

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
  }) => GpsFilterConfig(
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
  LocationFix? _zeroSpeedAnchor;
  double _zeroSpeedPathMeters = 0;
  bool _zeroSpeedMovementConfirmed = false;

  /// The GPS altitude series. The one that drifts.
  double? _smoothedGpsAltitude;

  /// The barometric altitude series. Present only while a barometer reports.
  double? _smoothedBaroAltitude;

  DateTime? _lastBaroAt;
  double? _lastGpsVerticalAccuracy;
  double? _bearing;

  double? _compassHeading;
  DateTime? _compassAt;
  double? _compassAccuracy;

  /// `gpsCourse − compass`, sampled while the GPS course was trustworthy.
  ///
  /// The whole point is that it is a *difference*: it converts the compass's
  /// frame into the frame the GPS and the map already use, so the compass can
  /// stand in for a missing course without either platform having to model
  /// magnetic declination or the angle the phone is mounted at. See
  /// [onCompassHeading].
  double? _compassAnchor;

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

  /// The altitude in force: the barometer when one is reporting, GPS otherwise.
  double? get smoothedAltitude => _smoothedBaroAltitude ?? _smoothedGpsAltitude;

  /// The GPS-only altitude, ignoring any barometer.
  ///
  /// Used by the engine to anchor the barometric series to a real height: a
  /// barometer knows the *shape* of a climb, GPS knows roughly where in the
  /// world that shape sits.
  double? get gpsSmoothedAltitude => _smoothedGpsAltitude;

  /// Whether the altitude in force came from a barometer.
  bool get barometerActive => _smoothedBaroAltitude != null;

  /// Feeds a barometric altitude, in metres.
  ///
  /// No deadband here, unlike the GPS path, and the reason is the opposite of
  /// the GPS reason. A barometer's noise is white and tiny, so a deadband
  /// would filter nothing — it would *stall* the series on any climb slow
  /// enough that consecutive samples move less than the threshold. A gentle 5%
  /// grade at 7 km/h is 0.1 m/s; sampled at 5 Hz that is 2 cm per sample, and a
  /// 0.3 m deadband would freeze the profile for the entire ascent.
  ///
  /// A light EMA follows instead. Light on purpose: the lag of a plain EMA is
  /// `(1−α)/α` samples, so a heavy α would leave a *systematic* shortfall on
  /// any sustained climb — at 0.15, a 120 m pass would read about 11 m low.
  /// Half is enough to halve a one-sample glitch (a door slamming, a gust)
  /// while costing a couple of centimetres of lag at the platform's cadence,
  /// and the real filtering is the accumulator's 2 m threshold, which is ten
  /// to forty standard deviations of the sensor's noise.
  ///
  /// The vertical-accuracy estimate is pinned while a barometer reports: it
  /// decides the smoothing, the gain threshold and the quality label, and the
  /// GPS figure would pull it straight back to the pessimistic bucket.
  static const double _barometricSmoothingAlpha = 0.5;

  void onBarometricAltitude(double altitudeMeters, {required DateTime at}) {
    if (!altitudeMeters.isFinite) return;

    // The time comes from the caller rather than from `DateTime.now()`, so
    // that staleness is judged against the same clock the fixes use. Reading
    // the wall clock here would compare platform timestamps with process time
    // the moment a test — or a device with a corrected clock — uses anything
    // but "now".
    _lastBaroAt = at;

    final previous = _smoothedBaroAltitude;
    if (previous == null) {
      _smoothedBaroAltitude = altitudeMeters;
    } else {
      _smoothedBaroAltitude =
          previous + _barometricSmoothingAlpha * (altitudeMeters - previous);
    }

    _verticalAccuracyEstimate = ElevationTuning.barometerAccuracyMeters;
  }

  /// Feeds a compass reading, in degrees clockwise from north.
  ///
  /// ## What this is for
  ///
  /// The bearing this filter produces has one hole in it, and it is a large
  /// one. A derived course needs three metres of travel between two accepted
  /// fixes — at 1 Hz that is 10.8 km/h — so below that speed, and at every
  /// junction, and for the first seconds of a ride, there is no new direction
  /// to report and the last one is carried forward. That is exactly the range
  /// a bicycle spends its slowest and most navigation-dependent moments in.
  /// A magnetometer has no such floor: it knows which way the phone points
  /// while the bike is completely stopped.
  ///
  /// ## What it is not for
  ///
  /// It never overrides a working GPS course. A compass reads the direction
  /// the **phone** points; the phone is only the bike when it is mounted the
  /// way the bike faces, and in a jersey pocket it is noise. So the GPS course
  /// stays authoritative whenever it exists, and the compass only fills in
  /// when it does not.
  ///
  /// ## Why the reading is anchored rather than trusted
  ///
  /// What gets used as a stand-in is `compass + anchor`, where the anchor is
  /// `last good GPS course − compass at that moment`. Two properties fall out
  /// of that, and they are the reason for the design rather than a side
  /// effect:
  ///
  /// * **A constant frame offset cancels.** Magnetic declination (several
  ///   degrees, and it varies by region) and the angle the phone happens to be
  ///   mounted at are both fixed for the length of a ride, and both are
  ///   absorbed. Neither platform has to model either one.
  /// * **The absolute frame stays the GPS one.** The stand-in inherits the
  ///   frame the GPS established instead of adopting the phone's own idea of
  ///   where north is.
  ///
  /// Before a trustworthy GPS course has been seen there is no anchor, so
  /// readings are ignored rather than invented — a ride that starts at a
  /// standstill behaves exactly as it did before a compass existed.
  ///
  /// [at] comes from the caller rather than from `DateTime.now()`, for the
  /// reason [onBarometricAltitude] gives: staleness has to be judged against
  /// the clock the fixes use.
  void onCompassHeading(
    double degrees, {
    required DateTime at,
    double? accuracyDegrees,
  }) {
    if (!degrees.isFinite) return;

    // A negative accuracy is the platform saying "I cannot quantify this",
    // which is not the same statement as zero error.
    _compassAccuracy = (accuracyDegrees != null && accuracyDegrees >= 0)
        ? accuracyDegrees
        : null;
    _compassHeading = normalizeBearing(degrees);
    _compassAt = at;
  }

  /// Validates and smooths one sample.
  ///
  /// [cumulativeDistanceMeters] is the ride distance *before* this sample,
  /// needed to place the sample in the gradient window.
  ProcessedFix process(LocationFix fix, {double cumulativeDistanceMeters = 0}) {
    totalFixes++;

    // A barometer that stops reporting has to hand the altitude back to GPS,
    // or the ride keeps a frozen altitude for the rest of the day. Fifteen
    // seconds is well past the sensor's normal cadence and well short of a
    // tunnel.
    final lastBaro = _lastBaroAt;
    if (lastBaro != null &&
        fix.timestamp.difference(lastBaro) > const Duration(seconds: 15)) {
      _smoothedBaroAltitude = null;
      _lastBaroAt = null;
      _verticalAccuracyEstimate = _lastGpsVerticalAccuracy;
    }

    final last = _lastAccepted;

    if (last == null) {
      return _acceptFirst(fix);
    }

    final dtMs = fix.timestamp.difference(last.timestamp).inMilliseconds;

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
        // Report the previous smoothed values so the UI does not flicker to
        // zero on one bad sample. The altitude is whichever source is in
        // force, barometer included.
        altitudeMeters: smoothedAltitude,
        altitudeAccuracyMeters: barometerActive
            ? ElevationTuning.barometerAccuracyMeters
            : _reportedVerticalAccuracy(fix),
        gradePercent: _currentGrade,
        bearing: _bearing,
      );
    }

    final dtSeconds = dtMs / 1000.0;
    final meters = haversineMeters(
      last.latitude,
      last.longitude,
      fix.latitude,
      fix.longitude,
    );
    final impliedSpeed = meters / dtSeconds;

    if (fix.isMocked) {
      rejectedFixes++;
      return ProcessedFix(
        raw: fix,
        rejection: FixRejection.mocked,
        speedMps: _smoothedSpeed,
        // Report the previous smoothed values so the UI does not flicker to
        // zero on one bad sample. The altitude is whichever source is in
        // force, barometer included.
        altitudeMeters: smoothedAltitude,
        altitudeAccuracyMeters: barometerActive
            ? ElevationTuning.barometerAccuracyMeters
            : _reportedVerticalAccuracy(fix),
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
        // Report the previous smoothed values so the UI does not flicker to
        // zero on one bad sample. The altitude is whichever source is in
        // force, barometer included.
        altitudeMeters: smoothedAltitude,
        altitudeAccuracyMeters: barometerActive
            ? ElevationTuning.barometerAccuracyMeters
            : _reportedVerticalAccuracy(fix),
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
        // Report the previous smoothed values so the UI does not flicker to
        // zero on one bad sample. The altitude is whichever source is in
        // force, barometer included.
        altitudeMeters: smoothedAltitude,
        altitudeAccuracyMeters: barometerActive
            ? ElevationTuning.barometerAccuracyMeters
            : _reportedVerticalAccuracy(fix),
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
        // Report the previous smoothed values so the UI does not flicker to
        // zero on one bad sample. The altitude is whichever source is in
        // force, barometer included.
        altitudeMeters: smoothedAltitude,
        altitudeAccuracyMeters: barometerActive
            ? ElevationTuning.barometerAccuracyMeters
            : _reportedVerticalAccuracy(fix),
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
      fix.timestamp,
    );

    final speed = _smoothSpeed(
      fix: fix,
      previousFix: last,
      reported: fix.hasSpeed ? fix.speed : null,
      derived: impliedSpeed,
      distanceMeters: meters,
      dtSeconds: dtSeconds,
      accuracy: fix.hasAccuracy ? fix.accuracy : null,
    );

    // The GPS series is always updated — it is what the barometer hands back
    // to if it stops — but the altitude that leaves this method prefers the
    // barometer.
    final gpsAltitude = _smoothAltitude(fix.altitude, fix.altitudeAccuracy);
    final altitude = smoothedAltitude ?? gpsAltitude;

    return ProcessedFix(
      raw: fix,
      rejection: FixRejection.accepted,
      speedMps: speed,
      altitudeMeters: altitude,
      altitudeAccuracyMeters: barometerActive
          ? ElevationTuning.barometerAccuracyMeters
          : _reportedVerticalAccuracy(fix),
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
    final alt = smoothedAltitude;
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
    _smoothedGpsAltitude = fix.altitude;
    // The first sample has no predecessor, so there is no derived speed. Use
    // the reported one if it exists; otherwise report zero rather than
    // inventing motion.
    _smoothedSpeed = (fix.hasSpeed && fix.speed! < config.maxSpeedMps)
        ? fix.speed
        : 0.0;
    _bearing = fix.heading;
    _lastFixHadCourse = fix.heading != null;
    _gradeWindow.clear();
    _gradeWindowDistance = 0;
    final altitude = smoothedAltitude;
    if (altitude != null) {
      _gradeWindow.add((distance: 0, altitude: altitude));
    }
    return ProcessedFix(
      raw: fix,
      rejection: FixRejection.firstFix,
      speedMps: _smoothedSpeed,
      altitudeMeters: altitude,
      altitudeAccuracyMeters: barometerActive
          ? ElevationTuning.barometerAccuracyMeters
          : _reportedVerticalAccuracy(fix),
      bearing: _bearing,
    );
  }

  /// The fix's own vertical accuracy, normalised: null when the platform did
  /// not report one.
  static double? _reportedVerticalAccuracy(LocationFix fix) {
    final accuracy = fix.altitudeAccuracy;
    return (accuracy != null && accuracy.isFinite && accuracy > 0)
        ? accuracy
        : null;
  }

  /// Blends the platform's Doppler speed with the distance-derived one
  /// (spec §12 — neither alone is trustworthy).
  ///
  /// Doppler speed is smoother and unaffected by position noise, but some
  /// receivers report a stale or zero value. The derived speed is exact for
  /// the segment in hand but explodes when the time delta is tiny. When they
  /// agree, weight the platform value. A trusted Doppler sample that is
  /// higher is acceleration and is taken as-is; a lower one is braking.
  /// Sustained position change can also disprove a platform speed stuck at
  /// zero.
  double _smoothSpeed({
    required LocationFix fix,
    required LocationFix previousFix,
    required double? reported,
    required double derived,
    required double distanceMeters,
    required double dtSeconds,
    required double? accuracy,
  }) {
    double candidate;

    final reportedUsable =
        reported != null &&
        reported.isFinite &&
        reported >= 0 &&
        reported < config.reportedSpeedCeilingMps;

    // Derived speed is meaningless when the segment is shorter than the GPS
    // noise floor or the interval is too short to divide by.
    final derivedUsable =
        distanceMeters >= 3.0 &&
        dtSeconds >= 0.5 &&
        derived < config.maxSpeedMps;

    // Some Android providers keep reporting Doppler speed as zero while
    // positions move. One segment can be GPS jitter, so only override that
    // zero after several fixes have moved consistently beyond a confirmation
    // radius. Keep the decision until a genuinely stationary fix arrives.
    //
    // Free rides cannot lean on route-progress fill (`noteRouteMatch`), so the
    // confirmation here is intentionally a little more eager than the
    // distance calculator's own radius: a stuck Doppler zero in an urban
    // canyon otherwise sits below the display floor for many seconds, and
    // auto-pause mistakes riding for a stop. The path-consistency check still
    // rejects the parked-bike oscillation that would otherwise look like
    // travel.
    final zeroReported =
        reportedUsable && reported < config.minSpeedToReportMps;
    double? confirmedPositionSpeed;
    if (zeroReported) {
      var anchor = _zeroSpeedAnchor ?? previousFix;
      if (!_zeroSpeedMovementConfirmed &&
          fix.timestamp.difference(anchor.timestamp) >
              const Duration(seconds: 12)) {
        anchor = previousFix;
        _zeroSpeedPathMeters = 0;
      }
      _zeroSpeedAnchor = anchor;
      _zeroSpeedPathMeters += distanceMeters;
      final netMeters = haversineMeters(
        anchor.latitude,
        anchor.longitude,
        fix.latitude,
        fix.longitude,
      );
      final spanSeconds =
          fix.timestamp.difference(anchor.timestamp).inMilliseconds / 1000;
      final accuracy = anchor.accuracy > fix.accuracy
          ? anchor.accuracy
          : fix.accuracy;
      // Tighter than the distance anchor (which uses accuracy×2 up to 25 m):
      // we only need enough evidence to distrust a stuck zero, not to bank
      // mileage. Cap stays modest so a poor fix cannot demand a city block.
      final radius = accuracy.clamp(8.0, 16.0);
      final netSpeed =
          spanSeconds > 0 ? netMeters / spanSeconds : 0.0;
      final consistent =
          netMeters >= _zeroSpeedPathMeters * 0.55 &&
          netSpeed >= config.minSpeedToReportMps;
      // Two ways in: clear the (tighter) radius, or accumulate enough path
      // with a coherent net so a canyon that inflates accuracy still escapes.
      final clearedRadius =
          spanSeconds >= 1.5 && netMeters >= radius && consistent;
      final pathEscape =
          spanSeconds >= 2.5 &&
          _zeroSpeedPathMeters >= 10 &&
          netMeters >= 8 &&
          consistent;
      if (!_zeroSpeedMovementConfirmed && (clearedRadius || pathEscape)) {
        _zeroSpeedMovementConfirmed = true;
      }
      if (_zeroSpeedMovementConfirmed) {
        confirmedPositionSpeed = derivedUsable
            ? derived
            : netSpeed;
      }
    } else {
      _resetZeroSpeedConflict();
    }

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
    final stopRadius = _zeroSpeedMovementConfirmed
        ? ((_smoothedSpeed ?? 0) * dtSeconds * 0.25).clamp(0.5, 2.0)
        : 2.0;
    if (distanceMeters < stopRadius && reportedUsable && reported < 2.0) {
      if (_zeroSpeedMovementConfirmed) _resetZeroSpeedConflict();
      _smoothedSpeed = reported;
      return _smoothedSpeed!;
    }

    // A Doppler sample is trusted when the receiver says so (tight speed
    // accuracy) or the horizontal fix is already good enough to ride on.
    // Position-derived speed lags a real acceleration by a fix or two; the
    // satellite's own speed does not.
    final speedAccuracy = fix.speedAccuracy;
    final dopplerTrusted =
        reportedUsable &&
        ((speedAccuracy != null &&
                speedAccuracy.isFinite &&
                speedAccuracy > 0 &&
                speedAccuracy <= 1.5) ||
            (accuracy != null && accuracy <= 25));

    if (confirmedPositionSpeed != null) {
      candidate = confirmedPositionSpeed;
    } else if (reportedUsable && derivedUsable) {
      final diff = (reported - derived).abs();
      final tolerance = (reported * 0.35).clamp(1.5, 6.0);
      if (diff <= tolerance) {
        candidate = dopplerTrusted
            ? reported * 0.8 + derived * 0.2
            : reported * 0.6 + derived * 0.4;
      } else if (reported <= derived || dopplerTrusted) {
        // Braking: the lower number is the one that just happened. A trusted
        // Doppler value that is higher is acceleration, and the position
        // segment has not caught up yet.
        candidate = reported;
      } else {
        candidate = derived;
      }
    } else if (reportedUsable) {
      candidate = reported;
    } else if (derivedUsable) {
      candidate = derived;
    } else {
      // Neither is usable this instant — hold the previous smoothed value and
      // decay it slightly, which reads as "coasting" rather than as a spike.
      candidate = (_smoothedSpeed ?? 0) * 0.9;
    }

    final previous = _smoothedSpeed;
    final rising = previous == null || candidate >= previous;

    // Poor accuracy means noisy position, so lean harder on the previous
    // value; good accuracy means the new sample is worth more. A trusted
    // Doppler rise skips that lag: one sample should already read as the
    // speed the receiver just measured.
    var alpha = config.speedSmoothingAlpha;
    if (dopplerTrusted && rising) {
      alpha = 0.85;
    } else if (accuracy != null) {
      if (accuracy > 20) {
        alpha *= 0.6;
      } else if (accuracy < 6) {
        alpha = (alpha * 1.4).clamp(0.0, 0.6);
      }
    }

    // Fall fast. A bicycle can brake hard, and a stale cruise speed is what
    // keeps auto-pause from counting the seconds at a red light.
    if (previous != null && candidate < previous) {
      alpha = (alpha * 2.0).clamp(0.0, 0.7);
    }

    var smoothed = previous == null
        ? candidate
        : previous + alpha * (candidate - previous);
    if (confirmedPositionSpeed != null && previous == 0) {
      // EMA from zero can remain below the display floor on a slow ride.
      smoothed = candidate;
    }

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

  void _resetZeroSpeedConflict() {
    _zeroSpeedAnchor = null;
    _zeroSpeedPathMeters = 0;
    _zeroSpeedMovementConfirmed = false;
  }

  /// Smooths the altitude series, scaled to how much the source can be
  /// trusted.
  ///
  /// A barometer and a bare GPS receiver need completely different treatment:
  /// the first has ~0.1 m of white noise, the second has metres of slow drift
  /// that no amount of filtering separates from real terrain. See
  /// [ElevationTuning].
  double? _smoothAltitude(double? rawAltitude, double? verticalAccuracy) {
    if (rawAltitude == null) return _smoothedGpsAltitude;

    _noteVerticalAccuracy(verticalAccuracy);
    final tuning = this.tuning;

    final previous = _smoothedGpsAltitude;
    if (previous == null) {
      _smoothedGpsAltitude = rawAltitude;
      return _smoothedGpsAltitude;
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

    _smoothedGpsAltitude = previous + alpha * (rawAltitude - previous);
    return _smoothedGpsAltitude;
  }

  /// Tracks the typical vertical accuracy this receiver is actually giving.
  ///
  /// An EMA rather than the latest value: a single fix can report an
  /// optimistic number, and the tuning should reflect the ride rather than
  /// one sample of it.
  void _noteVerticalAccuracy(double? verticalAccuracy) {
    if (verticalAccuracy == null || verticalAccuracy <= 0) return;

    _lastGpsVerticalAccuracy = verticalAccuracy;

    // A reporting barometer owns the answer; the GPS figure is still recorded
    // above so it can take over again if the barometer goes quiet.
    if (barometerActive) return;

    final previous = _verticalAccuracyEstimate;
    _verticalAccuracyEstimate = previous == null
        ? verticalAccuracy
        : previous + 0.1 * (verticalAccuracy - previous);
  }

  double? _verticalAccuracyEstimate;

  /// The elevation parameters currently in force.
  ///
  /// Derived from the running estimate of vertical accuracy, so a ride that
  /// starts under a bridge and emerges into open sky loosens its smoothing as
  /// the receiver improves.
  ElevationTuning get tuning =>
      ElevationTuning.forVerticalAccuracy(_verticalAccuracyEstimate);

  /// How old a compass reading may be before it stops standing in for the GPS
  /// course.
  ///
  /// Generous, for the same reason the barometer's window is: a platform
  /// timestamp is not always the moment the reading was taken, and the compass
  /// arrives at several hertz, so seconds of slack costs nothing.
  static const Duration _compassStaleAfter = Duration(seconds: 5);

  /// How far out a reading may be and still be used, in degrees.
  ///
  /// Generous, because Android reports a quality band rather than a number and
  /// maps its `LOW` state to 30. Past this the magnetometer is next to
  /// something that has taken it over — a steel frame, a magnetic mount, a
  /// speaker — and it is worth less than the stale GPS course it would
  /// replace.
  static const double _maxCompassAccuracyDegrees = 40;

  /// Relates the compass frame to the GPS one, from a course that has just
  /// arrived.
  ///
  /// **Only ever called from a fix that carried a course, and that is
  /// load-bearing.** The obvious generalisation — also updating it whenever a
  /// compass reading arrives, using the last course seen — is wrong in a way
  /// that is easy to miss: while the rider is stopped the last course stays
  /// recent for seconds, so every reading taken while they turn the bars would
  /// look like the *frame* had moved and would be folded into the anchor,
  /// cancelling the very turn the compass exists to show. The anchor describes
  /// how the phone is mounted, which is a property of the ride, not of the
  /// moment.
  ///
  /// The window on `seenAt` is why the anchor needs a compass that is already
  /// reporting when the first course arrives — which it is, because both
  /// streams are subscribed when the ride starts and a course needs a metre or
  /// two of travel. A compass that appears mid-ride simply anchors at the next
  /// course.
  ///
  /// The result is smoothed, because the GPS course is derived from positions
  /// and so lags the true heading through a corner. An anchor that chased it
  /// frame by frame would swing with every turn.
  void _anchorCompass(double gpsCourse, DateTime at) {
    final heading = _compassHeading;
    final seenAt = _compassAt;
    if (heading == null || seenAt == null) return;
    if (!_compassTrustworthy) return;
    if (at.difference(seenAt).abs() > _compassStaleAfter) return;

    final delta = signedTurnAngle(heading, gpsCourse);
    final previous = _compassAnchor;
    _compassAnchor = previous == null
        ? delta
        : previous + signedTurnAngle(previous, delta) * 0.2;
  }

  /// The compass expressed as a heading, or null when it cannot be.
  double? _compassStandIn(DateTime at) {
    final heading = _compassHeading;
    final seenAt = _compassAt;
    final anchor = _compassAnchor;
    if (heading == null || seenAt == null || anchor == null) return null;
    if (!_compassTrustworthy) return null;
    if (at.difference(seenAt).abs() > _compassStaleAfter) return null;
    return normalizeBearing(heading + anchor);
  }

  /// Whether the last compass reading was one the platform stood behind.
  ///
  /// Null accuracy means the platform declined to quantify it, which is not
  /// the same as a bad reading and is treated as usable.
  bool get _compassTrustworthy {
    final accuracy = _compassAccuracy;
    return accuracy == null || accuracy <= _maxCompassAccuracyDegrees;
  }

  /// Whether the last accepted fix carried a usable course of its own.
  ///
  /// Both platforms follow `Location.hasBearing()`: the field is simply absent
  /// when the receiver cannot say, which is the stationary case. So this is
  /// the platform's own answer to "is there a course right now", not a guess
  /// reconstructed from speed.
  bool _lastFixHadCourse = false;

  double? _smoothBearing(
    double? reported,
    double fromLat,
    double fromLng,
    double toLat,
    double toLng,
    DateTime at,
  ) {
    final moved = haversineMeters(fromLat, fromLng, toLat, toLng);
    final gpsCourse = (moved >= 3.0 && reported == null)
        ? initialBearingDegrees(fromLat, fromLng, toLat, toLng)
        : reported;
    _lastFixHadCourse = gpsCourse != null;

    if (gpsCourse == null) {
      // Nothing the receiver can say about direction right now. That is not a
      // rare state: a derived course needs three metres of travel between
      // fixes, which at 1 Hz is 10.8 km/h — so on a climb at 8 km/h, at every
      // junction, and for the first seconds of a ride, the receiver's answer
      // is stale. The compass is the only real direction available here, and
      // this is the entire reason it is wired in.
      final standIn = _compassStandIn(at);
      if (standIn == null) return _bearing;
      return _foldBearing(standIn);
    }

    // The GPS course is the direction of travel, which is what a bike computer
    // is asked for — so it stays the authority for as long as it exists, and
    // the compass is only ever a stand-in for its absence.
    _anchorCompass(gpsCourse, at);
    return _foldBearing(gpsCourse);
  }

  /// Smooths [heading] into the published bearing.
  ///
  /// Circular, because interpolating naively across 359°/1° would swing the
  /// arrow the long way round.
  double _foldBearing(double heading) {
    final previous = _bearing;
    if (previous == null) return _bearing = normalizeBearing(heading);

    final delta = signedTurnAngle(previous, heading);
    return _bearing = normalizeBearing(previous + delta * 0.3);
  }

  /// Folds in a compass reading immediately, with no fix to carry it.
  ///
  /// The reason this exists as well as [_smoothBearing]: a reading that can
  /// only take effect on the next fix is a reading that arrives up to five
  /// seconds late at the frugal profile — and the case the compass is for is
  /// the rider stopped at a junction, turning the bars, waiting for a direction
  /// the receiver has no intention of giving.
  ///
  /// Does nothing while the receiver is producing a course. At speed the
  /// compass has nothing to add and would only put noise on a good answer.
  double? advanceBearingFromCompass(DateTime at) {
    if (_lastFixHadCourse) return _bearing;
    final standIn = _compassStandIn(at);
    if (standIn == null) return _bearing;
    return _foldBearing(standIn);
  }

  /// Resets all state, e.g. after a long pause or a crash resume.
  void reset() {
    _lastAccepted = null;
    _smoothedSpeed = null;
    _resetZeroSpeedConflict();
    _smoothedGpsAltitude = null;
    _bearing = null;
    _gradeWindow.clear();
    _gradeWindowDistance = 0;
    poorAccuracyStreak = 0;
    totalFixes = 0;
    rejectedFixes = 0;

    // The next ride gets a fresh barometric baseline: a new stream zeroes on
    // its own first sample.
    _smoothedBaroAltitude = null;
    _lastBaroAt = null;

    // Likewise the compass: the anchor describes how this phone was mounted on
    // that ride, and carrying it into the next one would apply one mounting
    // angle to another.
    _compassHeading = null;
    _compassAt = null;
    _compassAccuracy = null;
    _compassAnchor = null;
    _lastFixHadCourse = false;

    // The accuracy estimate is deliberately *not* cleared: it describes the
    // receiver, which has not changed, and discarding it would re-tighten the
    // elevation tuning to the pessimistic default for the next few minutes.
    // What it cannot keep is a barometer's pin — that described the *source*,
    // and this filter may not see one again.
    _verticalAccuracyEstimate = _lastGpsVerticalAccuracy;
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
    _resetZeroSpeedConflict();
    _smoothedGpsAltitude = smoothedAltitude;
    _gradeWindow.clear();
    _gradeWindowDistance = 0;
    if (smoothedAltitude != null) {
      _gradeWindow.add((distance: 0, altitude: smoothedAltitude));
    }
  }

  /// Fraction of samples rejected, `0..1`, for the GPS quality indicator.
  double get rejectionRatio => totalFixes == 0 ? 0 : rejectedFixes / totalFixes;
}
