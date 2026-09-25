import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/sync/supabase_config.dart';
import '../../../core/sync/sync_service.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../../auth/data/auth_repository.dart';

/// The settings tree (spec §39).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(currentSettingsProvider);
    final sync = ref.watch(syncReportProvider).valueOrNull;
    final user = ref.watch(authUserProvider).valueOrNull;
    final formatter = UnitFormatter(settings.units);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsSection(
            title: '骑行',
            rows: [
              SettingsTile(
                title: '自动暂停',
                subtitle: settings.autoPause ? '已开启' : '已关闭',
                leading: const Icon(Icons.pause_circle_outline),
                onTap: () => context.push(AppRoutes.settingsRide),
              ),
              SettingsTile(
                title: 'GPS 精度',
                subtitle: settings.gpsAccuracy.label,
                leading: const Icon(Icons.gps_fixed),
                onTap: () => context.push(AppRoutes.settingsRide),
              ),
              SettingsTile(
                title: '倒计时开始',
                subtitle: settings.startCountdown.label,
                leading: const Icon(Icons.timer_outlined),
                onTap: () => context.push(AppRoutes.settingsRide),
              ),
            ],
          ),

          SettingsSection(
            title: '码表',
            rows: [
              SettingsTile(
                title: '页面布局',
                subtitle:
                    '${settings.dashboard.pages.length} 个页面 · '
                    '${settings.dashboard.pages.first.layout.label}',
                leading: const Icon(Icons.dashboard_customize_outlined),
                onTap: () => context.push(AppRoutes.settingsDashboard),
              ),
            ],
          ),

          SettingsSection(
            title: 'OLED',
            rows: [
              SettingsTile(
                title: 'OLED 模式',
                subtitle: settings.oledMode ? '已开启' : '已关闭',
                leading: const Icon(Icons.contrast),
                onTap: () => context.push(AppRoutes.settingsOled),
              ),
              SettingsTile(
                title: 'Pixel Shift 防烧屏',
                subtitle: settings.pixelShift ? '已开启' : '已关闭',
                leading: const Icon(Icons.blur_on),
                onTap: () => context.push(AppRoutes.settingsOled),
              ),
            ],
          ),

          SettingsSection(
            title: '导航',
            rows: [
              SettingsTile(
                title: '导航偏好',
                subtitle: settings.navigation.autoShowMap ? '自动显示地图' : '仅极简导航',
                leading: const Icon(Icons.navigation_outlined),
                onTap: () => context.push(AppRoutes.settingsNavigation),
              ),
              SettingsTile(
                title: '地图服务',
                subtitle: ref.watch(routingAvailabilityProvider).available
                    ? '高德（骑行路线）'
                    : '未配置 Key',
                leading: const Icon(Icons.map_outlined),
                onTap: () => context.push(AppRoutes.settingsMap),
              ),
            ],
          ),

          SettingsSection(
            title: '单位',
            rows: [
              SettingsTile(
                title: '单位制',
                subtitle: settings.units.label,
                trailingText:
                    '${formatter.system.distanceSuffix} · ${formatter.system.speedSuffix}',
                leading: const Icon(Icons.straighten),
                onTap: () => context.push(AppRoutes.settingsUnits),
              ),
            ],
          ),

          SettingsSection(
            title: '设备',
            rows: [
              SettingsTile(
                title: '传感器',
                subtitle: '心率带 · 踏频器 · 功率计',
                leading: const Icon(Icons.bluetooth),
                onTap: () => context.push(AppRoutes.settingsSensors),
              ),
            ],
          ),

          SettingsSection(
            title: '数据',
            rows: [
              SettingsTile(
                title: '云同步',
                subtitle: _syncSubtitle(sync, user),
                leading: const Icon(Icons.cloud_outlined),
                trailing: sync?.isBusy == true
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: () => context.push(AppRoutes.settingsSync),
              ),
              SettingsTile(
                title: '诊断日志',
                subtitle: '应用出错时的记录。没有位置轨迹，也不会自动上传',
                leading: const Icon(Icons.description_outlined),
                onTap: () => context.push(AppRoutes.settingsDiagnostics),
              ),
            ],
            footnote: SupabaseConfig.isConfigured
                ? null
                : '云同步未配置：${SupabaseConfig.configurationHint}。'
                    '所有功能在本地都可以正常使用。',
          ),

          const SizedBox(height: 24),
          Center(
            child: Text(
              '纯粹骑行 · 记录、码表、导航\n没有社区，没有信息流',
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  static String _syncSubtitle(SyncReport? report, AuthUser? user) {
    // The switch outranks the session state: "已关闭" is the fact that matters,
    // and it stays true whether or not someone is signed in.
    if (report?.phase == SyncPhase.disabled) return '已关闭';
    if (!SupabaseConfig.isConfigured) return '未配置';
    if (user == null) return '未登录';
    if (report == null) return '已登录';
    return switch (report.phase) {
      SyncPhase.disabled => '已关闭',
      SyncPhase.syncing => '同步中…',
      SyncPhase.offline => '离线',
      SyncPhase.failed => report.message ?? '同步失败',
      SyncPhase.notConfigured => '未配置',
      SyncPhase.signedOut => '未登录',
      SyncPhase.idle => report.lastSyncedAt == null
          ? '已登录，尚未同步'
          : '上次同步 ${UnitFormatter.clock(report.lastSyncedAt!)}'
              '${report.pendingCount > 0 ? '，待上传 ${report.pendingCount}' : ''}',
    };
  }
}
