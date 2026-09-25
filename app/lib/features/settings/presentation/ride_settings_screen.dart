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
            ],
            footnote: '高精度档位每秒采样一次。停车时应用会自动降低采样频率以节省电量。',
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
