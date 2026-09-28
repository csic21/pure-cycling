import 'dart:async';

import '../../../core/location/distance_calculator.dart';
import '../../../core/location/elevation_tuning.dart';
import '../../../core/location/gps_filter.dart';
import '../../../core/location/location_fix.dart';
import '../../../core/location/motion_detector.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/ids.dart';
import '../../sensors/domain/sensor.dart';
import 'auto_pause.dart';
import 'elevation_accumulator.dart';
import 'ride.dart';
import 'track_point.dart';

/// Lifecycle state of a ride (spec §30).
enum RideStatus {
  idle,
  preparing,
  riding,
  paused,
  finishing,
  finished;

  bool get isActive =>
      this == RideStatus.preparing ||
      this == RideStatus.riding ||
      this == RideStatus.paused;

  bool get countsTime =>
      this == RideStatus.riding || this == RideStatus.paused;
}

/// Live sensor values plus their ride averages.
class SensorSnapshot {
  const SensorSnapshot({
    this.heartRate,
    this.cadence,
    this.power,
    this.avgHeartRate,
    this.avgCadence,
    this.avgPower,
  });

  final int? heartRate;
  final int? avgHeartRate;
  final int? cadence;
  final int? avgCadence;
  final int? power;
  final int? avgPower;

  bool get hasAny => heartRate != null || cadence != null || power != null;
}

/// Everything the UI is allowed to know about the ride in progress.
///
/// The UI subscribes to this and nothing else (spec §30). No widget computes
/// distance, speed, or time for itself — that is how the map, the dashboard,
/// and the history list stay in agreement.
class RideState {
  const RideState({
    this.status = RideStatus.idle,
    this.rideId,
    this.startedAt,
    this.stats = RideStats.empty,
    this.gpsAccuracyMeters = 0,
    this.gpsSignalLost = false,
    this.gpsPoor = false,
    this.acceptedPointCount = 0,
    this.motionDetected,
    this.autoPaused = false,
    this.bearing,
    this.lastPoint,
    this.sensors = const SensorSnapshot(),
    this.error,
  });

  final RideStatus status;
  final String? rideId;
  final DateTime? startedAt;
  final RideStats stats;

  final double gpsAccuracyMeters;

  /// No fix has arrived for longer than the configured grace period.
  final bool gpsSignalLost;

  /// A fix is arriving, but it is too imprecise to trust for distance.
  final bool gpsPoor;

  final int acceptedPointCount;

  /// Whether the phone's accelerometer reports the bike moving.
  ///
  /// Null when there is no motion sensor, when its stream has gone quiet, or
  /// before it has said anything — and every consumer then falls back to GPS
  /// speed, which is what they used before this existed. That null state is
  /// the whole reason this is a `bool?` and not a `bool`: "I do not know" and
  /// "I know it is not moving" lead to different decisions.
  final bool? motionDetected;

  /// Paused by the auto-pause rule rather than by the rider. The UI
  /// distinguishes the two — one is a notification, the other is a command.
  final bool autoPaused;

  final double? bearing;
  final GeoPoint? lastPoint;
  final SensorSnapshot sensors;
  final String? error;

  bool get isRiding => status == RideStatus.riding;
  bool get isPaused => status == RideStatus.paused;
  bool get isPreparing => status == RideStatus.preparing;

  /// Whether the ride is recording in any sense — including auto-pause, which
  /// is a recorder state, not a stop.
  bool get isRecording => status.isActive;

  RideState copyWith({
    RideStatus? status,
    String? rideId,
    DateTime? startedAt,
    RideStats? stats,
    double? gpsAccuracyMeters,
    bool? gpsSignalLost,
    bool? gpsPoor,
    int? acceptedPointCount,
    bool? motionDetected,
    bool? autoPaused,
    double? bearing,
    GeoPoint? lastPoint,
    SensorSnapshot? sensors,
    String? error,
  }) {
    return RideState(
      status: status ?? this.status,
      rideId: rideId ?? this.rideId,
      startedAt: startedAt ?? this.startedAt,
      stats: stats ?? this.stats,
      gpsAccuracyMeters: gpsAccuracyMeters ?? this.gpsAccuracyMeters,
      gpsSignalLost: gpsSignalLost ?? this.gpsSignalLost,
      gpsPoor: gpsPoor ?? this.gpsPoor,
      acceptedPointCount: acceptedPointCount ?? this.acceptedPointCount,
      motionDetected: motionDetected ?? this.motionDetected,
      autoPaused: autoPaused ?? this.autoPaused,
      bearing: bearing ?? this.bearing,
      lastPoint: lastPoint ?? this.lastPoint,
      sensors: sensors ?? this.sensors,
      error: error ?? this.error,
    );
  }
}

/// Crash-recovery snapshot (spec §42).
class RideCheckpoint {
  const RideCheckpoint({
    required this.rideId,
    required this.status,
    required this.startedAt,
    required this.elapsed,
    required this.moving,
    required this.distanceMeters,
    required this.maxSpeedMps,
    required this.elevationGainMeters,
    required this.elevationLossMeters,
    required this.lastSequence,
    required this.smoothedSpeedMps,
    this.lastLat,
    this.lastLng,
    this.lastAltitude,
    this.smoothedAltitudeMeters,
    this.anchorLat,
    this.anchorLng,
    this.anchorTimestampMs,
  });

  final String rideId;

  /// Name of the [RideStatus] at checkpoint time.
  final String status;

  final DateTime startedAt;
  final Duration elapsed;
  final Duration moving;

  final double distanceMeters;
  final double maxSpeedMps;
  final double elevationGainMeters;
  final double elevationLossMeters;

  final double? lastLat;
  final double? lastLng;
  final double? lastAltitude;

  /// Sequence number of the last track point the engine emitted. The recorder
  /// guarantees points are flushed before this is written, so resuming from
  /// `lastSequence + 1` cannot collide.
  final int lastSequence;

  final double smoothedSpeedMps;
  final double? smoothedAltitudeMeters;

  /// Distance-calculator anchor, so the resumed ride does not invent a segment
  /// between where it stopped and where it restarted.
  final double? anchorLat;
  final double? anchorLng;
  final int? anchorTimestampMs;

  bool get resumable => lastSequence > 0;

  Duration ageFrom(DateTime now) => now.difference(startedAt);
}

/// Tunables for [RideEngine].
class RideEngineConfig {
  const RideEngineConfig({
    this.filter = const GpsFilterConfig(),
    this.autoPauseEnabled = true,
    this.autoPauseSpeedKph = 2.0,
    this.autoPauseDelay = const Duration(seconds: 5),
    this.autoResumeSpeedKph = 3.0,
    this.autoResumeDelay = const Duration(seconds: 2),
    this.checkpointInterval = const Duration(seconds: 5),
    this.gpsSignalLostAfter = const Duration(seconds: 15),
    this.preparingTimeout = const Duration(seconds: 20),
    this.tickInterval = const Duration(seconds: 1),
  });

  final GpsFilterConfig filter;

  final bool autoPauseEnabled;
  final double autoPauseSpeedKph;
  final Duration autoPauseDelay;
  final double autoResumeSpeedKph;
  final Duration autoResumeDelay;

  /// How often the crash-recovery checkpoint is written (spec §42: 5–10 s).
  final Duration checkpointInterval;

  /// How long without a fix before the UI reports the signal as lost.
  final Duration gpsSignalLostAfter;

  /// How long to wait for a first fix before offering to start anyway.
  ///
  /// The rider is never *blocked* by this — spec §4 is explicit that a weak
  /// signal warns but does not prevent starting.
  final Duration preparingTimeout;

  final Duration tickInterval;

  RideEngineConfig copyWith({
    GpsFilterConfig? filter,
    bool? autoPauseEnabled,
    Duration? checkpointInterval,
    Duration? gpsSignalLostAfter,
  }) =>
      RideEngineConfig(
        filter: filter ?? this.filter,
        autoPauseEnabled: autoPauseEnabled ?? this.autoPauseEnabled,
        autoPauseSpeedKph: autoPauseSpeedKph,
        autoPauseDelay: autoPauseDelay,
        autoResumeSpeedKph: autoResumeSpeedKph,
        autoResumeDelay: autoResumeDelay,
        checkpointInterval: checkpointInterval ?? this.checkpointInterval,
        gpsSignalLostAfter: gpsSignalLostAfter ?? this.gpsSignalLostAfter,
        preparingTimeout: preparingTimeout,
        tickInterval: tickInterval,
      );
}

/// Called for every validated track point, in order.
typedef TrackPointSink = void Function(TrackPoint point);

/// Called on the checkpoint cadence.
typedef CheckpointSink = void Function(RideCheckpoint checkpoint);

/// Called once when a ride finishes, with the final record.
typedef RideFinishedSink = void Function(Ride ride);

typedef NowProvider = DateTime Function();

/// The recording core.
///
/// Owns the whole pipeline — validation, smoothing, distance, timing — and
/// publishes a single immutable [RideState]. It has no Flutter, no database,
/// and no network dependency: persistence is pushed out through [TrackPointSink]
/// and [CheckpointSink], which makes the engine testable with synthetic fixes
/// and keeps the recording path incapable of blocking on I/O it does not own.
class RideEngine {
  RideEngine({
    RideEngineConfig config = const RideEngineConfig(),
    this.onTrackPoint,
    this.onCheckpoint,
    this.onRideFinished,
    NowProvider? now,
  })  : _config = config,
        _now = now ?? (() => DateTime.now().toUtc()) {
    _autoPause = AutoPauseController(
      enabled: config.autoPauseEnabled,
      pauseSpeedMps: config.autoPauseSpeedKph / 3.6,
      resumeSpeedMps: config.autoResumeSpeedKph / 3.6,
      pauseDelay: config.autoPauseDelay,
      resumeDelay: config.autoResumeDelay,
    );
  }

  RideEngineConfig _config;
  RideEngineConfig get config => _config;

  final NowProvider _now;
  final TrackPointSink? onTrackPoint;
  final CheckpointSink? onCheckpoint;
  final RideFinishedSink? onRideFinished;

  final _stateController = StreamController<RideState>.broadcast();

  /// Broadcast view of the ride. Late subscribers immediately receive the
  /// current state.
  Stream<RideState> get states => _stateController.stream;

  late AutoPauseController _autoPause;
  final _filter = GpsFilter();
  final _motion = MotionDetector();
  DateTime? _motionAt;
  final _distance = DistanceCalculator();
  final _elevation = ElevationAccumulator();

  final Map<SensorType, _RunningAverage> _averages = {};

  Timer? _ticker;
  Timer? _checkpointTimer;
  Timer? _preparingTimer;

  RideStatus _status = RideStatus.idle;
  String _rideId = '';
  DateTime? _startedAt;

  Duration _elapsed = Duration.zero;
  Duration _moving = Duration.zero;
  DateTime? _lastTick;

  double _maxSpeed = 0;
  int _sequence = 0;
  double _currentSpeed = 0;
  double? _grade;

  double _gpsAccuracy = 0;
  /// The timestamp the *platform* put on the last fix.
  ///
  /// The right clock for anything about continuity of position: the gap between
  /// two fixes, the distance anchor's time, the long-gap bridge. See
  /// [_lastFixArrivedAt] for why there is a second one.
  DateTime? _lastFixAt;

  /// When the last fix *reached the app*, by the process clock.
  ///
  /// Deliberately not the same thing as [_lastFixAt], and the difference is the
  /// whole reason both exist. "Has the signal gone?" is a question about
  /// whether updates are still arriving, and the platform's own timestamp
  /// answers a different one: how old the fix is. The two normally agree, and
  /// when they do not it is the platform's timestamp that lies —
  ///
  /// * **iOS hands over its cached location** the moment a stream opens, and a
  ///   re-subscription after a background spell therefore delivers a fix
  ///   stamped minutes ago. Judged by timestamp, that is indistinguishable from
  ///   silence, and the GPS indicator turns red seconds after the app started
  ///   listening again.
  /// * **A provider may replay a fix**, and some ROMs report GNSS time on a
  ///   clock that does not match the system one. Neither affects whether
  ///   updates are arriving.
  ///
  /// So the rider-facing signal indicator and the speed decay use this clock,
  /// and everything about position uses the other.
  DateTime? _lastFixArrivedAt;
  bool _gpsPoor = false;
  LocationFix? _lastAcceptedFix;

  int? _heartRate;
  int? _cadence;
  int? _power;

  /// `first GPS altitude − first barometric reading`, so that
  /// `anchor + relative` is an altitude. Null until both have been seen.
  double? _barometerAnchor;
  GeoPoint? _lastPoint;
  double? _bearing;

  RideState _state = const RideState();

  /// The most recent published state.
  RideState get state => _state;

  bool get isActive => _status.isActive;

  /// Begins a new ride and starts acquiring a fix.
  ///
  /// The engine enters [RideStatus.preparing] immediately so the UI can show
  /// the countdown; [beginRecording] moves it to [RideStatus.riding] once the
  /// rider is ready.
  Future<void> start({String? rideId}) async {
    if (_status.isActive) return;

    _resetInternal();
    _rideId = rideId ?? generateId();
    _startedAt = _now();
    _status = RideStatus.preparing;
    _lastTick = _startedAt;

    _startTicker();
    _startCheckpointTimer();

    // Never block the rider: after the timeout the ride starts regardless of
    // whether a fix has arrived (spec §4).
    _preparingTimer = Timer(_config.preparingTimeout, () {
      if (_status == RideStatus.preparing) beginRecording();
    });

    _publish(force: true);
  }

  /// Leaves [RideStatus.preparing] and starts counting.
  void beginRecording() {
    if (_status != RideStatus.preparing) return;
    _preparingTimer?.cancel();
    _preparingTimer = null;
    // Restart the wall clock at the moment recording actually begins, so the
    // countdown is not billed to the ride.
    final now = _now();
    _startedAt = now;
    _lastTick = now;
    _elapsed = Duration.zero;
    _moving = Duration.zero;
    _status = RideStatus.riding;
    _publish(force: true);
  }

  /// Manual pause. Auto-pause is suppressed while paused so the two cannot
  /// fight over the state.
  void pause() {
    if (_status != RideStatus.riding) return;
    _tick();
    _status = RideStatus.paused;
    _autoPause.suppress();
    _currentSpeed = 0;
    _publish(force: true);
  }

  void resume() {
    if (_status != RideStatus.paused) return;
    _lastTick = _now();
    _status = RideStatus.riding;
    _autoPause.reset();
    // Re-anchor: the rider is somewhere new, and the paused interval must not
    // be turned into a distance segment.
    _distance.seed(
      totalMeters: _distance.totalMeters,
      anchor: _lastPoint,
      anchorTime: _lastFixAt,
    );
    _publish(force: true);
  }

  /// Ends the ride and returns the final record.
  ///
  /// Persisting it is the caller's job — the engine has no database.
  Future<Ride> stop() async {
    if (!_status.isActive) {
      return _buildRide(endedAt: _now());
    }

    _tick();
    _status = RideStatus.finishing;
    _publish(force: true);

    _stopTimers();

    final ride = _buildRide(endedAt: _now());
    _status = RideStatus.finished;
    _publish(force: true);
    onRideFinished?.call(ride);
    return ride;
  }

  /// Discards the ride in progress without producing a record.
  void cancel() {
    _stopTimers();
    _resetInternal();
    _status = RideStatus.idle;
    _publish(force: true);
  }

  /// Feeds a raw position sample.
  void onLocation(LocationFix fix) {
    if (!_status.isActive) return;

    _lastFixAt = fix.timestamp;
    _lastFixArrivedAt = _now();
    if (fix.hasAccuracy) _gpsAccuracy = fix.accuracy;

    final processing = _filter.process(
      fix,
      cumulativeDistanceMeters: _distance.totalMeters,
    );

    if (!processing.accepted) {
      // Even a rejected sample refreshes the GPS indicator — the rider needs
      // to know a signal exists but is poor, which is different from silence.
      _gpsPoor = processing.rejection == FixRejection.accuracyTooPoor;
      _publish();
      return;
    }

    _gpsPoor = false;

    // Timing and speed update even while auto-paused: the rider is moving
    // slowly, and the resume rule needs a current speed to fire on.
    final speed = processing.speedMps ?? 0;

    final transition = _applyAutoPause(speed, _now());
    final isAutoPausing = transition.pausing;
    final isAutoResuming = transition.resuming;
    final autoPaused = _autoPause.isAutoPaused;

    _currentSpeed = speed;
    if (speed > _maxSpeed) _maxSpeed = speed;
    _grade = processing.gradePercent;
    _bearing = processing.bearing;
    _lastPoint = fix.geo;
    _firstPoint ??= fix.geo;
    _lastAcceptedFix = fix;

    // A track point is recorded while actually moving. Points collected
    // during an auto-pause are dropped: they are the GPS wandering around a
    // parked bicycle, and they would add length to the trace without adding
    // information.
    if (!autoPaused && !isAutoPausing) {
      // The accuracy is forwarded so the distance gate can widen for an
      // imprecise fix rather than treating it as if it were a good one.
      final added = _distance.add(
        fix.geo,
        fix.timestamp,
        accuracyMeters: fix.hasAccuracy ? fix.accuracy : null,
      );
      _filter.noteDistance(added);

      if (processing.altitudeMeters != null) {
        _applyElevationTuning();
        _elevation.add(processing.altitudeMeters!);
      }

      _sequence++;
      onTrackPoint?.call(
        TrackPoint(
          rideId: _rideId,
          sequence: _sequence,
          timestamp: fix.timestamp,
          lat: fix.latitude,
          lng: fix.longitude,
          altitude: processing.altitudeMeters,
          speed: speed,
          bearing: processing.bearing,
          horizontalAccuracy: fix.hasAccuracy ? fix.accuracy : null,
          // The accuracy of the altitude in the line above, which is the
          // barometer's when one is reporting — see `onBarometricAltitude`.
          verticalAccuracy: processing.altitudeAccuracyMeters,
          heartRate: _heartRate,
          cadence: _cadence,
          power: _power,
        ),
      );
    }

    _publish(force: isAutoPausing || isAutoResuming);
  }

  /// Feeds a barometric altitude, in metres above the first sample of the
  /// current stream.
  ///
  /// ## Why this is anchored rather than trusted
  ///
  /// A barometer measures pressure, and pressure at a given height changes
  /// with the weather — a phone has no way to know the local sea-level
  /// pressure, so the absolute height is unknowable. What it knows precisely
  /// is *change*: 0.1 m of resolution, and noise that does not drift the way
  /// GPS altitude does.
  ///
  /// So the shape comes from the barometer and the position from GPS: the
  /// anchor is `first GPS altitude − first relative reading`, and every
  /// reading is then an absolute altitude good to the GPS fix's own vertical
  /// error (tens of metres) in *value* but to about a metre in *change*. The
  /// climb total and the profile care only about the latter; the exported GPX
  /// carries the former, which is no worse than it was before a barometer
  /// existed.
  ///
  /// Before any GPS altitude exists there is nothing to anchor to, so samples
  /// are dropped rather than invented.
  void onBarometricAltitude(
    double relativeAltitudeMeters, {
    DateTime? at,
  }) {
    if (!_status.isActive) return;
    if (!relativeAltitudeMeters.isFinite) return;

    final timestamp = at ?? _now();

    if (_barometerAnchor == null) {
      final gpsAltitude = _filter.gpsSmoothedAltitude;
      if (gpsAltitude == null) return;
      _barometerAnchor = gpsAltitude - relativeAltitudeMeters;
    }

    final altitude = _barometerAnchor! + relativeAltitudeMeters;
    final firstSample = !_filter.barometerActive;
    _filter.onBarometricAltitude(altitude, at: timestamp);

    // Threshold and quality follow the new source; this may also re-seed the
    // accumulator if the threshold moved.
    _applyElevationTuning();

    // The series is fed here as well as from accepted fixes, and that is the
    // point of a barometer: it keeps measuring through a tunnel, under trees
    // and between two fixes, none of which stop a climb from happening. The
    // accumulator is a series processor, so samples from both paths interleave
    // correctly — a fix is just another sample.
    final smoothed = _filter.smoothedAltitude;
    if (smoothed == null) return;

    if (firstSample) {
      // The series just changed coordinate systems — GPS metres to barometric
      // metres, with an offset of however wrong the GPS altitude was. The
      // accumulator's running extremes are in the old system, so that offset
      // would be banked as terrain. Reseeding keeps the leg already measured
      // and re-anchors without inventing a climb.
      _elevation.reseed(smoothed);
    } else {
      _elevation.add(smoothed);
    }
  }

  /// How far the compass must move the bearing before it is worth publishing.
  ///
  /// The compass reports several times a second and [RideState] is the only
  /// channel the UI has (spec §30) — re-publishing the whole ride on every
  /// reading would be a state stream at several hertz to serve one widget.
  /// Four degrees is finer than the arrow can show and far finer than a
  /// handlebar-mounted phone can be read to.
  static const double _compassPublishDegrees = 4.0;

  /// Advances the auto-pause rule and applies the consequences of a change.
  ///
  /// Extracted from [onLocation] because two inputs move this now — a fix and
  /// a motion reading — and the consequence that matters, re-anchoring the
  /// distance so a pause is not drawn as a straight line, has to happen
  /// identically for both.
  ({bool pausing, bool resuming}) _applyAutoPause(
    double speedMps,
    DateTime now,
  ) {
    final wasAutoPaused = _autoPause.isAutoPaused;
    final autoPaused = _autoPause.update(
      speedMps,
      now,
      motionDetected: motionDetected,
    );
    final pausing = autoPaused && !wasAutoPaused;
    final resuming = !autoPaused && wasAutoPaused;

    if (resuming) {
      // Same reasoning as manual resume: do not draw a line across the pause.
      _distance.seed(
        totalMeters: _distance.totalMeters,
        anchor: _lastPoint,
        anchorTime: _lastFixAt,
      );
    }

    return (pausing: pausing, resuming: resuming);
  }

  /// How long after the last reading the motion sensor's answer stops counting.
  ///
  /// Past this the engine says "I do not know" rather than repeating a verdict
  /// that described a moment several seconds ago — a stopped stream would
  /// otherwise freeze auto-pause in whatever state it was in when the sensor
  /// died.
  static const Duration _motionStaleAfter = Duration(seconds: 3);

  /// The accelerometer's verdict, or null when there is nothing current to go
  /// on. See [RideState.motionDetected] for what null means downstream.
  bool? get motionDetected {
    final at = _motionAt;
    if (at == null) return null;
    if (_now().difference(at).abs() > _motionStaleAfter) return null;
    if (!_motion.hasReading) return null;
    return _motion.moving;
  }

  /// Feeds an accelerometer magnitude, in g.
  ///
  /// The verdict is deliberately weak, and consumers are expected to treat it
  /// that way: it may only ever *shorten a stop*, never start, continue or
  /// resume a ride. A phone can vibrate in a bag on a parked bike — an engine
  /// idling, a rack rattling — so "moving" is not evidence that the rider is
  /// riding. "Still" is much stronger evidence, and that is the direction the
  /// two consumers lean.
  void onMotionSample(double magnitudeG, {DateTime? at}) {
    if (!_status.isActive) return;
    if (!magnitudeG.isFinite) return;

    final stamp = at ?? _now();
    final wasMoving = _motion.moving;
    _motion.add(magnitudeG, stamp);
    _motionAt = stamp;

    // A motion reading can end a stop on its own, which is the point of
    // feeding it to the rule rather than only to the display.
    final transition = _applyAutoPause(_currentSpeed, stamp);
    if (transition.pausing || transition.resuming || _motion.moving != wasMoving) {
      _publish(force: transition.pausing || transition.resuming);
    }
  }

  /// Feeds the phone's compass, in degrees clockwise from north.
  ///
  /// Folded in immediately rather than on the next fix, because the case this
  /// exists for is a rider who has stopped and is turning the bars: at the
  /// frugal sampling profile the next fix is five seconds away, and when
  /// auto-paused the receiver has no course to give at all. See
  /// [GpsFilter.onCompassHeading] for why the reading is anchored to the GPS
  /// course rather than trusted on its own.
  void onCompassHeading(
    double degrees, {
    DateTime? at,
    double? accuracyDegrees,
  }) {
    if (!_status.isActive) return;
    if (!degrees.isFinite) return;

    final stamp = at ?? _now();
    _filter.onCompassHeading(
      degrees,
      at: stamp,
      accuracyDegrees: accuracyDegrees,
    );

    final previous = _bearing;
    final heading = _filter.advanceBearingFromCompass(stamp);
    if (heading == null || heading == previous) return;

    _bearing = heading;
    if (previous == null ||
        bearingDelta(previous, heading) >= _compassPublishDegrees) {
      _publish();
    }
  }

  /// Feeds a normalized sensor value.
  void onSensorReading(SensorReading reading) {
    if (!_status.isActive) return;

    switch (reading.type) {
      case SensorType.heartRate:
        final v = reading.heartRate;
        if (v != null && v > 0 && v < 260) {
          _heartRate = v;
          _avg(SensorType.heartRate).add(v.toDouble());
        }
      case SensorType.cadence:
        final v = reading.cadence;
        if (v != null && v >= 0 && v < 300) {
          _cadence = v;
          _avg(SensorType.cadence).add(v.toDouble());
        }
      case SensorType.power:
        final v = reading.power;
        if (v != null && v >= 0 && v < 3000) {
          _power = v;
          _avg(SensorType.power).add(v.toDouble());
        }
      case SensorType.speed:
        // A wheel sensor is more precise than GPS at low speed, and it keeps
        // working in a tunnel. Trust it only while the GPS is weak, so a
        // mis-calibrated wheel radius cannot corrupt a normal ride.
        final v = reading.speedMps;
        if (v != null && v >= 0 && v < _config.filter.maxSpeedMps) {
          if (_gpsPoor || _lastFixArrivedAt == null) {
            _currentSpeed = v;
            if (v > _maxSpeed) _maxSpeed = v;
          }
        }
    }

    _publish();
  }

  /// Restores an interrupted ride (spec §42).
  ///
  /// [resumeSequence] comes from the database rather than the checkpoint: the
  /// recorder flushes points before writing the checkpoint, but the database
  /// is the authority on what was actually stored.
  Future<void> restoreFrom(
    RideCheckpoint checkpoint, {
    required int resumeSequence,
  }) async {
    _resetInternal();

    _rideId = checkpoint.rideId;
    _startedAt = checkpoint.startedAt;
    _elapsed = checkpoint.elapsed;
    _moving = checkpoint.moving;
    _maxSpeed = checkpoint.maxSpeedMps;
    _sequence = resumeSequence;
    _status = RideStatus.paused;
    _lastTick = _now();

    _distance.seed(
      totalMeters: checkpoint.distanceMeters,
      anchor: (checkpoint.anchorLat != null && checkpoint.anchorLng != null)
          ? GeoPoint(checkpoint.anchorLat!, checkpoint.anchorLng!)
          : null,
      anchorTime: checkpoint.anchorTimestampMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              checkpoint.anchorTimestampMs!,
              isUtc: true,
            ),
    );

    _elevation.seed(
      gain: checkpoint.elevationGainMeters,
      loss: checkpoint.elevationLossMeters,
      referenceAltitude: checkpoint.smoothedAltitudeMeters,
    );

    if (checkpoint.lastLat != null && checkpoint.lastLng != null) {
      _lastPoint = GeoPoint(checkpoint.lastLat!, checkpoint.lastLng!);
    }

    _startTicker();
    _startCheckpointTimer();
    _publish(force: true);
  }

  /// Keeps the climb threshold in step with how good the altitude source
  /// actually is.
  ///
  /// A barometer and a bare GPS receiver need thresholds an order of magnitude
  /// apart — 2 m versus 20 m. Using the barometer number on a GPS-only phone
  /// reports tens of metres of phantom climbing on a flat ride; using the GPS
  /// number on a barometer would throw away every real rise under 20 m.
  ///
  /// The change is rare — once or twice per ride, as the receiver settles or
  /// the rider leaves a canyon — and re-seeding the reference on each change
  /// keeps the switch itself from creating or destroying gain.
  void _applyElevationTuning() {
    final tuning = _filter.tuning;

    // The label follows the tuning whether or not the threshold moved: a
    // source can change quality without changing bucket, and a stale 「估算」
    // on a measured climb is the kind of wrong that erodes trust in every
    // other number on the screen.
    _elevationQuality = tuning.quality;

    if (tuning.gainThresholdMeters == _elevation.thresholdMeters) return;

    _elevation.thresholdMeters = tuning.gainThresholdMeters;

    final altitude = _filter.smoothedAltitude;
    if (altitude != null) _elevation.reseed(altitude);
  }

  /// How reliable this ride's elevation figures are.
  ///
  /// Surfaced so the UI can label the climb total as an estimate on a phone
  /// without a barometer, rather than presenting a number it cannot stand
  /// behind.
  ElevationQuality get elevationQuality => _elevationQuality;

  ElevationQuality _elevationQuality = ElevationQuality.approximate;

  /// Applies settings changes mid-ride.
  ///
  /// Changing auto-pause while riding must not restart the recording, so only
  /// the affected sub-controllers are rebuilt.
  void applyConfig(RideEngineConfig next) {
    _config = next;
    _filter.config = next.filter;
    _autoPause = AutoPauseController(
      enabled: next.autoPauseEnabled,
      pauseSpeedMps: next.autoPauseSpeedKph / 3.6,
      resumeSpeedMps: next.autoResumeSpeedKph / 3.6,
      pauseDelay: next.autoPauseDelay,
      resumeDelay: next.autoResumeDelay,
    );
  }

  Future<void> dispose() async {
    _stopTimers();
    await _stateController.close();
  }

  // ---- internals ----

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_config.tickInterval, (_) => _tick());
  }

  void _startCheckpointTimer() {
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer.periodic(
      _config.checkpointInterval,
      (_) => _writeCheckpoint(),
    );
  }

  void _stopTimers() {
    _ticker?.cancel();
    _ticker = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _preparingTimer?.cancel();
    _preparingTimer = null;
  }

  /// Advances the clocks.
  ///
  /// Time is derived from wall-clock deltas rather than by counting ticks, so
  /// a delayed or coalesced timer does not silently lose seconds — and so the
  /// clock keeps running while the phone is in a pocket with the screen off.
  void _tick() {
    if (!_status.countsTime) return;
    final now = _now();
    final last = _lastTick ?? now;
    final dt = now.difference(last);
    if (dt <= Duration.zero) return;
    _lastTick = now;

    _elapsed += dt;
    if (_status == RideStatus.riding && !_autoPause.isAutoPaused) {
      _moving += dt;
    }

    // The arrival clock, not the platform's: a replayed or cached fix is not
    // evidence that updates are arriving, and one is not evidence that the
    // receiver has gone quiet either.
    final fixAge =
        _lastFixArrivedAt == null ? null : now.difference(_lastFixArrivedAt!);
    if (fixAge != null && fixAge > _config.gpsSignalLostAfter) {
      // No fix for a while: decay the displayed speed to zero rather than
      // freezing it at the last value, which would look like the app had hung.
      _currentSpeed = _currentSpeed * 0.5 < 0.3 ? 0 : _currentSpeed * 0.5;
    }

    _publish();
  }

  void _writeCheckpoint() {
    if (!_status.isActive || _sequence == 0) return;
    onCheckpoint?.call(buildCheckpoint());
  }

  /// Current checkpoint state, also exposed for tests and for an explicit
  /// save before the app is backgrounded or terminated.
  RideCheckpoint buildCheckpoint() => RideCheckpoint(
        rideId: _rideId,
        status: _status.name,
        startedAt: _startedAt ?? _now(),
        elapsed: _elapsed,
        moving: _moving,
        distanceMeters: _distance.totalMeters,
        maxSpeedMps: _maxSpeed,
        elevationGainMeters: _elevation.gainMeters,
        elevationLossMeters: _elevation.lossMeters,
        lastLat: _lastPoint?.lat,
        lastLng: _lastPoint?.lng,
        lastAltitude: _lastAcceptedFix?.altitude,
        lastSequence: _sequence,
        smoothedSpeedMps: _currentSpeed,
        smoothedAltitudeMeters: _filter.smoothedAltitude,
        anchorLat: _distance.anchor?.lat,
        anchorLng: _distance.anchor?.lng,
        anchorTimestampMs:
            _distance.anchorTime?.millisecondsSinceEpoch,
      );

  Ride _buildRide({required DateTime endedAt}) => Ride(
        id: _rideId,
        startedAt: _startedAt ?? endedAt,
        endedAt: endedAt,
        stats: _buildStats(),
        startPoint: _firstPoint,
        endPoint: _lastPoint,
      );

  GeoPoint? _firstPoint;

  RideStats _buildStats() => RideStats(
        distanceMeters: _distance.totalMeters,
        elapsed: _elapsed,
        moving: _moving,
        currentSpeedMps: _status.isActive ? _currentSpeed : 0,
        avgSpeedMps:
            RideStats.computeAvgSpeed(_distance.totalMeters, _moving),
        maxSpeedMps: _maxSpeed,
        altitudeMeters: _filter.smoothedAltitude ?? 0,
        elevationGainMeters: _elevation.gainMeters,
        elevationLossMeters: _elevation.lossMeters,
        gradePercent: _grade ?? 0,
        heartRate: _heartRate,
        avgHeartRate: _avg(SensorType.heartRate).rounded,
        cadence: _cadence,
        avgCadence: _avg(SensorType.cadence).rounded,
        power: _power,
        avgPower: _avg(SensorType.power).rounded,
      );

  _RunningAverage _avg(SensorType type) =>
      _averages.putIfAbsent(type, _RunningAverage.new);

  void _publish({bool force = false}) {
    if (_stateController.isClosed) return;
    _state = RideState(
      status: _status,
      rideId: _rideId.isEmpty ? null : _rideId,
      startedAt: _startedAt,
      stats: _buildStats(),
      gpsAccuracyMeters: _gpsAccuracy,
      gpsSignalLost: _status.isActive &&
          _lastFixArrivedAt != null &&
          _now().difference(_lastFixArrivedAt!) >
              _config.gpsSignalLostAfter,
      gpsPoor: _gpsPoor,
      acceptedPointCount: _sequence,
      motionDetected: motionDetected,
      autoPaused: _autoPause.isAutoPaused,
      bearing: _bearing,
      lastPoint: _lastPoint,
      sensors: SensorSnapshot(
        heartRate: _heartRate,
        avgHeartRate: _avg(SensorType.heartRate).rounded,
        cadence: _cadence,
        avgCadence: _avg(SensorType.cadence).rounded,
        power: _power,
        avgPower: _avg(SensorType.power).rounded,
      ),
    );
    _stateController.add(_state);
  }

  void _resetInternal() {
    _filter.reset();
    _distance.reset();
    _elevation.reset();
    _barometerAnchor = null;
    _averages.clear();
    _status = RideStatus.idle;
    _rideId = '';
    _startedAt = null;
    _elapsed = Duration.zero;
    _moving = Duration.zero;
    _lastTick = null;
    _maxSpeed = 0;
    _sequence = 0;
    _currentSpeed = 0;
    _grade = null;
    _gpsAccuracy = 0;
    _lastFixAt = null;
    _lastFixArrivedAt = null;
    _gpsPoor = false;
    _lastAcceptedFix = null;
    _heartRate = null;
    _cadence = null;
    _power = null;
    _lastPoint = null;
    _firstPoint = null;
    _bearing = null;
    _motionAt = null;
    _motion.reset();
    _autoPause.reset();
  }

}

/// Mean of samples seen so far, or null before the first one.
class _RunningAverage {
  double _sum = 0;
  int _count = 0;

  void add(double value) {
    // Reject non-finite values up front: one NaN would poison the sum for the
    // rest of the ride.
    if (!value.isFinite) return;
    _sum += value;
    _count++;
  }

  int? get rounded => _count == 0 ? null : (_sum / _count).round();

  void reset() {
    _sum = 0;
    _count = 0;
  }
}
