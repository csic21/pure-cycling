import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/sync/supabase_config.dart';
import '../data/auth_repository.dart';

/// Chooses a new password after a reset link has been opened.
///
/// The link is not the change. Supabase exchanges it for a session that proves
/// the rider owns the address, and the password is only replaced by the call
/// this screen makes. Without this step the app lands on a signed-in account
/// whose old password still works — the rider believes the reset succeeded and
/// nothing is actually better.
///
/// Deliberately not dismissible with a back gesture: there is no "back" from
/// here that leads somewhere sensible. 稍后再说 is the explicit exit, and it
/// keeps the session so the rider can reset again.
class SetPasswordScreen extends ConsumerStatefulWidget {
  const SetPasswordScreen({super.key});

  @override
  ConsumerState<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends ConsumerState<SetPasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('设置新密码'),
          automaticallyImplyLeading: false,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
          children: [
            const SizedBox(height: 8),
            const Text(
              '重置链接已验证你的邮箱。',
              style: AppText.body,
            ),
            const SizedBox(height: 6),
            const Text(
              '下面设置一个新的登录密码，设置成功后立刻生效。在此之前，'
              '旧密码仍然可以使用。',
              style: AppText.caption,
            ),
            const SizedBox(height: 28),

            if (!SupabaseConfig.isConfigured) ...[
              _Banner(
                icon: Icons.info_outline,
                tone: AppColors.warning,
                text: '当前构建没有配置云同步，无法修改密码。',
              ),
              const SizedBox(height: 20),
            ],

            TextField(
              controller: _passwordController,
              enabled: !_busy,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '新密码',
                helperText: '至少 6 位',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _confirmController,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(labelText: '再输一次'),
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              _Banner(
                icon: Icons.error_outline,
                tone: AppColors.danger,
                text: _error!,
              ),
            ],

            const SizedBox(height: 28),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Text('保存新密码'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : _later,
              child: const Text('稍后再说'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (password.length < 6) {
      setState(() => _error = '密码太短，至少需要 6 位');
      return;
    }
    if (password != confirm) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).updatePassword(password);
      ref.read(passwordRecoveryProvider.notifier).clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码已更新，下次登录请使用新密码')),
      );
      context.go(AppRoutes.home);
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// Leaves without changing anything. The session is already signed in, so
  /// the rider keeps using the app; the old password keeps working until they
  /// ask for another link.
  void _later() {
    ref.read(passwordRecoveryProvider.notifier).clear();
    context.go(AppRoutes.home);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.tone});

  final IconData icon;
  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: tone.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: AppText.caption.copyWith(color: tone)),
          ),
        ],
      ),
    );
  }
}
