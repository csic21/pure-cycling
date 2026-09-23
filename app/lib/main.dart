import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/sync/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _initSupabase();

  runApp(const ProviderScope(child: CyclingApp()));
}

/// Initialises Supabase when credentials were supplied at build time.
///
/// Failure here is not fatal and must not be: the app records rides entirely
/// offline (spec §15). A malformed URL or an unreachable project means cloud
/// sync is unavailable, not that the app cannot start — so the error is
/// swallowed and the sync screen reports the state it finds itself in.
Future<void> _initSupabase() async {
  if (!SupabaseConfig.isConfigured) return;

  try {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      // The SDK renamed this from `anonKey`; both are the same publishable
      // credential, and it must never be the service_role key (spec §25).
      publishableKey: SupabaseConfig.anonKey,
      // Kept so the session is refreshed while the app is in the foreground —
      // a ride that ends four hours after sign-in still uploads.
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: true,
      ),
    );
  } catch (error, stack) {
    debugPrint('Supabase 初始化失败，将以本地模式运行：$error');
    debugPrintStack(stackTrace: stack);
  }
}
