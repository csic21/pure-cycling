import 'package:drift/drift.dart';

/// Completed and in-progress rides.
///
/// This is the local source of truth. Every field here mirrors the Postgres
/// `rides` table so an upload is a straight projection, but the two are
/// independent: the cloud copy is a backup, never a prerequisite.
@DataClassName('LocalRide')
class LocalRides extends Table {
  /// Null means unassigned local data; only explicit consent may bind it.
  TextColumn get ownerUserId => text().nullable()();
  TextColumn get id => text()();

  TextColumn get name => text().nullable()();

  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();

  IntColumn get elapsedSeconds => integer().withDefault(const Constant(0))();
  IntColumn get movingSeconds => integer().withDefault(const Constant(0))();

  RealColumn get distanceMeters => real().withDefault(const Constant(0))();
  RealColumn get avgSpeedMps => real().nullable()();
  RealColumn get maxSpeedMps => real().nullable()();
  RealColumn get elevationGainMeters => real().nullable()();
  RealColumn get elevationLossMeters => real().nullable()();

  RealColumn get startLat => real().nullable()();
  RealColumn get startLng => real().nullable()();
  RealColumn get endLat => real().nullable()();
  RealColumn get endLng => real().nullable()();

  /// WKT `LINESTRING`, built once at ride end. Uploaded in place of
  /// per-point rows (see spec §23).
  TextColumn get routeGeometryWkt => text().nullable()();

  TextColumn get gpxPath => text().nullable()();
  TextColumn get fitPath => text().nullable()();

  TextColumn get syncStatus =>
      text().withDefault(const Constant('local_only'))();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();

  TextColumn get notes => text().nullable()();
  TextColumn get bikeId => text().nullable()();

  /// Tombstone. Rows are never hard-deleted locally so an offline device
  /// cannot re-upload a ride the user removed elsewhere.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The raw GPS trace.
///
/// Written at ~1 Hz for the whole ride; a four-hour ride is ~15k rows. Kept
/// out of the cloud by design.
@DataClassName('TrackPointRow')
class TrackPoints extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get rideId =>
      text().references(LocalRides, #id, onDelete: KeyAction.cascade)();

  /// Monotonic index within the ride.
  IntColumn get sequence => integer()();

  /// Milliseconds since epoch, UTC. Stored as an int rather than a datetime
  /// column so millisecond precision survives — sub-second deltas matter for
  /// speed and for detecting timestamp regressions.
  IntColumn get timestampMs => integer()();

  RealColumn get lat => real()();
  RealColumn get lng => real()();

  RealColumn get altitude => real().nullable()();
  RealColumn get speed => real().nullable()();
  RealColumn get bearing => real().nullable()();
  RealColumn get horizontalAccuracy => real().nullable()();
  RealColumn get verticalAccuracy => real().nullable()();

  IntColumn get heartRate => integer().nullable()();
  IntColumn get cadence => integer().nullable()();
  IntColumn get power => integer().nullable()();
}

/// Routes the user planned or imported.
@DataClassName('SavedRouteRow')
class SavedRoutes extends Table {
  TextColumn get ownerUserId => text().nullable()();
  TextColumn get id => text()();

  TextColumn get name => text()();

  RealColumn get distanceMeters => real().withDefault(const Constant(0))();
  IntColumn get estimatedSeconds => integer().withDefault(const Constant(0))();
  RealColumn get elevationGainMeters => real().nullable()();

  /// JSON array of `[lat, lng]` pairs. A compact, dependency-free encoding:
  /// a 100 km route is a few thousand pairs and ~40 KB of text.
  TextColumn get geometryJson => text()();

  TextColumn get instructionsJson =>
      text().withDefault(const Constant('[]'))();

  TextColumn get provider => text().withDefault(const Constant('local'))();
  TextColumn get providerRouteId => text().nullable()();

  BoolColumn get favorite => boolean().withDefault(const Constant(false))();

  TextColumn get syncStatus =>
      text().withDefault(const Constant('local_only'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Durable outbox. Survives restarts; drained whenever the network allows.
@DataClassName('SyncQueueRow')
class SyncQueueItems extends Table {
  TextColumn get ownerUserId => text().nullable()();
  IntColumn get id => integer().autoIncrement()();

  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();

  /// One pending operation per entity: re-editing a ride replaces the queued
  /// upsert rather than stacking a second one.
  @override
  List<Set<Column>> get uniqueKeys => [
        {entityType, entityId, operation},
      ];
}

/// Key/value application settings.
///
/// A KV table rather than a single wide row: new settings can ship without a
/// migration, and an unknown key can be safely ignored by an older build.
@DataClassName('AppSettingRow')
class AppSettingsEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}

/// BLE sensors the user has paired.
@DataClassName('PairedSensorRow')
class PairedSensors extends Table {
  /// Platform-assigned device identifier (iOS UUID / Android MAC).
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// `heartRate` | `cadence` | `speed` | `power`.
  TextColumn get type => text()();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  DateTimeColumn get lastConnectedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Crash-recovery checkpoint for the ride in progress.
///
/// Written every few seconds while riding. If the process dies — a crash, an
/// OS kill, a battery pull — the next launch finds this row and offers to
/// resume rather than silently losing the whole ride.
@DataClassName('ActiveRideCheckpointRow')
class ActiveRideCheckpoints extends Table {
  TextColumn get rideId => text()();

  /// `RideStatus` name at the moment of the checkpoint.
  TextColumn get status => text()();

  DateTimeColumn get startedAt => dateTime()();

  IntColumn get elapsedSeconds => integer().withDefault(const Constant(0))();
  IntColumn get movingSeconds => integer().withDefault(const Constant(0))();

  RealColumn get distanceMeters => real().withDefault(const Constant(0))();
  RealColumn get maxSpeedMps => real().withDefault(const Constant(0))();
  RealColumn get elevationGainMeters => real().withDefault(const Constant(0))();
  RealColumn get elevationLossMeters => real().withDefault(const Constant(0))();

  RealColumn get lastLat => real().nullable()();
  RealColumn get lastLng => real().nullable()();
  RealColumn get lastAltitude => real().nullable()();
  IntColumn get lastSequence => integer().withDefault(const Constant(0))();

  RealColumn get smoothedAltitudeMeters => real().nullable()();
  RealColumn get smoothedSpeedMps => real().withDefault(const Constant(0))();

  /// Accumulated moving distance is already in [distanceMeters]; the anchor
  /// point is stored separately so distance can resume without a gap.
  RealColumn get anchorLat => real().nullable()();
  RealColumn get anchorLng => real().nullable()();
  IntColumn get anchorTimestampMs => integer().nullable()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {rideId};
}
