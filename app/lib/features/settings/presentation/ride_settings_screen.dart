import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../domain/app_settings.dart';

/// 骑行 settings (spec §39).
class RideSettingsScreen extends ConsumerWidget {
  const RideSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(currentSettingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('骑行')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsSection(
            title: '自动暂停',
            rows: [
              SettingsSwitch(
                title: '启用自动暂停',
                subtitle: '低于阈值速度一段时间后自动暂停记录',
                value: settings.autoPause,
                onChanged: (v) => notifier.mutate((s) => s.copyWith(autoPause: v)),
              ),
              SettingsStepper(
                title: '暂停速度阈值',
                subtitle: '速度低于此值持续一段时间后暂停',
                value: settings.autoPauseSpeedThresholdKph.round(),
                suffix: ' km/h',
                min: 1,
                max: 10,
                enabled: settings.autoPause,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(autoPauseSpeedThresholdKph: v.toDouble())),
              ),
              SettingsStepper(
                title: '暂停延迟',
                subtitle: '避免停车瞬间误触发',
                value: settings.autoPauseDelaySeconds,
                suffix: ' s',
                min: 1,
                max: 30,
                enabled: settings.autoPause,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(autoPauseDelaySeconds: v)),
              ),
              SettingsStepper(
                title: '恢复速度阈值',
                subtitle: '速度高于此值持续一段时间后恢复',
                value: settings.autoResumeSpeedThresholdKph.round(),
                suffix: ' km/h',
                min: 2,
                max: 15,
                enabled: settings.autoPause,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(autoResumeSpeedThresholdKph: v.toDouble())),
              ),
              SettingsStepper(
                title: '恢复延迟',
                value: settings.autoResumeDelaySeconds,
                suffix: ' s',
                min: 1,
                max: 15,
                enabled: settings.autoPause,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(autoResumeDelaySeconds: v)),
              ),
            ],
            footnote: '速度阈值之间留有间隔（默认 2 / 3 km/h），'
                '避免在阈值附近反复切换暂停与恢复。',
          ),

          SettingsSection(
            title: '开始方式',
            rows: [
              SettingsChoice<StartCountdown>(
                title: '倒计时开始',
                subtitle: '给骑手一点时间扶好车把，同时等待 GPS 稳定',
                value: settings.startCountdown,
                options: [
                  for (final option in StartCountdown.values)
                    (value: option, label: option.label),
                ],
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(startCountdown: v)),
              ),
            ],
          ),

          SettingsSection(
            title: 'GPS',
            rows: [
              SettingsChoice<GpsAccuracyMode>(
                title: '定位精度',
                subtitle: settings.gpsAccuracy.description,
                value: settings.gpsAccuracy,
                options: [
                  for (final mode in GpsAccuracyMode.values)
                    (value: mode, label: mode.label),
                ],
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(gpsAccuracy: v)),
              ),
              SettingsStepper(
                title: '有效精度上限',
                subtitle: '精度差于此值的定位不计入里程，但仍会显示',
                value: settings.maxAcceptableAccuracyMeters.round(),
                suffix: ' m',
                min: 10,
                max: 200,
                step: 5,
                onChanged: (v) => notifier.mutate(
                  (s) => s.copyWith(maxAcceptableAccuracyMeters: v.toDouble()),
                ),
              ),
              SettingsStepper(
                title: '信号丢失判定',
                subtitle: '超过此时间没有定位则提示信号丢失',
                value: settings.gpsSignalLostSeconds,
                suffix: ' s',
                min: 5,
                max: 120,
                step: 5,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(gpsSignalLostSeconds: v)),
              ),
              const _BackgroundLocationRow(),
              const _NotificationRow(),
              if (defaultTargetPlatform == TargetPlatform.android)
                const _BatteryOptimizationRow(),
            ],
            footnote:
                '高精度档位每秒采样一次。停车后改为大约 5 秒一次，'
                '定位精度保持你选的那一档，避免卫星芯片休眠。\n\n'
                '手机放车把支架（朝上固定）比放口袋更稳；'
                '金属壳、强磁吸和车架遮挡会加重城市多径；'
                '开骑前尽量到开阔天空下等 GPS 就绪。',
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Text(
              '骑行结束后只有名称和备注可以修改，'
              '距离、时间和爬升不会被自动改写。',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether the phone will keep delivering fixes with the screen off.
///
/// The one permission state that is invisible until it hurts: a foreground-only
/// grant produces a working app that stops recording when the rider pockets
/// the phone. The home screen says so once before the first ride; this row is
/// where they can check it again after dismissing that notice.
class _BackgroundLocationRow extends ConsumerWidget {
  const _BackgroundLocationRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(backgroundLocationProvider);
    final granted = access.valueOrNull;

    return SettingsTile(
      title: '锁屏继续记录',
      subtitle: granted == null
          ? '正在检查系统权限…'
          : granted
              ? '已授权「始终允许」定位，锁屏后继续记录'
              : '当前只有「使用 App 期间」定位。锁屏后系统可能停止提供位置，'
                  '记录会中断 —— 到系统设置里改成「始终允许」',
      leading: Icon(
        granted == false ? Icons.warning_amber_outlined : Icons.lock_clock,
        color: granted == false ? AppColors.warning : null,
      ),
      onTap: granted == false
          ? () => ref.read(locationServiceProvider).openAppSettings()
          : null,
    );
  }
}

/// Whether the recording notification is allowed.
///
/// Worth a row of its own: on Android 13+ the foreground service notification
/// is invisible without this grant, and that notification is how a rider
/// confirms — from a locked screen — that the ride is still being recorded.
/// The permission dialog cannot be shown a second time, so a rider who
/// declined needs a path back, and this is it.
class _NotificationRow extends ConsumerStatefulWidget {
  const _NotificationRow();

  @override
  ConsumerState<_NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends ConsumerState<_NotificationRow> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final granted = await ref.read(notificationPermissionProvider).isGranted();
    if (mounted) setState(() => _granted = granted);
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;

    return SettingsTile(
      title: '记录通知',
      subtitle: granted == null
          ? '正在检查系统权限…'
          : granted
              ? '已允许。锁屏后通知栏会常驻「正在记录骑行」'
              : '未允许。记录照常进行，但锁屏后看不到这条状态；'
                  '在系统设置里打开通知即可',
      leading: Icon(
        granted == false
            ? Icons.notifications_off_outlined
            : Icons.notifications_none,
        color: granted == false ? AppColors.warning : null,
      ),
      onTap: granted == false
          ? () async {
              await ref.read(notificationPermissionProvider).openSettings();
              await _refresh();
            }
          : null,
    );
  }
}

/// Android's battery-optimization exemption.
///
/// The foreground service is not enough on the phones this app is ridden on.
/// Xiaomi, Huawei and OPPO will still freeze a background process they have
/// not been told to leave alone, and a frozen process delivers no fixes.
/// The row is Android-only: other platforms have nothing to ask.
class _BatteryOptimizationRow extends ConsumerStatefulWidget {
  const _BatteryOptimizationRow();

  @override
  ConsumerState<_BatteryOptimizationRow> createState() =>
      _BatteryOptimizationRowState();
}

class _BatteryOptimizationRowState
    extends ConsumerState<_BatteryOptimizationRow> {
  bool? _ignoring;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ignoring = await ref.read(batteryOptimizationProvider).isIgnoring();
    if (mounted) setState(() => _ignoring = ignoring);
  }

  @override
  Widget build(BuildContext context) {
    final ignoring = _ignoring;

    return SettingsTile(
      title: '电池优化',
      subtitle: ignoring == null
          ? '正在检查系统设置…'
          : ignoring
          ? '已关闭对本应用的电池优化，锁屏后系统不会为了省电停掉定位'
          : '系统省电可能会在锁屏后停掉定位。关闭对本应用的电池优化，'
                '记录才不会被中途掐断',
      leading: Icon(
        ignoring == false ? Icons.battery_alert_outlined : Icons.battery_saver,
        color: ignoring == false ? AppColors.warning : null,
      ),
      onTap: ignoring == false
          ? () async {
              await ref.read(batteryOptimizationProvider).request();
              await _refresh();
            }
          : null,
    );
  }
}
