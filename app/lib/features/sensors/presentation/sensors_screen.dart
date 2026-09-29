import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../data/sensor_manager.dart';
import '../domain/sensor.dart';

/// BLE sensor management (spec §35, §39).
///
/// The list is organized by what the rider gets, not by what the device is: a
/// combined speed-and-cadence sensor shows up under 踏频, because that is the
/// number they will see on the dashboard.
class SensorsScreen extends ConsumerStatefulWidget {
  const SensorsScreen({super.key});

  @override
  ConsumerState<SensorsScreen> createState() => _SensorsScreenState();
}

class _SensorsScreenState extends ConsumerState<SensorsScreen> {
  SensorManager? _manager;

  @override
  void deactivate() {
    // Scanning is active radio use. Leaving the screen has to stop it, or a
    // rider who wandered into settings and back out again runs a scan for the
    // rest of the ride.
    _manager?.removeListener(_onChanged);
    _manager?.stopScan();
    _manager = null;
    super.deactivate();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(sensorManagerProvider);
    if (!identical(manager, _manager)) {
      _manager?.removeListener(_onChanged);
      manager.addListener(_onChanged);
      _manager = manager;
    }

    final paired = manager.pairedSensors;
    final discovered = manager.discovered
        .where((d) => !paired.any((p) => p.id == d.id))
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('传感器'),
        actions: [
          if (manager.isScanning)
            TextButton(onPressed: manager.stopScan, child: const Text('停止'))
          else
            IconButton(
              tooltip: '搜索设备',
              icon: const Icon(Icons.bluetooth_searching),
              onPressed: manager.startScan,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          if (!manager.bluetoothAvailable)
            SettingsSection(
              title: '蓝牙不可用',
              rows: const [
                SettingsTile(
                  title: '请打开蓝牙',
                  subtitle:
                      '心率带、踏频器和功率计需要通过蓝牙连接。'
                      '未连接传感器时，骑行记录和其他功能完全正常。',
                  leading: Icon(Icons.bluetooth_disabled),
                ),
              ],
            ),

          if (paired.isNotEmpty)
            SettingsSection(
              title: '已配对',
              rows: [
                for (final sensor in paired)
                  _PairedTile(sensor: sensor, manager: manager),
              ],
              footnote: '踏频和心率数据会随骑行记录一起保存，并出现在 GPX 文件的扩展字段中。',
            ),

          if (manager.isScanning || discovered.isNotEmpty)
            SettingsSection(
              title: '发现的设备',
              rows: [
                if (manager.isScanning && discovered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Column(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(height: 14),
                          Text('正在搜索附近的心率带、踏频器和功率计…', style: AppText.caption),
                        ],
                      ),
                    ),
                  ),
                for (final device in discovered)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    leading: Icon(_iconFor(device.type)),
                    title: Text(device.name, style: AppText.body),
                    subtitle: Text(
                      '${device.type.label} · 信号 ${_rssiLabel(device.rssi)}',
                      style: AppText.caption,
                    ),
                    trailing: OutlinedButton(
                      onPressed: () => manager.pair(device),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      child: const Text('配对'),
                    ),
                  ),
              ],
            ),

          if (!manager.isScanning && paired.isEmpty && discovered.isEmpty)
            SettingsSection(
              title: '开始',
              rows: [
                SettingsTile(
                  title: '点击右上角搜索设备',
                  subtitle:
                      '确保传感器的电池已装好，并且没有被其他设备（例如手机上的其他骑行 App）占用。'
                      '大多数心率带在未被连接时才会广播。',
                  leading: const Icon(Icons.bluetooth),
                  onTap: manager.startScan,
                ),
              ],
            ),

          const SettingsSection(
            title: '支持的设备',
            rows: [
              SettingsTile(
                title: '心率带',
                subtitle: '标准 BLE 心率服务（0x180D）',
                leading: Icon(Icons.favorite_outline),
              ),
              SettingsTile(
                title: '踏频 / 速度传感器',
                subtitle: '标准骑行速度与踏频服务（0x1816）',
                leading: Icon(Icons.rotate_right),
              ),
              SettingsTile(
                title: '功率计',
                subtitle: '标准骑行功率服务（0x1818），同时提供踏频',
                leading: Icon(Icons.bolt_outlined),
              ),
            ],
            footnote:
                '只使用标准 GATT 服务，不区分品牌。'
                'ANT+ 设备需要额外的硬件，暂不支持。',
          ),

          const _PhoneSensorsSection(),
        ],
      ),
    );
  }

  static IconData _iconFor(SensorType type) => switch (type) {
    SensorType.heartRate => Icons.favorite_outline,
    SensorType.cadence => Icons.rotate_right,
    SensorType.speed => Icons.speed,
    SensorType.power => Icons.bolt_outlined,
  };

  static String _rssiLabel(int rssi) {
    if (rssi >= -60) return '强';
    if (rssi >= -80) return '中';
    return '弱';
  }
}

/// What the phone itself contributes, which decides what two figures on the
/// dashboard are worth.
///
/// Neither is a BLE device and neither is pairable — they are part of the
/// phone — so they get their own section rather than a row under
/// 「支持的设备」. The rider-facing question they answer is why one phone
/// reports 300 m of climbing on a pass and another reports 「≈」, or why the
/// direction figure sits still on one phone and follows the bars on another.
class _PhoneSensorsSection extends ConsumerWidget {
  const _PhoneSensorsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasBarometer = ref.watch(barometerAvailabilityProvider).valueOrNull;
    final hasCompass = ref.watch(compassAvailabilityProvider).valueOrNull;
    final hasMotion = ref.watch(motionAvailabilityProvider).valueOrNull;

    return SettingsSection(
      title: '手机自带',
      rows: [
        SettingsTile(
          title: '气压计',
          subtitle: switch (hasBarometer) {
            null => '正在检查…',
            true => '有此设备。爬升和坡度按气压变化测量，不会标注为估算',
            false =>
              '这台手机没有气压计。爬升来自 GPS 高度，是估算值 —— '
                  '平路可能虚报十几米，长爬坡几乎无损',
          },
          leading: Icon(
            hasBarometer == false
                ? Icons.speed_outlined
                : Icons.terrain_outlined,
          ),
        ),
        SettingsTile(
          title: '指南针',
          subtitle: switch (hasCompass) {
            null => '正在检查…',
            true =>
              '有此设备。GPS 航向在约 11 km/h 以下不会更新，'
                  '此时方向由指南针给出',
            false =>
              '这台手机没有指南针（或没有磁力计）。'
                  '低速和停车时方向会停在最后一次 GPS 航向',
          },
          leading: Icon(
            hasCompass == false
                ? Icons.explore_off_outlined
                : Icons.explore_outlined,
          ),
        ),
        SettingsTile(
          title: '运动检测',
          subtitle: switch (hasMotion) {
            null => '正在检查…',
            true =>
              '有此设备。停车时用加速度判断车是否真的停下了，'
                  '自动暂停因此更快，采样也更省电',
            false =>
              '这台手机没有加速度计。自动暂停只按速度判断，'
                  '和以前一样可用',
          },
          leading: Icon(
            hasMotion == false
                ? Icons.vibration
                : Icons.directions_bike_outlined,
          ),
        ),
      ],
      footnote: _footnote(
        hasBarometer: hasBarometer,
        hasCompass: hasCompass,
        hasMotion: hasMotion,
      ),
    );
  }

  /// The section's trailing note, which has to carry three unrelated things.
  ///
  /// The compass one is only shown to a rider who actually has one: it is not
  /// a hardware explanation but a limitation, and finding it out on a ride —
  /// after trusting the number at a junction — is worse than reading it here.
  /// No such warning belongs on motion detection, which can only ever make a
  /// decision the rider already trusts slightly earlier.
  static String? _footnote({
    required bool? hasBarometer,
    required bool? hasCompass,
    required bool? hasMotion,
  }) {
    final notes = <String>[
      if (hasBarometer == false)
        '要拿到测量值需要手机自带气压计（大多数中高端机型有，少数没有）。'
            '这是硬件差异，不是设置问题。',
      if (hasCompass == true)
        '指南针读的是手机的朝向：只有手机和车头同向固定时，它才等于行进方向。'
            '放在口袋里会跟着身体转，这时方向数值不可信；'
            '钢架、磁吸支架和扬声器也会干扰磁力计。'
            'GPS 航向可用时一律以 GPS 为准，所以影响只出现在低速和停车时。',
      if (hasMotion == true)
        '运动检测只用来确认「车停下来了」。振动不能证明骑手在骑，'
            '所以它不会让一次暂停提前结束 —— 恢复照旧看速度。',
    ];
    return notes.isEmpty ? null : notes.join('\n\n');
  }
}

class _PairedTile extends StatelessWidget {
  const _PairedTile({required this.sensor, required this.manager});

  final PairedSensor sensor;
  final SensorManager manager;

  @override
  Widget build(BuildContext context) {
    final status = manager.statuses[sensor.id];
    final state = status?.state ?? SensorConnectionState.disconnected;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      onTap: sensor.enabled && state == SensorConnectionState.disconnected
          ? () => manager.connect(sensor.id)
          : null,
      leading: Icon(
        _SensorsScreenState._iconFor(sensor.type),
        color: state == SensorConnectionState.connected
            ? AppColors.accent
            : AppColors.textTertiary,
      ),
      title: Text(sensor.name, style: AppText.body),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          _subtitle(status, state),
          style: AppText.caption.copyWith(
            color: status?.error != null ? AppColors.danger : null,
          ),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch.adaptive(
            value: sensor.enabled,
            activeThumbColor: Colors.black,
            activeTrackColor: AppColors.accent,
            onChanged: (v) => manager.setEnabled(sensor.id, v),
          ),
          IconButton(
            tooltip: '忘记此设备',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => _confirmForget(context),
          ),
        ],
      ),
    );
  }

  static String _subtitle(SensorStatus? status, SensorConnectionState state) {
    if (status?.sensor.enabled == false) return '已关闭';
    if (status?.error != null) return '${status!.error!} · 点击重试';
    return switch (state) {
      SensorConnectionState.connected =>
        status?.lastValue == null
            ? '已连接'
            : '已连接 · 当前 ${status!.lastValue!.round()}',
      SensorConnectionState.connecting => '连接中…',
      SensorConnectionState.disconnected => '未连接 · 点击重试',
    };
  }

  Future<void> _confirmForget(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('忘记「${sensor.name}」？'),
        content: const Text('下次需要重新配对。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('忘记'),
          ),
        ],
      ),
    );

    if (confirmed == true) await manager.forget(sensor.id);
  }
}
