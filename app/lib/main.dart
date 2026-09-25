import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/diagnostics/diagnostic_log.dart';
import 'core/diagnostics/error_reporting.dart';
import 'core/sync/supabase_config.dart';

Future<void> main() async {
  // One log for the process, handed to the provider graph so the settings
  // screen exports exactly what these handlers wrote.
  final log = DiagnosticLog();

  installErrorHandlers(log);

  // The zone is the last net: an error raised in a callback that no framework
  // hook owns — a timer, a stream listener — arrives here and nowhere else.
  // Without it, that error is invisible *and* unrecorded.
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await log.init();

      await _initSupabase();

      runApp(
        ProviderScope(
          overrides: [diagnosticLogProvider.overrideWithValue(log)],
          child: const CyclingApp(),
        ),
      );
    },
    (error, stack) => log.error('zone', error, stack),
  );
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
