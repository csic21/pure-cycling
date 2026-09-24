import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/sync/supabase_config.dart';
import '../../auth/data/auth_repository.dart';

/// Sign in (spec §2.1, §40 Sprint 0).
///
/// The screen's first job is to explain that signing in is optional. This app
/// records rides entirely offline, and a login wall in front of that would
/// contradict the whole design — so the "跳过，仅本地使用" action is a
/// first-class button, not a small grey link.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _busy = false;
  bool _isSignUp = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configured = SupabaseConfig.isConfigured;

    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
        children: [
          const SizedBox(height: 8),
          const Text(
            '登录后可以把骑行备份到云端，并在新手机上恢复。',
            style: AppText.body,
          ),
          const SizedBox(height: 6),
          const Text(
            '不登录也可以完整使用：记录、码表、历史、GPX 导出全部在本地完成。',
            style: AppText.caption,
          ),
          const SizedBox(height: 28),

          if (!configured) ...[
            _Banner(
              icon: Icons.info_outline,
              tone: AppColors.warning,
              text: '当前构建没有配置 Supabase，无法登录。'
                  '${SupabaseConfig.configurationHint}。',
            ),
            const SizedBox(height: 20),
          ],

          TextField(
            controller: _emailController,
            enabled: configured && !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '邮箱',
              hintText: 'you@example.com',
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passwordController,
            enabled: configured && !_busy,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '密码',
              hintText: _isSignUp ? '至少 6 位' : null,
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            _Banner(
              icon: Icons.error_outline,
              tone: AppColors.danger,
              text: _error!,
            ),
          ],

          if (_notice != null) ...[
            const SizedBox(height: 16),
            _Banner(
              icon: Icons.mark_email_unread_outlined,
              tone: AppColors.success,
              text: _notice!,
            ),
          ],

          const SizedBox(height: 28),
          FilledButton(
            onPressed: configured && !_busy ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : Text(_isSignUp ? '注册' : '登录'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _isSignUp = !_isSignUp),
            child: Text(_isSignUp ? '已有账号？去登录' : '没有账号？注册一个'),
          ),

          if (!_isSignUp) ...[
            TextButton(
              onPressed: _busy || !configured ? null : _resetPassword,
              child: const Text('忘记密码'),
            ),
          ],

          const Divider(height: 40),

          OutlinedButton(
            onPressed: configured && !_busy ? _signInAnonymously : null,
            child: const Text('先匿名使用'),
          ),
          const SizedBox(height: 8),
          const Text(
            '匿名账号同样会把骑行同步到云端，之后可以随时绑定邮箱。',
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 24),
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('跳过，仅本地使用'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写邮箱和密码');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    try {
      final auth = ref.read(authRepositoryProvider);
      if (_isSignUp) {
        final user = await auth.signUp(email: email, password: password);
        if (!mounted) return;
        if (user == null) {
          setState(() {
            _busy = false;
            _error = '注册失败';
          });
          return;
        }
        // With email confirmation on, a successful sign-up returns no session.
        if (!auth.isSignedIn) {
          setState(() {
            _busy = false;
            _notice = '注册成功。请到邮箱点击验证链接 —— '
                '点击后会自动回到 App 并登录，不用再输一次密码。';
            _isSignUp = false;
          });
          return;
        }
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }

      if (!mounted) return;
      await ref.read(syncServiceProvider).syncNow(force: true);
      if (mounted) context.pop();
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '操作失败：$e';
      });
    }
  }

  Future<void> _signInAnonymously() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).signInAnonymously();
      if (!mounted) return;
      context.pop();
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = '请先填写邮箱');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).sendPasswordReset(email);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = '重置邮件已发送，请查收。';
      });
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.tone,
  });

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
