import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/settings_widgets.dart';

/// Unit settings (spec §39).
///
/// The sample readout underneath is the whole point: "imperial" means nothing
/// until a rider sees that their 40 km ride becomes 24.9 mi, and seeing it
/// here avoids discovering it on the bike.
class UnitsSettingsScreen extends ConsumerWidget {
  const UnitsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(currentSettingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final formatter = UnitFormatter(settings.units);

    return Scaffold(
      appBar: AppBar(title: const Text('单位')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsSection(
            title: '单位制',
            rows: [
              SettingsChoice<UnitSystem>(
                title: '显示单位',
                value: settings.units,
                options: [
                  for (final system in UnitSystem.values)
                    (value: system, label: system.label),
                ],
                onChanged: (v) => notifier.mutate((s) => s.copyWith(units: v)),
              ),
            ],
            footnote: '存储始终以米和米/秒进行，切换单位不会改变任何已记录的数据。',
          ),

          SettingsSection(
            title: '预览',
            rows: [
              _SampleRow(
                label: '距离',
                value:
                    '${formatter.distanceKm(42300)} ${formatter.system.distanceSuffix}',
              ),
              _SampleRow(
                label: '速度',
                value:
                    '${formatter.speed(6.36)} ${formatter.system.speedSuffix}',
              ),
              _SampleRow(
                label: '海拔',
                value: formatter.elevationWithUnit(486),
              ),
              _SampleRow(
                label: '爬升',
                value: formatter.elevationWithUnit(384, withSign: true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SampleRow extends StatelessWidget {
  const _SampleRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppText.caption),
          Text(value, style: AppText.value.copyWith(fontSize: 20)),
        ],
      ),
    );
  }
}
