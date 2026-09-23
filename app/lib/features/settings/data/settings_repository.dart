import '../../../core/database/dao/settings_dao.dart';
import '../../../core/database/database.dart';
import '../domain/app_settings.dart';

/// Persistence for the settings tree.
///
/// The in-memory `AppSettings` is the live value; this only reads it once at
/// startup and writes the diff on change.
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  SettingsDao get _dao => _db.settingsDao;

  Future<AppSettings> load() => _dao.load();

  /// Persists only the keys that changed.
  Future<void> save(AppSettings settings) => _dao.save(settings);

  /// Arbitrary key/value access for the handful of values that are not part of
  /// the user-editable settings tree — the remembered route provider, the last
  /// sync watermark.
  Future<String?> getString(String key) => _dao.get(key);

  Future<void> setString(String key, String value) => _dao.put(key, value);
}
