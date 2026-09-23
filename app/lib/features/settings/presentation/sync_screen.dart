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
import '../domain/app_settings.dart';

/// Cloud sync (spec §16, §25, §39).
///
/// The screen leads with the local-first truth rather than burying it: rides
/// live on this device, the cloud is a backup, and nothing here can lose a
/// ride. A rider who understands that will trust the app on a mountain pass
/// with no signal — which is the entire design premise.
class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(currentSettingsProvider);
    final report = ref.watch(syncReportProvider).valueOrNull;
    final user = ref.watch(authUserProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('云同步')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          if (!SupabaseConfig.isConfigured)
            SettingsSection(
              title: '未配置',
              rows: [
                SettingsTile(
                  title: '云同步未启用',
                  subtitle: '${SupabaseConfig.configurationHint}。'
                      '应用仍可完整使用：记录、码表、历史、GPX 导出都在本地完成。',
                  leading: const Icon(Icons.info_outline),
                ),
              ],
              footnote: '如需启用，请在构建时通过 '
                  '--dart-define=SUPABASE_URL=... 与 '
                  '--dart-define=SUPABASE_ANON_KEY=... 传入配置。',
            )
          else ...[
            _AccountSection(user: user),
            _StatusSection(report: report, settings: settings),
          ],

          SettingsSection(
            title: '本地数据',
            rows: [
              const SettingsTile(
                title: '本地优先',
                subtitle: '骑行过程中所有数据先写入本机数据库，不依赖网络。'
                    '同步失败只会重新排队，永远不会删除本地记录。',
                leading: Icon(Icons.phone_android),
              ),
              const SettingsTile(
                title: '轨迹点不会逐点上传',
                subtitle: '云端保存骑行摘要和一条轨迹线，完整轨迹以 GPX 文件存放在存储中。'
                    '一次三小时的骑行只占一行，而不是一万行。',
                leading: Icon(Icons.storage_outlined),
              ),
            ],
          ),

          SettingsSection(
            title: '隐私',
            rows: [
              const SettingsTile(
                title: '位置数据不公开',
                subtitle: '所有骑行记录默认为私有。没有公开链接、没有分享流、'
                    '没有关注和排行榜。存储桶是私有的，只有本人可读。',
                leading: Icon(Icons.lock_outline),
              ),
              const SettingsTile(
                title: '不采集无关信息',
                subtitle: '不读取通讯录、不获取广告标识。',
                leading: Icon(Icons.shield_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccountSection extends ConsumerWidget {
  const _AccountSection({required this.user});

  final AuthUser? user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (user == null) {
      return SettingsSection(
        title: '账号',
        rows: [
          SettingsTile(
            title: '登录以启用云同步',
            subtitle: '登录后可以把骑行备份到云端，并在新手机上恢复',
            leading: const Icon(Icons.login),
            onTap: () => context.push(AppRoutes.login),
          ),
        ],
      );
    }

    return SettingsSection(
      title: '账号',
      rows: [
        SettingsTile(
          title: user!.label,
          subtitle: '已登录',
          leading: const Icon(Icons.person_outline),
        ),
        SettingsTile(
          title: '退出登录',
          destructive: true,
          leading: const Icon(Icons.logout, color: AppColors.danger),
          onTap: () => _confirmSignOut(context, ref),
        ),
      ],
      footnote: '退出登录不会删除任何本地记录。',
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('本地记录会全部保留，只是不再上传到云端。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await ref.read(authRepositoryProvider).signOut();
  }
}

class _StatusSection extends ConsumerWidget {
  const _StatusSection({required this.report, required this.settings});

  final SyncReport? report;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = report ?? const SyncReport();

    return SettingsSection(
      title: '同步',
      rows: [
        SettingsSwitch(
          title: '启用云同步',
          subtitle: '关闭后不会上传，但仍可手动同步',
          value: settings.cloudSync,
          onChanged: (v) =>
              ref.read(settingsProvider.notifier).mutate((s) => s.copyWith(cloudSync: v)),
        ),
        SettingsSwitch(
          title: '仅 Wi-Fi 上传',
          subtitle: '避免在移动网络下消耗流量',
          value: settings.wifiOnlyUpload,
          enabled: settings.cloudSync,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .mutate((s) => s.copyWith(wifiOnlyUpload: v)),
        ),
        ListTile(
          leading: Icon(_iconFor(current.phase), color: _colorFor(current.phase)),
          title: Text(_labelFor(current.phase), style: AppText.body),
          subtitle: Text(
            current.message ??
                (current.lastSyncedAt == null
                    ? '尚未同步'
                    : '上次同步 ${UnitFormatter.durationCompact(DateTime.now().difference(current.lastSyncedAt!))}前'),
            style: AppText.caption,
          ),
          trailing: current.isBusy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        if (current.pendingCount > 0)
          SettingsTile(
            title: '待上传 ${current.pendingCount} 条',
            subtitle: '网络恢复后会自动上传',
            leading: const Icon(Icons.cloud_upload_outlined,
                color: AppColors.warning),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: FilledButton(
            onPressed: current.isBusy
                ? null
                : () => ref.read(syncServiceProvider).syncNow(force: true),
            child: const Text('立即同步'),
          ),
        ),
      ],
    );
  }

  static IconData _iconFor(SyncPhase phase) => switch (phase) {
        SyncPhase.syncing => Icons.sync,
        SyncPhase.failed => Icons.cloud_off,
        SyncPhase.offline => Icons.wifi_off,
        SyncPhase.signedOut => Icons.person_off_outlined,
        SyncPhase.notConfigured => Icons.settings_outlined,
        SyncPhase.idle => Icons.cloud_done_outlined,
      };

  static Color _colorFor(SyncPhase phase) => switch (phase) {
        SyncPhase.failed => AppColors.danger,
        SyncPhase.offline => AppColors.warning,
        SyncPhase.syncing => AppColors.accent,
        _ => AppColors.textSecondary,
      };

  static String _labelFor(SyncPhase phase) => switch (phase) {
        SyncPhase.syncing => '同步中…',
        SyncPhase.failed => '同步失败',
        SyncPhase.offline => '离线',
        SyncPhase.signedOut => '未登录',
        SyncPhase.notConfigured => '未配置',
        SyncPhase.idle => '已就绪',
      };
}
