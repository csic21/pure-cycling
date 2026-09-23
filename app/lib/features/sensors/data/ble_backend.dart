import 'dart:async';

import 'package:universal_ble/universal_ble.dart';

import '../domain/sensor.dart';
import 'gatt_parsers.dart';

/// One device seen during a scan.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.rssi,
  });

  final String id;
  final String name;
  final SensorType type;
  final int rssi;
}

/// The Bluetooth transport, behind an interface.
///
/// Everything above this file deals in [DiscoveredDevice] and [SensorReading].
/// That means the sensor manager can be exercised on a machine with no
/// Bluetooth radio, and swapping the BLE package later touches one file — as
/// happened once already, when the project moved off a library whose licence
/// required payment for commercial use.
abstract interface class BleBackend {
  /// Whether the radio is on and usable.
  Future<bool> isAvailable();

  /// Streams devices advertising any of the supported GATT services.
  ///
  /// The scan filters on service UUIDs rather than listing everything in
  /// range: a bike-mounted phone next to a café will otherwise show a hundred
  /// headsets and televisions, and every one of them costs battery to
  /// discover.
  Stream<List<DiscoveredDevice>> scan({Duration timeout});

  Future<void> stopScan();

  /// Connects and streams normalized readings until [dispose] is called.
  Future<Stream<SensorReading>> connect(DiscoveredDevice device);

  Future<void> disconnect(String deviceId);

  Future<void> dispose();
}

/// The real implementation, backed by `universal_ble`.
///
/// **`universal_ble` is BSD-3-Clause** — permissive, with no restriction on
/// commercial use. That is why it is here: the previous implementation used
/// `flutter_blue_plus`, which is free only for personal, nonprofit and
/// educational use and requires a paid licence the moment an app is sold or
/// run by a company.
///
/// Because `BleBackend` is an interface and this is its only implementation
/// that touches a platform, that swap was confined to this file. The parser
/// tests, the sensor manager and every screen above them were unaffected.
class UniversalBleBackend implements BleBackend {
  UniversalBleBackend();

  final Map<String, BluetoothDeviceHandle> _devices = {};
  final Map<String, List<StreamSubscription<dynamic>>> _subscriptions = {};
  final Map<String, int> _battery = {};

  @override
  Future<bool> isAvailable() async {
    try {
      final state = await UniversalBle.getBluetoothAvailabilityState();
      // `unsupported` is the desktop-without-a-radio case and
      // `unauthorized` the denied-permission case. Neither is an error worth
      // surfacing as an exception — the settings screen explains both.
      return state == AvailabilityState.poweredOn;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<List<DiscoveredDevice>> scan({
    Duration timeout = const Duration(seconds: 15),
  }) {
    final controller = StreamController<List<DiscoveredDevice>>();

    unawaited(() async {
      try {
        // A device that advertises two services would otherwise appear twice;
        // the map keyed by device id keeps the list stable and lets a later
        // advertisement upgrade a device's RSSI in place.
        final seen = <String, DiscoveredDevice>{};

        final sub = UniversalBle.scanStream.listen((device) {
          final discovered = _classify(device);
          if (discovered == null) return;

          seen[discovered.id] = discovered;
          _devices[discovered.id] = BluetoothDeviceHandle(
            id: discovered.id,
            services: device.services,
          );

          if (!controller.isClosed) {
            controller.add(seen.values.toList(growable: false));
          }
        });

        await UniversalBle.startScan(
          scanFilter: ScanFilter(
            withServices: GattParsers.supportedServices
                .map(GattParsers.normalizeUuid)
                .toList(growable: false),
          ),
        );

        // `universal_ble` scans until told to stop, unlike the previous
        // library whose `startScan` resolved when the scan finished. The
        // timeout is ours to enforce.
        await Future<void>.delayed(timeout);
        await UniversalBle.stopScan();
        await sub.cancel();

        if (!controller.isClosed) await controller.close();
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(e);
          await controller.close();
        }
      }
    }());

    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    try {
      await UniversalBle.stopScan();
    } catch (_) {
      // Already stopped, or the radio went away mid-scan.
    }
  }

  @override
  Future<Stream<SensorReading>> connect(DiscoveredDevice device) async {
    final handle = _devices[device.id];
    if (handle == null) {
      throw StateError('设备已不在范围内：${device.name}');
    }

    await UniversalBle.connect(
      device.id,
      timeout: const Duration(seconds: 20),
    );

    final services = await UniversalBle.discoverServices(device.id);
    final tracker = BluetoothDeviceHandle(id: device.id, services: handle.services);
    _devices[device.id] = tracker;

    await _cancelSubscriptions(device.id);
    final subs = <StreamSubscription<dynamic>>[];
    final controller = StreamController<SensorReading>();

    // Heart rate and CSC counters are cumulative, so each characteristic
    // needs its own accumulator to turn them into rates.
    final csc = CscAccumulator();

    for (final service in services) {
      handle.service(service);

      if (GattParsers.matches(service.uuid, GattParsers.heartRateService)) {
        final hr = handle.characteristic(
          service,
          GattParsers.heartRateMeasurement,
        );
        if (hr != null) {
          subs.add(
            hr.onValueReceived.listen((value) {
              final bpm = GattParsers.parseHeartRate(value);
              if (bpm != null) {
                controller.add(
                  SensorReading(
                    type: SensorType.heartRate,
                    value: bpm.toDouble(),
                    timestamp: DateTime.now().toUtc(),
                    sensorId: device.id,
                  ),
                );
              }
            }),
          );
          await hr.notifications.subscribe();
        }
      }

      if (GattParsers.matches(service.uuid, GattParsers.cscService)) {
        final cscChar = handle.characteristic(
          service,
          GattParsers.cscMeasurement,
        );
        if (cscChar != null) {
          subs.add(
            cscChar.onValueReceived.listen((value) {
              final measurement = GattParsers.parseCsc(value);
              if (measurement == null) return;
              final now = DateTime.now().toUtc();

              if (measurement.hasCrank) {
                final rpm = csc.addCrank(
                  measurement.crankRevolutions!,
                  measurement.crankEventTimeUnits!,
                );
                if (rpm != null) {
                  controller.add(
                    SensorReading(
                      type: SensorType.cadence,
                      value: rpm.toDouble(),
                      timestamp: now,
                      sensorId: device.id,
                    ),
                  );
                }
              }

              if (measurement.hasWheel) {
                final kph = csc.addWheel(
                  measurement.wheelRevolutions!,
                  measurement.wheelEventTimeUnits!,
                );
                if (kph != null) {
                  controller.add(
                    SensorReading(
                      type: SensorType.speed,
                      value: kph,
                      timestamp: now,
                      sensorId: device.id,
                    ),
                  );
                }
              }
            }),
          );
          await cscChar.notifications.subscribe();
        }
      }

      if (GattParsers.matches(service.uuid, GattParsers.cyclingPowerService)) {
        final powerChar = handle.characteristic(
          service,
          GattParsers.cyclingPowerMeasurement,
        );
        if (powerChar != null) {
          final crank = CscAccumulator();
          subs.add(
            powerChar.onValueReceived.listen((value) {
              final measurement = GattParsers.parsePower(value);
              if (measurement == null) return;
              final now = DateTime.now().toUtc();

              controller.add(
                SensorReading(
                  type: SensorType.power,
                  value: measurement.watts.toDouble(),
                  timestamp: now,
                  sensorId: device.id,
                ),
              );

              // A power meter usually carries crank data too, which is a more
              // reliable cadence source than a separate sensor.
              if (measurement.crankRevolutions != null &&
                  measurement.crankEventTimeUnits != null) {
                final rpm = crank.addCrank(
                  measurement.crankRevolutions!,
                  measurement.crankEventTimeUnits!,
                );
                if (rpm != null) {
                  controller.add(
                    SensorReading(
                      type: SensorType.cadence,
                      value: rpm.toDouble(),
                      timestamp: now,
                      sensorId: device.id,
                    ),
                  );
                }
              }
            }),
          );
          await powerChar.notifications.subscribe();
        }
      }

      if (GattParsers.matches(service.uuid, GattParsers.batteryService)) {
        final batteryChar = handle.characteristic(
          service,
          GattParsers.batteryLevel,
        );
        if (batteryChar != null) {
          try {
            final value = await batteryChar.read();
            _battery[device.id] =
                GattParsers.parseBatteryLevel(value) ?? -1;
          } catch (_) {
            // Battery level is optional and often unreadable on the first
            // attempt while the device is still settling.
          }
        }
      }
    }

    _subscriptions[device.id] = subs;
    return controller.stream;
  }

  /// Last known battery percentage, or null.
  int? batteryFor(String deviceId) {
    final level = _battery[deviceId];
    return (level == null || level < 0) ? null : level;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    await _cancelSubscriptions(deviceId);
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {
      // Already disconnected.
    }
  }

  @override
  Future<void> dispose() async {
    for (final id in _subscriptions.keys.toList()) {
      await _cancelSubscriptions(id);
    }
    _devices.clear();
    await stopScan();
  }

  Future<void> _cancelSubscriptions(String deviceId) async {
    final subs = _subscriptions.remove(deviceId);
    if (subs == null) return;
    for (final sub in subs) {
      await sub.cancel();
    }
  }

  /// Works out what a scanned device is from the services it advertises.
  static DiscoveredDevice? _classify(BleDevice device) {
    for (final uuid in device.services) {
      final type = GattParsers.typeForService(uuid);
      if (type == null) continue;

      return DiscoveredDevice(
        id: device.deviceId,
        // A nameless device still works; naming it is friendlier than hiding
        // it, since some straps only reveal their name after connecting.
        name: (device.name?.trim().isNotEmpty ?? false)
            ? device.name!.trim()
            : '${type.label}（未命名）',
        type: type,
        rssi: device.rssi ?? 0,
      );
    }
    return null;
  }
}

/// A connected device plus the services that were discovered on it.
///
/// `universal_ble` addresses everything by string id, while the rest of this
/// file wants to hand out characteristics. This keeps the discovered service
/// tree in one place so a characteristic can be looked up by its short UUID
/// without threading service lists through every call site.
class BluetoothDeviceHandle {
  BluetoothDeviceHandle({required this.id, required this.services});

  final String id;

  /// Service UUIDs advertised at scan time. Retained so a device that stops
  /// advertising while connected can still be recognised.
  final List<String> services;

  final List<BleService> _discovered = [];

  void service(BleService service) {
    if (!_discovered.any((s) => s.uuid == service.uuid)) {
      _discovered.add(service);
    }
  }

  /// The characteristic with the given short UUID, or null.
  ///
  /// Matches on the normalized 128-bit form so a provider reporting `2A37`
  /// and one reporting the full UUID both work.
  BleCharacteristic? characteristic(BleService service, String shortUuid) {
    for (final c in service.characteristics) {
      if (GattParsers.matches(c.uuid, shortUuid)) return c;
    }
    return null;
  }
}
