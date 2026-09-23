import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/sync/supabase_config.dart';

/// Why a sign-in attempt failed, in terms a rider can act on.
class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.isConfiguration = false});

  final String message;
  final bool isConfiguration;

  @override
  String toString() => message;
}

/// The signed-in account, reduced to what the UI needs.
class AuthUser {
  const AuthUser({required this.id, this.email, this.displayName});

  final String id;
  final String? email;
  final String? displayName;

  String get label {
    if (displayName != null && displayName!.trim().isNotEmpty) {
      return displayName!.trim();
    }
    return email ?? '已登录';
  }
}

/// Authentication against Supabase Auth.
///
/// The app is usable signed out — local recording never depends on a session
/// (spec §15). Signing in exists to back up rides and to restore them on a new
/// phone, so every method here degrades to "not available" rather than
/// blocking anything.
class AuthRepository {
  AuthRepository({SupabaseClient? client}) : _client = client;

  SupabaseClient? _client;

  /// Resolved lazily so a build with no Supabase configuration never touches
  /// the SDK at all.
  SupabaseClient? get _c {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return _client ??= Supabase.instance.client;
    } catch (_) {
      // Supabase.initialize has not run — a configuration race during startup.
      return null;
    }
  }

  bool get isConfigured => SupabaseConfig.isConfigured;

  bool get isSignedIn => currentUser != null;

  AuthUser? get currentUser {
    final user = _c?.auth.currentUser;
    if (user == null) return null;
    return _toAuthUser(user);
  }

  /// Emits on sign-in, sign-out and token refresh. Emits the current value
  /// immediately so a listener does not have to also poll.
  Stream<AuthUser?> authStateChanges() {
    final client = _c;
    if (client == null) {
      return Stream<AuthUser?>.value(null);
    }
    return Stream<AuthUser?>.multi((controller) {
      controller.add(
        client.auth.currentUser == null
            ? null
            : _toAuthUser(client.auth.currentUser!),
      );
      final sub = client.auth.onAuthStateChange.listen(
        (event) {
          final user = event.session?.user;
          controller.add(user == null ? null : _toAuthUser(user));
        },
        onError: controller.addError,
      );
      controller.onCancel = sub.cancel;
    });
  }

  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
  }) async {
    final client = _requireClient();
    try {
      final response = await client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      final user = response.user;
      if (user == null) {
        throw const AuthFailure('登录失败：未返回用户信息');
      }
      await _ensureProfile(user);
      return _toAuthUser(user);
    } on AuthException catch (e) {
      throw AuthFailure(_describe(e));
    }
  }

  Future<AuthUser?> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final client = _requireClient();
    try {
      final response = await client.auth.signUp(
        email: email.trim(),
        password: password,
        data: displayName == null ? null : {'display_name': displayName},
      );
      final user = response.user;
      if (user == null) return null;
      // With email confirmation enabled, `session` is null until the rider
      // clicks the link — a success, but not a signed-in one.
      if (response.session != null) {
        await _ensureProfile(user, displayName: displayName);
      }
      return _toAuthUser(user);
    } on AuthException catch (e) {
      throw AuthFailure(_describe(e));
    }
  }

  /// Signs in anonymously.
  ///
  /// Anonymous accounts still get a real `auth.users` row, so rides sync and
  /// survive a reinstall on the same device. Anonymous sign-in must be enabled
  /// in the Supabase project for this to work; if it is not, the error is
  /// surfaced verbatim rather than swallowed.
  Future<AuthUser> signInAnonymously() async {
    final client = _requireClient();
    try {
      final response = await client.auth.signInAnonymously();
      final user = response.user;
      if (user == null) {
        throw const AuthFailure('匿名登录失败');
      }
      await _ensureProfile(user);
      return _toAuthUser(user);
    } on AuthException catch (e) {
      throw AuthFailure(
        _describe(e),
        isConfiguration: true,
      );
    }
  }

  Future<void> sendPasswordReset(String email) async {
    final client = _requireClient();
    try {
      await client.auth.resetPasswordForEmail(email.trim());
    } on AuthException catch (e) {
      throw AuthFailure(_describe(e));
    }
  }

  Future<void> signOut() async {
    await _c?.auth.signOut();
  }

  /// Creates the `profiles` row on first sign-in.
  ///
  /// The row is otherwise only created by a database trigger, which does not
  /// exist for accounts created before the trigger was installed — so this is
  /// a repair path as much as an initialisation one. Failures are ignored: a
  /// missing display name must never block a sign-in.
  Future<void> _ensureProfile(User user, {String? displayName}) async {
    final client = _c;
    if (client == null) return;
    try {
      final existing = await client
          .from('profiles')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();
      if (existing != null) return;

      await client.from('profiles').upsert({
        'id': user.id,
        'display_name': displayName ??
            user.userMetadata?['display_name'] as String? ??
            user.email?.split('@').first,
      });
    } catch (_) {
      // Non-fatal.
    }
  }

  SupabaseClient _requireClient() {
    final client = _c;
    if (client == null) {
      throw const AuthFailure(
        '云同步未配置，无法登录。应用仍可在本地记录骑行。',
        isConfiguration: true,
      );
    }
    return client;
  }

  static AuthUser _toAuthUser(User user) => AuthUser(
        id: user.id,
        email: user.email,
        displayName: user.userMetadata?['display_name'] as String?,
      );

  /// Maps Supabase's error text to something a Chinese-speaking rider can
  /// act on. Unknown messages pass through unchanged rather than being
  /// flattened into a generic failure — an unexplained error is worse than an
  /// English one.
  static String _describe(AuthException e) {
    final message = e.message.toLowerCase();
    if (message.contains('invalid login credentials')) {
      return '邮箱或密码不正确';
    }
    if (message.contains('email not confirmed')) {
      return '邮箱尚未验证，请先点击验证邮件中的链接';
    }
    if (message.contains('user already registered')) {
      return '该邮箱已注册，请直接登录';
    }
    if (message.contains('password should be at least')) {
      return '密码太短，至少需要 6 位';
    }
    if (message.contains('anonymous sign-ins are disabled')) {
      return '该项目未开启匿名登录，请在 Supabase 控制台启用';
    }
    if (message.contains('rate limit') || e.statusCode == '429') {
      return '操作过于频繁，请稍后再试';
    }
    if (message.contains('network') || message.contains('socket')) {
      return '网络不可用，请检查连接';
    }
    return e.message;
  }
}
