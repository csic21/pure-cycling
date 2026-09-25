import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/database/dao/active_ride_dao.dart';
import '../../../core/database/database.dart';
import '../../../core/location/barometer_source.dart';
import '../../../core/location/gps_filter.dart';
import '../../../core/location/location_fix.dart';
import '../../../core/location/location_service.dart';
import '../../../core/location/sampling_policy.dart';
import '../../../core/utils/geo.dart';
import '../../sensors/domain/sensor.dart';
import '../../settings/domain/app_settings.dart';
import '../domain/ride.dart';
import '../domain/ride_engine.dart';
import '../domain/track_point.dart';
import 'ride_repository.dart';

/// How many points are held in memory before being written.
///
/// At 1 Hz this is ten seconds of trace. Buffering turns 3,600 individual
/// transactions per hour into 360 batched ones, which is a meaningful
/// difference in flash wear and battery, and the checkpoint written alongside
/// each flush caps what a crash can cost at the same ten seconds.
const int _flushEveryPoints = 10;

/// Orchestrates a ride: owns the engine, drives it from GPS and sensors, and
/// is the only place that writes to storage.
///
/// The split matters. [RideEngine] is pure computation with no I/O, so it can
/// be tested against synthetic fixes; everything that can fail — the location
/// permission, the database, the file system, the network — lives here, where
/// failures can be handled without the recording logic knowing about them.
class RideRecorder {
  RideRecorder({
    required AppDatabase db,
    required RideRepository repository,
    required LocationService locationService,
    ActiveRideDao? activeRideDao,
    Stream<SensorReading>? sensorReadings,
    BarometerSource? barometer,
    SamplingPolicy? samplingPolicy,
  })  : _db = db,
        _repository = repository,
        _location = locationService,
        _activeRideDao = activeRideDao ?? db.activeRideDao,
        _sensorReadings = sensorReadings,
        _barometer = barometer,
        _sampling = samplingPolicy ??
            SamplingPolicy(chosen: const AppSettings().gpsAccuracy);

  final AppDatabase _db;
  final RideRepository _repository;
  final LocationService _location;
  final ActiveRideDao _activeRideDao;

  /// Normalized heart rate / cadence / power / wheel-speed readings, when the
  /// app has a sensor manager to ask.
  ///
  /// Injected as a stream rather than as the manager itself so this class —
  /// the one that owns the engine — stays testable without a Bluetooth stack,
  /// and so a test can feed a reading directly.
  final Stream<SensorReading>? _sensorReadings;

  /// The phone's own barometer, when it has one.
  ///
  /// Injected rather than constructed so a test can feed a synthetic climb
  /// through the whole pipeline without a device — which is the only way to
  /// check that the elevation arithmetic is right before standing on a hill.
  final BarometerSource? _barometer;

  /// How often the platform is asked for a fix, which is not always what the
  /// rider chose — see [SamplingPolicy].
  final SamplingPolicy _sampling;

  /// The profile the current subscription was opened with, so a change is a
  /// re-subscription and nothing else is.
  GpsAccuracyMode? _requestedMode;

  RideEngine? _engine;
  StreamSubscription<LocationFix>? _locationSub;
  StreamSubscription<SensorReading>? _sensorSub;
  StreamSubscription<BarometerSample>? _barometerSub;
  final _pending = <TrackPoint>[];
  bool _disposed = false;

  /// The trace so far, for the live map.
  ///
  /// Held in memory and appended to rather than re-queried from SQLite: the
  /// map redraws every frame and a query per frame would be absurd, and the
  /// database only sees a write every ten points. Reading the table would
  /// therefore show a line that lags reality by five seconds — which reads as
  /// a broken map, not as a batched writer.
  final List<GeoPoint> _liveTrace = [];

  /// Bumped when [_liveTrace] grows. A counter rather than a new list so
  /// publishing costs nothing and the map can rebuild without copying
  /// thousands of coordinates.
  final ValueNotifier<int> traceRevision = ValueNotifier<int>(0);

  /// The recorded trace, oldest first. Do not mutate.
  List<GeoPoint> get liveTrace => _liveTrace;

  /// Broadcast of the current ride state. Survives individual rides: the
  /// engine is rebuilt per ride, this stream is not.
  final _stateController = StreamController<RideState>.broadcast();
  Stream<RideState> get states => _stateController.stream;

  RideState get state => _engine?.state ?? const RideState();

  RideEngine? get engine => _engine;

  /// Set when the last fix could not be obtained; surfaced on the home screen
  /// so the rider knows why the start button is warning.
  LocationPermissionStatus? lastPermissionStatus;

  // ---- Lifecycle ----

  /// Configures and starts a new ride.
  ///
  /// Returns false when location permission is missing — the caller is
  /// expected to surface the reason rather than silently doing nothing.
  Future<bool> startRide(AppSettings settings) async {
    _sampling.setChosen(settings.gpsAccuracy);

    final permission = await _location.ensurePermission();
    lastPermissionStatus = permission;
    if (!permission.isUsable) return false;

    await _teardownEngine();

    final engine = RideEngine(
      config: _engineConfig(settings),
      onTrackPoint: _onTrackPoint,
      onCheckpoint: _onCheckpoint,
    );
    _engine = engine;
    _pending.clear();

    _liveTrace.clear();

    traceRevision.value++;

    // Subscribe *before* starting. `RideEngine.states` is a broadcast stream
    // with no replay, so a listener attached afterwards never sees the
    // `preparing` state that `start()` publishes — and the ride screen, still
    // reading `idle`, renders a dead dashboard with no countdown until the
    // first tick a second later.
    _forward(engine);
    await engine.start();

    // The parent row first. Track points carry a foreign key to it, and the
    // batched writer below runs from the first few seconds of the ride.
    await _repository.beginRide(
      id: engine.state.rideId!,
      startedAt: engine.state.startedAt ?? DateTime.now().toUtc(),
    );

    _subscribeLocation();
    _subscribeSensors();
    _subscribeBarometer();

    return true;
  }

  /// Restores an interrupted ride from its checkpoint (spec §42).
  Future<bool> resumeRide(RideCheckpoint checkpoint, AppSettings settings) async {
    _sampling.setChosen(settings.gpsAccuracy);

    final permission = await _location.ensurePermission();
    lastPermissionStatus = permission;
    if (!permission.isUsable) return false;

    await _teardownEngine();

    // The database is the authority on what was actually stored; the
    // checkpoint may lag it by one flush.
    final storedMax = await _maxStoredSequence(checkpoint.rideId);
    final resumeFrom = storedMax > checkpoint.lastSequence
        ? storedMax
        : checkpoint.lastSequence;

    final engine = RideEngine(
      config: _engineConfig(settings),
      onTrackPoint: _onTrackPoint,
      onCheckpoint: _onCheckpoint,
    );
    _engine = engine;
    _pending.clear();
    // The live trace starts empty on resume: the earlier points are already in
    // the database and are loaded from there by the map, so re-adding them
    // here would draw the ride twice.
    _liveTrace.clear();
    traceRevision.value++;

    // Same ordering as `startRide`: subscribe first, so the restored state is
    // delivered rather than published into an empty room.
    _forward(engine);
    await engine.restoreFrom(checkpoint, resumeSequence: resumeFrom);

    // Same reasoning as `startRide`: the row has to exist before any point is
    // written against it.
    await _repository.beginRide(
      id: checkpoint.rideId,
      startedAt: checkpoint.startedAt,
    );

    _subscribeLocation();
    _subscribeSensors();
    _subscribeBarometer();

    return true;
  }

  Future<void> beginRecording() async => _engine?.beginRecording();

  void pause() => _engine?.pause();

  void resume() => _engine?.resume();

  /// Ends the ride, flushes everything, and persists the record.
  ///
  /// Returns the saved ride, or null if no ride was in progress.
  Future<Ride?> stopRide({String? name}) async {
    final engine = _engine;
    if (engine == null || !engine.isActive) return null;

    final ride = await engine.stop();
    await _activeRideDao.clear();
    await _cancelLocation();

    final toSave = name == null || name.trim().isEmpty
        ? ride
        : ride.copyWith(name: name.trim());

    // The buffer goes to the repository rather than being flushed here.
    // `saveFinishedRide` writes the ride row, then these points, then reads
    // the whole trace back to build the geometry — and flushing first would
    // insert points whose ride row is about to be rewritten, for no gain.
    final buffered = List<TrackPoint>.of(_pending);
    _pending.clear();

    await _repository.saveFinishedRide(toSave, unflushed: buffered);
    _pending.clear();
    _liveTrace.clear();
    traceRevision.value++;

    return await _repository.getRide(toSave.id) ?? toSave;
  }

  /// Throws away the ride in progress without saving it.
  ///
  /// Offered only for the "I started this by accident" case; the caller is
  /// responsible for confirming first.
  Future<void> discardRide() async {
    final rideId = _engine?.state.rideId;
    _engine?.cancel();
    _pending.clear();
    _liveTrace.clear();
    traceRevision.value++;
    await _activeRideDao.clear();
    await _cancelLocation();

    // The placeholder row `beginRide` created goes too. Leaving it would put a
    // zero-distance ride in the rider's history every time they tapped 开始骑行
    // and changed their mind.
    if (rideId != null) await _repository.purgeAbandonedRide(rideId);
  }

  /// Checks for a ride left behind by a crash or an OS kill.
  Future<RideCheckpoint?> findUnfinishedRide() =>
      _activeRideDao.loadUnfinished();

  Future<bool> hasUnfinishedRide() async =>
      (await _activeRideDao.loadUnfinished()) != null;

  /// Applies changed settings to a ride already in progress.
  void applySettings(AppSettings settings) {
    _engine?.applyConfig(_engineConfig(settings));

    // A rider who switches profile mid-ride gets it now, rather than at the
    // next ride. Nothing else about the subscription changes.
    _sampling.setChosen(settings.gpsAccuracy);
    _syncSamplingProfile();
  }

  /// Writes a checkpoint immediately. Called when the app is backgrounded or
  /// about to be terminated, where the five-second cadence may not get a turn.
  Future<void> saveCheckpointNow() async {
    final engine = _engine;
    if (engine == null || !engine.isActive) return;
    await _flushPoints();
    await _activeRideDao.save(engine.buildCheckpoint());
  }

  void onSensorReading(SensorReading reading) =>
      _engine?.onSensorReading(reading);

  Future<void> dispose() async {
    _disposed = true;
    await _teardownEngine();
    await _stateController.close();
  }

  // ---- Internals ----

  void _forward(RideEngine engine) {
    engine.states.listen((s) {
      if (_disposed) return;

      // One state per second is the policy's clock: it needs the smoothed
      // speed and nothing else, and the engine already decided what that is.
      if (_sampling.update(
        speedMps: s.stats.currentSpeedMps,
        at: DateTime.now().toUtc(),
      )) {
        _syncSamplingProfile();
      }

      _stateController.add(s);
    });
  }

  void _subscribeLocation() {
    final mode = _sampling.effective;
    _requestedMode = mode;
    _locationSub?.cancel();
    _locationSub = _location
        .fixes(mode: mode)
        .listen(
          (fix) => _engine?.onLocation(fix),
          onError: (_) {
            // A stream error is transient on both platforms; the platform
            // re-establishes on its own. Losing the subscription entirely is
            // the thing to avoid, so it is not cancelled here.
          },
          cancelOnError: false,
        );
  }

  Future<void> _cancelLocation() async {
    await _locationSub?.cancel();
    _locationSub = null;
    _requestedMode = null;
  }

  /// Re-opens the fix stream if the profile in force has changed.
  ///
  /// Re-subscribing is the only way to change a platform's sampling settings:
  /// they are part of the subscription. The engine keeps its state across it —
  /// the last accepted fix, the distance anchor, the smoothed speed — so the
  /// switch costs one interval's worth of resolution, not a segment of the
  /// ride.
  void _syncSamplingProfile() {
    if (_locationSub == null) return;
    if (_requestedMode == _sampling.effective) return;
    _subscribeLocation();
  }

  /// Attaches the sensor stream for the duration of a ride.
  ///
  /// Subscribed per ride rather than for the process: readings outside a ride
  /// have nowhere to go — the engine refuses them when it is not active — and
  /// a subscription held open across the whole session is one more thing
  /// keeping a disposed engine reachable.
  ///
  /// A sensor error is dropped rather than surfaced. A heart-rate strap that
  /// drops out mid-ride must not disturb a recording that is otherwise fine;
  /// the sensor screen already shows the connection state to the rider who
  /// cares about it.
  void _subscribeSensors() {
    final readings = _sensorReadings;
    if (readings == null) return;

    _sensorSub?.cancel();
    _sensorSub = readings.listen(
      onSensorReading,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _cancelSensors() async {
    await _sensorSub?.cancel();
    _sensorSub = null;
  }

  /// Attaches the barometer for the duration of a ride.
  ///
  /// Errors are the normal case on a device without one, and on iOS when the
  /// motion permission was refused: the altitude stays GPS-only, the climb
  /// figure stays labelled as an estimate, and nothing else notices.
  void _subscribeBarometer() {
    final source = _barometer;
    if (source == null) return;

    _barometerSub?.cancel();
    _barometerSub = source.samples().listen(
      (sample) {
        final relative = sample.relativeAltitudeMeters;
        if (relative != null) {
          _engine?.onBarometricAltitude(relative, at: sample.timestamp);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _cancelBarometer() async {
    await _barometerSub?.cancel();
    _barometerSub = null;
  }

  /// Stops the engine, then the location subscription.
  ///
  /// The order matters and is not obvious. `RideEngine.dispose` cancels its
  /// ticker and checkpoint timers *synchronously*, before its first `await` —
  /// but `_cancelLocation` yields to the event loop. Awaiting the location
  /// first therefore leaves the recording timers running across that
  /// suspension, which is long enough for a caller that is tearing the whole
  /// app down (a test binding checking for pending timers, an OS reclaiming a
  /// backgrounded process) to see a clock still ticking on a ride that is
  /// supposed to be gone.
  Future<void> _teardownEngine() async {
    final engine = _engine;
    _engine = null;

    final stopping = engine?.dispose();
    await _cancelLocation();
    await _cancelSensors();
    await _cancelBarometer();
    await stopping;
  }

  /// Buffers a validated point. Never fails — the engine's callback cannot
  /// return an error, and a rejected write here is retried at the next flush.
  void _onTrackPoint(TrackPoint point) {
    _pending.add(point);

    // 60,000 points is a sixteen-hour ride at 1 Hz — beyond any bicycle ride,
    // and about 2 MB of coordinates. The cap is a backstop against a runaway
    // process, not a limit anyone will reach.
    if (_liveTrace.length < 60000) {
      _liveTrace.add(point.geo);
      traceRevision.value++;
    }

    if (_pending.length >= _flushEveryPoints) {
      // Fire and forget: the next checkpoint will re-flush anything that did
      // not make it, and the ride is still in memory until stop.
      unawaited(_flushPoints());
    }
  }

  /// Flush-then-checkpoint. The order is the whole crash guarantee: the
  /// checkpoint records `lastSequence`, and if a point with that sequence were
  /// not yet on disk, a resume would skip it.
  void _onCheckpoint(RideCheckpoint checkpoint) {
    unawaited(() async {
      await _flushPoints();
      await _activeRideDao.save(checkpoint);
    }());
  }

  Future<void> _flushPoints() async {
    if (_pending.isEmpty) return;
    final batch = List<TrackPoint>.of(_pending);
    _pending.clear();
    try {
      await _db.rideDao.insertTrackPoints(batch);
    } catch (_) {
      // Put them back so the next flush retries, but cap the retry buffer so
      // a persistently failing disk cannot grow memory without bound.
      _pending.insertAll(0, batch);
      if (_pending.length > _flushEveryPoints * 6) {
        _pending.removeRange(0, _pending.length - _flushEveryPoints * 6);
      }
    }
  }

  Future<int> _maxStoredSequence(String rideId) async {
    final last = await _db.rideDao.lastTrackPoint(rideId);
    return last?.sequence ?? 0;
  }

  RideEngineConfig _engineConfig(AppSettings settings) => RideEngineConfig(
        filter: GpsFilterConfig(
          maxAccuracyMeters: settings.maxAcceptableAccuracyMeters,
          longGapSeconds: 120,
          gradeWindowMeters: 150,
        ),
        autoPauseEnabled: settings.autoPause,
        autoPauseSpeedKph: settings.autoPauseSpeedThresholdKph,
        autoPauseDelay: Duration(seconds: settings.autoPauseDelaySeconds),
        autoResumeSpeedKph: settings.autoResumeSpeedThresholdKph,
        autoResumeDelay: Duration(seconds: settings.autoResumeDelaySeconds),
        gpsSignalLostAfter: Duration(seconds: settings.gpsSignalLostSeconds),
      );
}
