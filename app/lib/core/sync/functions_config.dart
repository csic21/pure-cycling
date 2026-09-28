/// The project's edge functions, behind one base URL.
///
/// ```sh
/// flutter run \
///   --dart-define=SUPABASE_FUNCTIONS_URL=https://xxx.supabase.co/functions/v1
/// ```
///
/// One knob rather than one per function: they are deployed together and there
/// is no build that wants half of them. When the URL is absent every feature
/// degrades honestly — route planning falls back to a rider-supplied key or a
/// straight line, account deletion says it is unavailable rather than
/// pretending, and the update check says the service is not configured.
///
/// They are not all guarded the same way, and the difference is deliberate:
/// `route` and `delete-account` need a session, `release` must not have one
/// (`supabase/config.toml` records why, and `scripts/check-functions-config.sh`
/// holds it there).
///
/// What lives at the other end, and why the keys are not in the app:
/// [docs/map.md] for the routing relay, `supabase/functions/delete-account`
/// for self-service deletion, `supabase/functions/release` for update checks.
abstract final class FunctionsConfig {
  static const String baseUrl =
      String.fromEnvironment('SUPABASE_FUNCTIONS_URL');

  static bool get isConfigured => _trimmed.isNotEmpty;

  /// The routing relay: holds the AMap key (docs/map.md).
  static String? get routeUrl => isConfigured ? '$_trimmed/route' : null;

  /// Self-service account deletion.
  static String? get deleteAccountUrl =>
      isConfigured ? '$_trimmed/delete-account' : null;

  /// The release relay: asks GitHub on the project's behalf and caches the
  /// answer. The app used to ask directly, which does not survive a shared
  /// public IP — see `supabase/functions/release/handler.ts`.
  static String? get releaseUrl => isConfigured ? '$_trimmed/release' : null;

  /// Trailing slashes in a `--dart-define` are easy to type and would turn
  /// into `//route`, which some gateways treat as a different path.
  static String get _trimmed => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
}
