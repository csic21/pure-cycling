import 'dart:async';

import 'package:cycling_app/features/auth/data/auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;

/// An auth repository whose events and password changes the test controls.
///
/// The real one is a thin wrapper around `Supabase.instance.client`, which a
/// test build cannot initialise — `SupabaseConfig.isConfigured` is a
/// compile-time constant and no credentials are passed. That makes the
/// recovery flow unreachable from a widget test unless the repository can be
/// substituted, which is exactly what this is for.
class FakeAuthRepository extends AuthRepository {
  final _events = StreamController<AuthChangeEvent>.broadcast();

  /// Every password handed to [updatePassword], in order.
  final List<String> savedPasswords = [];

  /// Set to make the next [updatePassword] fail the way the server would.
  AuthFailure? nextFailure;

  @override
  Stream<AuthChangeEvent> authEvents() => _events.stream;

  @override
  Future<void> updatePassword(String password) async {
    final failure = nextFailure;
    if (failure != null) {
      nextFailure = null;
      throw failure;
    }
    savedPasswords.add(password);
  }

  /// Fires the event the SDK emits after a reset link has been exchanged.
  void emitPasswordRecovery() =>
      _events.add(AuthChangeEvent.passwordRecovery);

  Future<void> dispose() => _events.close();
}
