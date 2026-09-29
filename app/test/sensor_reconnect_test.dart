import 'dart:async';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/features/sensors/data/ble_backend.dart';
import 'package:cycling_app/features/sensors/data/sensor_manager.dart';
import 'package:cycling_app/features/sensors/domain/sensor.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _FakeBleBackend implements BleBackend {
  final attempts = <String>[];
  final controllers = <StreamController<SensorReading>>[];
  int failuresRemaining = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<List<DiscoveredDevice>> scan({Duration timeout = Duration.zero}) =>
      const Stream.empty();

  @override
  Future<void> stopScan() async {}

  @override
  Future<Stream<SensorReading>> connect(DiscoveredDevice device) async {
    attempts.add(device.id);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('disconnected');
    }
    final controller = StreamController<SensorReading>.broadcast();
    controllers.add(controller);
    return controller.stream;
  }

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Future<void> dispose() async {
    for (final controller in controllers) {
      if (!controller.isClosed) await controller.close();
    }
  }
}

class _FakeBlePlatform extends UniversalBlePlatform {
  String? connectedId;
  bool permissionRequested = false;

  @override
  Future<void> requestPermissions({
    bool withAndroidFineLocation = false,
  }) async {
    permissionRequested = true;
  }

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connectedId = deviceId;
    scheduleMicrotask(() => updateConnection(deviceId, true));
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => [];

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      connectedId == deviceId
      ? BleConnectionState.connected
      : BleConnectionState.disconnected;

  @override
  Future<void> disconnect(String deviceId) async {
    connectedId = null;
    updateConnection(deviceId, false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('sensor state did not change');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('saved sensor reconnects on startup and retries after a drop', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.sensorDao.upsert(
      const PairedSensor(
        id: 'saved-id',
        name: 'Wheel',
        type: SensorType.cadence,
      ),
    );
    final backend = _FakeBleBackend();
    final manager = SensorManager(
      db: db,
      backend: backend,
      retryInitialDelay: const Duration(milliseconds: 10),
    );
    await manager.reconnectEnabled();
    await _waitUntil(
      () =>
          manager.statuses['saved-id']?.state ==
          SensorConnectionState.connected,
    );

    expect(backend.attempts, ['saved-id']);
    expect(
      manager.statuses['saved-id']?.state,
      SensorConnectionState.connected,
    );

    await backend.controllers.single.close();
    await _waitUntil(() => backend.attempts.length == 2);
    await _waitUntil(
      () =>
          manager.statuses['saved-id']?.state ==
          SensorConnectionState.connected,
    );
    expect(backend.attempts, ['saved-id', 'saved-id']);
    expect(
      manager.statuses['saved-id']?.state,
      SensorConnectionState.connected,
    );

    manager.dispose();
    await db.close();
  });

  test('failed connection retries and clears its old error', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.sensorDao.upsert(
      const PairedSensor(
        id: 'strap',
        name: 'Strap',
        type: SensorType.heartRate,
      ),
    );
    final backend = _FakeBleBackend()..failuresRemaining = 1;
    final manager = SensorManager(
      db: db,
      backend: backend,
      retryInitialDelay: const Duration(milliseconds: 10),
    );
    await manager.reconnectEnabled();
    await _waitUntil(() => backend.attempts.length == 2);
    await _waitUntil(
      () => manager.statuses['strap']?.state == SensorConnectionState.connected,
    );

    expect(backend.attempts, ['strap', 'strap']);
    expect(manager.statuses['strap']?.state, SensorConnectionState.connected);
    expect(manager.statuses['strap']?.error, isNull);

    manager.dispose();
    await db.close();
  });

  test('BLE backend connects by saved id without a scan first', () async {
    final platform = _FakeBlePlatform();
    UniversalBle.setInstance(platform);
    final backend = UniversalBleBackend();
    final readings = await backend.connect(
      const DiscoveredDevice(
        id: 'saved-id',
        name: 'Wheel',
        type: SensorType.cadence,
        rssi: 0,
      ),
    );
    expect(platform.connectedId, 'saved-id');
    expect(platform.permissionRequested, isTrue);

    final done = Completer<void>();
    readings.listen((_) {}, onDone: done.complete);
    platform.updateConnection('saved-id', false);
    await done.future.timeout(const Duration(seconds: 1));
    await backend.dispose();
  });
}
