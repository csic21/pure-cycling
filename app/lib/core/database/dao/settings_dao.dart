import 'package:drift/drift.dart';

import '../../../features/settings/domain/app_settings.dart';
import '../database.dart';

part 'settings_dao.g.dart';

/// Key/value settings storage.
///
/// Reads return the whole row set at once — it is a few dozen tiny rows, and
/// reading them together guarantees the app never observes a settings object
/// assembled from two different points in time.
@DriftAccessor(tables: [AppSettingsEntries])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(super.db);

  Future<Map<String, String>> readAll() async {
    final rows = await select(appSettingsEntries).get();
    return {for (final r in rows) r.key: r.value};
  }

  Stream<Map<String, String>> watchAll() {
    return select(appSettingsEntries)
        .watch()
        .map((rows) => {for (final r in rows) r.key: r.value});
  }

  Future<AppSettings> load() async => AppSettings.fromKeyValues(await readAll());

  /// Writes only the keys whose values actually changed.
  ///
  /// An unchanged key is left alone rather than rewritten, which keeps
  /// `updated_at` meaningful for the eventual settings sync.
  Future<void> save(AppSettings settings) async {
    final desired = settings.toKeyValues();
    final current = await readAll();
    final now = DateTime.now().toUtc();

    final changed = <String, String>{};
    for (final entry in desired.entries) {
      if (current[entry.key] != entry.value) {
        changed[entry.key] = entry.value;
      }
    }
    if (changed.isEmpty) return;

    await batch((b) {
      b.insertAllOnConflictUpdate(
        appSettingsEntries,
        changed.entries
            .map((e) => AppSettingsEntriesCompanion.insert(
                  key: e.key,
                  value: e.value,
                  updatedAt: now,
                ))
            .toList(),
      );
    });
  }

  Future<void> put(String key, String value) async {
    await into(appSettingsEntries).insertOnConflictUpdate(
      AppSettingsEntriesCompanion.insert(
        key: key,
        value: value,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<String?> get(String key) async {
    final query = select(appSettingsEntries)..where((t) => t.key.equals(key));
    final row = await query.getSingleOrNull();
    return row?.value;
  }
}
