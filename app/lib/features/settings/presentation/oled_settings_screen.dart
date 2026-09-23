import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/pixel_shift.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../../dashboard/domain/dashboard_config.dart';
import '../../dashboard/domain/dashboard_field.dart';
import '../../dashboard/presentation/dashboard_view.dart';
import '../../ride/domain/ride.dart';

/// OLED settings (spec §7, §39).
///
/// The preview is the point of this screen. Every one of these options is
/// about how the ride screen *looks in the sun*, and a list of switches cannot
/// answer whether 「极简模式」 is too sparse for a particular rider. So the page
/// carries a live, full-fidelity preview that responds to every toggle above
/// it.
class OledSettingsScreen extends ConsumerStatefulWidget {
  const OledSettingsScreen({super.key});

  @override
  ConsumerState<OledSettingsScreen> createState() => _OledSettingsScreenState();
}

class _OledSettingsScreenState extends ConsumerState<OledSettingsScreen> {
  bool _previewDimmed = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(currentSettingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final formatter = ref.watch(unitFormatterProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('OLED')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsSection(
            title: '显示',
            rows: [
              SettingsSwitch(
                title: 'OLED 模式',
                subtitle: '纯黑背景，最低功耗；关闭后使用常规深色界面',
                value: settings.oledMode,
                onChanged: (v) => notifier.mutate((s) => s.copyWith(oledMode: v)),
              ),
              SettingsSwitch(
                title: '屏幕常亮',
                subtitle: '骑行过程中保持屏幕开启',
                value: settings.keepScreenOn,
                onChanged: (v) {
                  notifier.mutate((s) => s.copyWith(keepScreenOn: v));
                  // Applied immediately so the rider can feel the effect here
                  // rather than discovering it mid-ride.
                  unawaited(
                    v ? WakelockPlus.enable() : WakelockPlus.disable(),
                  );
                },
              ),
            ],
          ),

          SettingsSection(
            title: '防烧屏',
            rows: [
              SettingsSwitch(
                title: 'Pixel Shift',
                subtitle: '每 45 秒将界面轻微偏移 ±2 像素，避免固定像素长期点亮',
                value: settings.pixelShift,
                enabled: settings.oledMode,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(pixelShift: v)),
              ),
              SettingsSwitch(
                title: '静止自动变暗',
                subtitle: '速度低于 1 km/h 持续 30 秒后降低亮度并隐藏次要数据',
                value: settings.dimOnStandstill,
                enabled: settings.oledMode,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(dimOnStandstill: v)),
              ),
              SettingsSwitch(
                title: '极简模式',
                subtitle: '静止时只保留速度、爬升和下一个转向',
                value: settings.minimalOled,
                enabled: settings.oledMode && settings.dimOnStandstill,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(minimalOled: v)),
              ),
            ],
            footnote: 'Pixel Shift 的偏移范围是固定的 ±2 像素：'
                '更大的位移在骑行中会被察觉为画面抖动，'
                '反而比烧屏更影响使用。',
          ),

          SettingsSection(
            title: '预览',
            rows: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  '下面的预览会应用上面的设置。点击可以在「骑行中」和「停车」两种状态之间切换。',
                  style: AppText.caption,
                ),
              ),
              const SizedBox(height: 12),
              _PreviewSurface(
                dimmed: _previewDimmed,
                pixelShiftEnabled: settings.oledMode && settings.pixelShift,
                dimOnStandstill: settings.dimOnStandstill,
                minimal: settings.minimalOled,
                formatter: formatter,
                onTap: () =>
                    setState(() => _previewDimmed = !_previewDimmed),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Center(
                  child: Text(
                    _previewDimmed ? '预览状态：停车（已变暗）' : '预览状态：骑行中',
                    style: AppText.caption.copyWith(
                      color: _previewDimmed
                          ? AppColors.warning
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({
    required this.dimmed,
    required this.pixelShiftEnabled,
    required this.dimOnStandstill,
    required this.minimal,
    required this.formatter,
    required this.onTap,
  });

  final bool dimmed;
  final bool pixelShiftEnabled;
  final bool dimOnStandstill;
  final bool minimal;
  final UnitFormatter formatter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final data = DashboardData(
      // Fixed values rather than live ones: the preview has to look the same
      // every time, so a rider comparing two settings is comparing the
      // settings and not two different moments on a stationary phone.
      stats: _previewStats,
      gpsAccuracyMeters: 6,
      now: DateTime.now(),
    );

    final page = DashboardPage(
      layout: DashboardLayout.hero4,
      fields: const [
        DashboardField.speed,
        DashboardField.distance,
        DashboardField.movingTime,
        DashboardField.avgSpeed,
        DashboardField.elevationGain,
      ],
    );

    final isDimmed = dimmed && dimOnStandstill;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        height: 300,
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.hairlineStrong),
          borderRadius: BorderRadius.circular(16),
        ),
        // Clip.hardEdge so the pixel-shift offset does not escape the preview
        // frame — the ride screen itself allows the offset to overhang.
        clipBehavior: Clip.hardEdge,
        child: PixelShiftScope(
          enabled: pixelShiftEnabled,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: isDimmed ? 0.45 : 1.0,
            child: DashboardView(
              page: page,
              data: data,
              formatter: formatter,
              dimmed: isDimmed,
              minimal: minimal && isDimmed,
            ),
          ),
        ),
      ),
    );
  }
}

/// Representative numbers for the preview, matching the spec's mock-up.
const RideStats _previewStats = RideStats(
  distanceMeters: 23820,
  elapsed: Duration(hours: 1, minutes: 2, seconds: 36),
  moving: Duration(hours: 1, minutes: 2, seconds: 36),
  // 28.6 km/h.
  currentSpeedMps: 7.944,
  // 22.9 km/h.
  avgSpeedMps: 6.361,
  maxSpeedMps: 10.722,
  altitudeMeters: 62,
  elevationGainMeters: 384,
  elevationLossMeters: 372,
  gradePercent: 1.8,
);
