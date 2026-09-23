import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../domain/app_settings.dart';

/// Navigation settings (spec §8, §39).
class NavigationSettingsScreen extends ConsumerWidget {
  const NavigationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(currentSettingsProvider);
    final navigation = settings.navigation;
    final notifier = ref.read(settingsProvider.notifier);

    void update(NavigationConfig Function(NavigationConfig) transform) {
      notifier.mutate(
        (s) => s.copyWith(navigation: transform(s.navigation)),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('导航')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsSection(
            title: '显示',
            rows: [
              SettingsSwitch(
                title: '默认极简导航',
                subtitle: '只显示转向提示而不显示地图，更省电、阳光下更清楚',
                value: navigation.minimalByDefault,
                onChanged: (v) =>
                    update((c) => c.copyWith(minimalByDefault: v)),
              ),
              SettingsSwitch(
                title: '自动显示地图',
                subtitle: '复杂路口、环岛、连续转向和偏航时自动切到地图',
                value: navigation.autoShowMap,
                enabled: navigation.minimalByDefault,
                onChanged: (v) => update((c) => c.copyWith(autoShowMap: v)),
              ),
              SettingsStepper(
                title: '地图停留时间',
                subtitle: '转弯完成后地图保持显示的时间',
                value: navigation.autoMapDismissSeconds,
                suffix: ' s',
                min: 3,
                max: 30,
                enabled: navigation.minimalByDefault && navigation.autoShowMap,
                onChanged: (v) =>
                    update((c) => c.copyWith(autoMapDismissSeconds: v)),
              ),
              SettingsStepper(
                title: '提前切图距离',
                subtitle: '距离转向多近时开始显示地图',
                value: navigation.approachingTurnMeters.round(),
                suffix: ' m',
                min: 50,
                max: 500,
                step: 25,
                enabled: navigation.minimalByDefault && navigation.autoShowMap,
                onChanged: (v) => update(
                  (c) => c.copyWith(approachingTurnMeters: v.toDouble()),
                ),
              ),
            ],
          ),

          SettingsSection(
            title: '偏航处理',
            rows: [
              SettingsSwitch(
                title: '偏航后重新规划',
                subtitle: '偏离路线后自动从当前位置重新规划到终点',
                value: navigation.rerouteOnDeviation,
                onChanged: (v) =>
                    update((c) => c.copyWith(rerouteOnDeviation: v)),
              ),
              SettingsStepper(
                title: '偏航判定距离',
                subtitle: '偏离路线多远算作偏航；实际生效值不低于 30 米',
                value: navigation.rerouteThresholdMeters.round(),
                suffix: ' m',
                min: 20,
                max: 200,
                step: 5,
                enabled: navigation.rerouteOnDeviation,
                onChanged: (v) => update(
                  (c) => c.copyWith(rerouteThresholdMeters: v.toDouble()),
                ),
              ),
            ],
            footnote: '判定距离下限为 30 米：城市中高楼旁的定位误差常有 30–40 米，'
                '阈值过低会把每次经过桥下都当成偏航。',
          ),

          SettingsSection(
            title: '语音（V1.5）',
            rows: [
              SettingsSwitch(
                title: '语音提示',
                subtitle: '转向和偏航时播报语音提示',
                value: navigation.voicePrompts,
                onChanged: (v) => update((c) => c.copyWith(voicePrompts: v)),
              ),
            ],
            footnote: '语音播报属于 V1.5 范围，当前版本仅保留开关与接口。',
          ),
        ],
      ),
    );
  }
}
