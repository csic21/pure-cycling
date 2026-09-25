import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/providers.dart';
import '../../../../app/router.dart';
import '../../../../app/theme.dart';
import '../../../auth/data/auth_repository.dart';
import '../../../../shared/widgets/settings_widgets.dart';

/// The signed-in account, and what can be done with it.
///
/// Extracted from the sync screen so it can be rendered directly. The sync
/// screen only shows it when Supabase is configured, and `isConfigured` is a
/// compile-time constant — a test build can never have credentials — so this
/// section would otherwise be unreachable from a test, and its
/// anonymous-account branch would go untested. That branch is exactly the kind
/// of thing that breaks silently: the login screen promises the rider can
/// attach an address later, and nothing else would notice if the way to do it
/// disappeared.
class AccountSection extends ConsumerWidget {
  const AccountSection({super.key, required this.user});

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

    final isAnonymous = user!.isAnonymous;

    return SettingsSection(
      title: '账号',
      rows: [
        SettingsTile(
          title: user!.label,
          subtitle: isAnonymous ? '匿名账号 · 换手机后无法找回' : '已登录',
          leading: Icon(
            isAnonymous ? Icons.person_outline : Icons.verified_user_outlined,
            color: isAnonymous ? AppColors.warning : AppColors.success,
          ),
        ),
        if (isAnonymous)
          // Without this the account is tied to one device's storage: a
          // reinstall or a new phone has no way back in, and every ride synced
          // under it becomes unreachable.
          SettingsTile(
            title: '绑定邮箱',
            subtitle: '绑定后可在其他手机上找回骑行记录',
            leading: const Icon(Icons.alternate_email),
            onTap: () => _attachEmail(context, ref),
          ),
        SettingsTile(
          title: '退出登录',
          destructive: true,
          leading: const Icon(Icons.logout, color: AppColors.danger),
          onTap: () => _confirmSignOut(context, ref),
        ),
      ],
      footnote: isAnonymous
          ? '匿名账号的骑行同样会上传到云端，但只有绑定邮箱之后才能在新手机上取回。'
          : '退出登录不会删除任何本地记录。',
    );
  }

  /// Attaches an address to an anonymous account.
  ///
  /// The account id does not change, so every ride already synced under it
  /// stays attached — this adds a way back in, it does not move anything.
  Future<void> _attachEmail(BuildContext context, WidgetRef ref) async {
    final submitted = await showDialog<({String email, String password})>(
      context: context,
      builder: (_) => const _AttachEmailDialog(),
    );

    if (submitted == null || !context.mounted) return;

    final address = submitted.email;
    final secret = submitted.password;

    if (address.isEmpty || secret.length < 6) {
      _showMessage(context, '请填写邮箱，密码至少 6 位');
      return;
    }

    try {
      await ref
          .read(authRepositoryProvider)
          .attachEmail(email: address, password: secret);
      if (!context.mounted) return;
      _showMessage(context, '已绑定，请到邮箱点击验证链接');
    } on AuthFailure catch (e) {
      if (!context.mounted) return;
      _showMessage(context, e.message);
    }
  }

  static void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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

/// Collects the address and password for binding an anonymous account.
///
/// It owns its controllers, and that is the whole reason it is a widget. The
/// dialog's exit animation keeps rebuilding its fields after `showDialog`
/// resolves, so controllers disposed at that moment are *used after dispose* —
/// which throws during a rebuild rather than leaking quietly.
class _AttachEmailDialog extends StatefulWidget {
  const _AttachEmailDialog();

  @override
  State<_AttachEmailDialog> createState() => _AttachEmailDialogState();
}

class _AttachEmailDialogState extends State<_AttachEmailDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('绑定邮箱'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '已同步的骑行不会受影响，只是多了一种登录方式。',
            style: AppText.caption,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '邮箱'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '设置密码',
              helperText: '至少 6 位',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (email: _email.text.trim(), password: _password.text),
          ),
          child: const Text('绑定'),
        ),
      ],
    );
  }
}
