import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/sync/account_deletion_client.dart';
import '../../../core/sync/functions_config.dart';
import '../../../core/sync/supabase_config.dart';
import '../../../core/sync/sync_service.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/settings_widgets.dart';
import 'widgets/account_section.dart';
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
            AccountSection(user: user),
            _StatusSection(report: report, settings: settings),
            if (user != null)
              SettingsSection(
                title: '云端数据',
                rows: [
                  SettingsTile(
                    title: '删除云端数据',
                    subtitle: '删除云端保存的全部骑行、路线和 GPX 文件。'
                        '本机记录不受影响，会变成「待上传」；云同步会同时关闭。',
                    leading: const Icon(Icons.delete_outline,
                        color: AppColors.danger),
                    onTap: () => _confirmDeleteCloudData(context, ref),
                  ),
                  if (FunctionsConfig.isConfigured)
                    SettingsTile(
                      title: '删除账号',
                      subtitle: '永久删除账号和云端的全部数据。本机记录保留，'
                          '但不会再有备份，也不再用这个账号登录。',
                      leading: const Icon(Icons.person_remove_outlined,
                          color: AppColors.danger),
                      onTap: () => _confirmDeleteAccount(context, ref),
                    ),
                ],
                footnote: FunctionsConfig.isConfigured
                    ? '删除用你自己的登录令牌完成，服务端按行级权限校验，没有旁路。'
                        '删除后如果重新打开云同步，会重新备份一遍。'
                    : '这个构建没有配置在线服务地址：删除云端数据仍可用，'
                        '删除账号请联系运营方。',
              ),
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

/// Confirms and performs "delete my cloud data".
///
/// The order matters: the switch goes off *first*, so even a failed deletion
/// cannot be followed by the next sync putting everything back. Deleting is
/// the promise; turning uploads off is what keeps it.
Future<void> _confirmDeleteCloudData(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除云端数据？'),
      content: const Text(
        '将删除你账号下云端的全部骑行、路线和 GPX 文件。\n\n'
        '本机记录不会被删除，它们会变成「待上传」。云同步会同时关闭——'
        '否则下一次同步会立刻把刚删掉的东西重新传上去。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: Colors.black,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除并关闭云同步'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await ref
      .read(settingsProvider.notifier)
      .mutate((s) => s.copyWith(cloudSync: false));

  final report = await ref.read(syncServiceProvider).deleteCloudData();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(report.summary)));
}

/// Confirms and performs self-service account deletion.
///
/// The local bookkeeping is deliberately *not* the same as the cloud wipe's:
/// with the account gone there is nowhere to upload to, so the queue is
/// cleared instead of re-filled. A queue that can never drain would sit there
/// saying 「待上传 N 条」 for the rest of the install's life.
Future<void> _confirmDeleteAccount(BuildContext context, WidgetRef ref) async {
  // Captured before the first await: after sign-out this widget's context may
  // no longer be mounted, and the confirmation has to be able to report what
  // happened either way.
  final messenger = ScaffoldMessenger.of(context);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除账号？'),
      content: const Text(
        '将永久删除你的账号，以及云端的全部骑行、路线和 GPX 文件。\n\n'
        '本机记录会保留，但不会再备份到云端，也不能再用这个账号登录。'
        '这一步不可恢复。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: Colors.black,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('永久删除账号'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    final files = await ref.read(accountDeletionClientProvider).deleteAccount();
    await ref.read(syncServiceProvider).forgetCloudCopy(requeue: false);
    await ref
        .read(settingsProvider.notifier)
        .mutate((s) => s.copyWith(cloudSync: false));
    await ref.read(authRepositoryProvider).signOut();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          files > 0
              ? '账号已删除。本机记录仍在，云端 $files 个 GPX 已清理。'
              : '账号已删除。本机记录仍在。',
        ),
      ),
    );
  } on AccountDeletionException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
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
          subtitle: settings.cloudSync
              ? '已开启：上传摘要、轨迹和路线，用于换手机后找回'
              : '已关闭：不会上传任何内容，手动同步也不会',
          value: settings.cloudSync,
          onChanged: (v) =>
              ref.read(settingsProvider.notifier).mutate((s) => s.copyWith(cloudSync: v)),
        ),
        const SettingsTile(
          // Stated once, always visible, so the switch is an informed choice
          // rather than a toggle whose consequences show up later.
          title: '会上传什么',
          subtitle: '骑行摘要（距离、时间、速度、爬升）、完整轨迹（GPX 文件）、'
              '保存的路线和你的设置。不上传通讯录、广告标识或其它应用的数据。',
          leading: Icon(Icons.cloud_upload_outlined),
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
            subtitle: settings.cloudSync
                ? '网络恢复后会自动上传'
                : '打开云同步后才会上传',
            leading: const Icon(Icons.cloud_upload_outlined,
                color: AppColors.warning),
          ),
        // The button disappears when the switch is off instead of sitting
        // there disabled: there is nothing to press, and offering a dead
        // control next to a privacy switch reads as a loophole.
        if (settings.cloudSync)
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
        SyncPhase.disabled => Icons.lock_outline,
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
        SyncPhase.disabled => '云同步已关闭',
        SyncPhase.idle => '已就绪',
      };
}
