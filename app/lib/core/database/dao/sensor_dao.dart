import 'package:drift/drift.dart';

import '../../../features/sensors/domain/sensor.dart';
import '../database.dart';

part 'sensor_dao.g.dart';

@DriftAccessor(tables: [PairedSensors])
class SensorDao extends DatabaseAccessor<AppDatabase> with _$SensorDaoMixin {
  SensorDao(super.db);

  Future<List<PairedSensor>> all() async {
    final rows = await select(pairedSensors).get();
    return rows.map(_toDomain).nonNulls.toList();
  }

  Stream<List<PairedSensor>> watchAll() => select(pairedSensors)
      .watch()
      .map((rows) => rows.map(_toDomain).nonNulls.toList());

  /// Returns null for a row whose type this build no longer recognises — a
  /// downgrade should not crash the settings screen.
  PairedSensor? _toDomain(PairedSensorRow row) {
    final type = SensorType.fromId(row.type);
    if (type == null) return null;
    return PairedSensor(
      id: row.id,
      name: row.name,
      type: type,
      enabled: row.enabled,
      lastConnectedAt: row.lastConnectedAt?.toUtc(),
    );
  }

  Future<void> upsert(PairedSensor sensor) async {
    await into(pairedSensors).insertOnConflictUpdate(
      PairedSensorsCompanion.insert(
        id: sensor.id,
        name: sensor.name,
        type: sensor.type.id,
        enabled: Value(sensor.enabled),
        lastConnectedAt: Value(sensor.lastConnectedAt?.toUtc()),
      ),
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await (update(pairedSensors)..where((t) => t.id.equals(id)))
        .write(PairedSensorsCompanion(enabled: Value(enabled)));
  }

  Future<void> forget(String id) async {
    await (delete(pairedSensors)..where((t) => t.id.equals(id))).go();
  }

  Future<void> markConnected(String id) async {
    await (update(pairedSensors)..where((t) => t.id.equals(id))).write(
      PairedSensorsCompanion(
        lastConnectedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }
}
