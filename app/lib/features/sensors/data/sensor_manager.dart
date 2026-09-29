import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/database/dao/sensor_dao.dart';
import '../../../core/database/database.dart';
import '../../settings/domain/app_settings.dart';
import '../domain/sensor.dart';
import 'ble_backend.dart';

/// Owns paired sensors and their connections.
///
/// The manager is the only thing in the app that knows a device id, a GATT
/// service or a brand name. Everything downstream receives [SensorReading] —
/// which is what lets the ride engine accept a heart rate without knowing
/// whether it came from a chest strap, a watch or a mock (spec §35).
///
/// It is deliberately tolerant of having no radio at all: on a desktop build,
/// or on a phone where the user denied Bluetooth permission, every method
/// degrades to a no-op and the rest of the app is unaffected. Sensors are an
/// enhancement to a ride, never a prerequisite for one.
class SensorManager extends ChangeNotifier {
  SensorManager({
    required AppDatabase db,
    BleBackend? backend,
    this.retryInitialDelay = const Duration(seconds: 15),
  }) : _db = db,
       _backend = backend ?? UniversalBleBackend() {
    _ready = _loadPaired();
  }

  final AppDatabase _db;
  final BleBackend _backend;
  final Duration retryInitialDelay;
  late final Future<void> _ready;

  SensorDao get _dao => _db.sensorDao;

  final List<PairedSensor> _paired = [];
  final Map<String, SensorStatus> _statuses = {};
  final Map<String, StreamSubscription<SensorReading>> _connections = {};
  final Set<String> _connecting = {};
  final Set<String> _blockedConnections = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, Duration> _retryDelays = {};
  bool _disposed = false;

  final _readings = StreamController<SensorReading>.broadcast();

  /// All normalized readings, for the ride engine to consume.
  Stream<SensorReading> get readings => _readings.stream;

  List<PairedSensor> get pairedSensors => List.unmodifiable(_paired);

  /// Connection state for each paired sensor, keyed by device id.
  Map<String, SensorStatus> get statuses => Map.unmodifiable(_statuses);

  bool _bluetoothAvailable = true;
  bool get bluetoothAvailable => _bluetoothAvailable;

  bool _scanning = false;
  bool get isScanning => _scanning;

  List<DiscoveredDevice> _discovered = const [];
  List<DiscoveredDevice> get discovered => _discovered;

  /// Sensors are independent of the ride settings today, so there is nothing
  /// to apply — the hook exists so the settings notifier has a uniform way to
  /// push changes to every long-lived service, and so a future "only connect
  /// while riding" option has an obvious place to live.
  void applySettings(AppSettings settings) {}

  bool get hasAnyConnected =>
      _statuses.values.any((s) => s.state == SensorConnectionState.connected);

  /// Give enabled sensors a fresh connection attempt when a ride starts.
  /// A sensor switched on after app launch may have missed the first attempt.
  Future<void> reconnectEnabled() async {
    await _ready;
    if (_disposed) return;
    for (final sensor in _paired.where((s) => s.enabled)) {
      unawaited(connect(sensor.id));
    }
  }

  // ---- Pairing ----

  Future<void> _loadPaired() async {
    final rows = await _dao.all();
    if (_disposed) return;
    _paired
      ..clear()
      ..addAll(rows);
    for (final sensor in _paired) {
      _statuses[sensor.id] = SensorStatus(sensor: sensor);
    }
    notifyListeners();

    // Reconnect anything the rider had enabled. Auto-connecting is what makes
    // a strap work on the second ride without being re-paired every time.
    for (final sensor in rows.where((s) => s.enabled)) {
      unawaited(connect(sensor.id));
    }
  }

  /// Scans for supported sensors.
  ///
  /// Returns an empty list rather than throwing when Bluetooth is off — the
  /// UI shows "请打开蓝牙", which is a more useful answer than an exception.
  Future<List<DiscoveredDevice>> startScan({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_scanning) return _discovered;
    _scanning = true;
    _discovered = const [];
    notifyListeners();

    try {
      _bluetoothAvailable = await _backend.isAvailable();
      if (!_bluetoothAvailable) {
        _scanning = false;
        notifyListeners();
        return const [];
      }

      final completer = Completer<List<DiscoveredDevice>>();
      late StreamSubscription<List<DiscoveredDevice>> sub;

      sub = _backend
          .scan(timeout: timeout)
          .listen(
            (devices) {
              _discovered = devices;
              notifyListeners();
            },
            onError: (Object _) {
              if (!completer.isCompleted) completer.complete(_discovered);
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete(_discovered);
            },
          );

      await completer.future;
      await sub.cancel();
      return _discovered;
    } catch (_) {
      return _discovered;
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    await _backend.stopScan();
    _scanning = false;
    notifyListeners();
  }

  /// Pairs a discovered device and connects to it.
  Future<void> pair(DiscoveredDevice device) async {
    final sensor = PairedSensor(
      id: device.id,
      name: device.name,
      type: device.type,
    );
    await _dao.upsert(sensor);

    _paired
      ..removeWhere((s) => s.id == sensor.id)
      ..add(sensor);
    _statuses[sensor.id] = SensorStatus(sensor: sensor);
    notifyListeners();

    await connect(sensor.id);
  }

  Future<void> forget(String deviceId) async {
    await disconnect(deviceId);
    await _dao.forget(deviceId);
    _paired.removeWhere((s) => s.id == deviceId);
    _statuses.remove(deviceId);
    notifyListeners();
  }

  Future<void> setEnabled(String deviceId, bool enabled) async {
    await _dao.setEnabled(deviceId, enabled);

    final index = _paired.indexWhere((s) => s.id == deviceId);
    if (index >= 0) {
      final updated = _paired[index].copyWith(enabled: enabled);
      _paired[index] = updated;
      _statuses[deviceId] =
          (_statuses[deviceId] ?? SensorStatus(sensor: updated)).copyWith(
            sensor: updated,
          );
      notifyListeners();
    }

    if (enabled) {
      await connect(deviceId);
    } else {
      await disconnect(deviceId);
    }
  }

  // ---- Connection ----

  Future<void> connect(String deviceId) async {
    final sensor = _paired.firstWhere(
      (s) => s.id == deviceId,
      orElse: () => PairedSensor(
        id: deviceId,
        name: deviceId,
        type: SensorType.heartRate,
      ),
    );

    if (_connections.containsKey(deviceId) || _connecting.contains(deviceId)) {
      return;
    }

    _blockedConnections.remove(deviceId);
    _retryTimers.remove(deviceId)?.cancel();
    _connecting.add(deviceId);

    _setState(deviceId, SensorConnectionState.connecting);

    try {
      final stream = await _backend.connect(
        DiscoveredDevice(
          id: sensor.id,
          name: sensor.name,
          type: sensor.type,
          rssi: 0,
        ),
      );

      if (_disposed ||
          _blockedConnections.contains(deviceId) ||
          !_isEnabled(deviceId)) {
        try {
          await _backend.disconnect(deviceId);
        } catch (_) {
          // This connection was cancelled while it was opening.
        }
        return;
      }

      _connections[deviceId] = stream.listen(
        (reading) {
          if (_disposed) return;
          _readings.add(reading);
          _statuses[deviceId] =
              (_statuses[deviceId] ?? SensorStatus(sensor: sensor)).copyWith(
                lastValue: reading.value,
                state: SensorConnectionState.connected,
              );
          notifyListeners();
        },
        onError: (Object e) {
          _setError(deviceId, _describe(e));
          unawaited(_backend.disconnect(deviceId).catchError((Object _) {}));
          _scheduleRetry(deviceId);
        },
        onDone: () {
          _connections.remove(deviceId);
          _setState(deviceId, SensorConnectionState.disconnected);
          _scheduleRetry(deviceId);
        },
      );

      _retryDelays.remove(deviceId);
      _setState(deviceId, SensorConnectionState.connected);
      try {
        await _dao.markConnected(deviceId);
      } catch (_) {
        // A timestamp write must not drop an otherwise healthy BLE link.
      }
    } catch (e) {
      _setError(deviceId, _describe(e));
      _scheduleRetry(deviceId);
    } finally {
      _connecting.remove(deviceId);
    }
  }

  Future<void> disconnect(String deviceId) async {
    _blockedConnections.add(deviceId);
    _retryTimers.remove(deviceId)?.cancel();
    _retryDelays.remove(deviceId);
    await _connections.remove(deviceId)?.cancel();
    try {
      await _backend.disconnect(deviceId);
    } catch (_) {
      // Already gone.
    }
    _setState(deviceId, SensorConnectionState.disconnected);
  }

  Future<void> disconnectAll() async {
    for (final id in _connections.keys.toList()) {
      await disconnect(id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    for (final sub in _connections.values) {
      unawaited(sub.cancel());
    }
    _connections.clear();
    unawaited(_readings.close());
    unawaited(_backend.dispose());
    super.dispose();
  }

  // ---- Internals ----

  void _setState(String deviceId, SensorConnectionState state) {
    if (_disposed) return;
    final existing = _statuses[deviceId];
    final sensor =
        existing?.sensor ??
        _paired.firstWhere(
          (s) => s.id == deviceId,
          orElse: () => PairedSensor(
            id: deviceId,
            name: deviceId,
            type: SensorType.heartRate,
          ),
        );
    _statuses[deviceId] = (existing ?? SensorStatus(sensor: sensor)).copyWith(
      state: state,
      clearError: state != SensorConnectionState.disconnected,
    );
    notifyListeners();
  }

  void _setError(String deviceId, String message) {
    _connections.remove(deviceId)?.cancel();
    if (_disposed) return;
    final existing = _statuses[deviceId];
    final sensor =
        existing?.sensor ??
        PairedSensor(id: deviceId, name: deviceId, type: SensorType.heartRate);
    _statuses[deviceId] = (existing ?? SensorStatus(sensor: sensor)).copyWith(
      state: SensorConnectionState.disconnected,
      error: message,
    );
    notifyListeners();
  }

  bool _isEnabled(String deviceId) =>
      _paired.any((sensor) => sensor.id == deviceId && sensor.enabled);

  void _scheduleRetry(String deviceId) {
    if (_disposed ||
        _blockedConnections.contains(deviceId) ||
        !_isEnabled(deviceId) ||
        _retryTimers.containsKey(deviceId)) {
      return;
    }

    final delay = _retryDelays[deviceId] ?? retryInitialDelay;
    final doubled = delay * 2;
    _retryDelays[deviceId] = doubled > const Duration(minutes: 2)
        ? const Duration(minutes: 2)
        : doubled;
    _retryTimers[deviceId] = Timer(delay, () {
      _retryTimers.remove(deviceId);
      unawaited(connect(deviceId));
    });
  }

  static String _describe(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('permission')) return '缺少蓝牙权限';
    if (text.contains('not supported')) return '此设备不支持蓝牙';
    if (text.contains('timeout') || text.contains('timed out')) {
      return '连接超时，请靠近传感器后重试';
    }
    if (text.contains('disconnected')) return '设备已断开';
    return '连接失败';
  }
}
