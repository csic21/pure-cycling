/// The project's edge functions, behind one base URL.
///
/// ```sh
/// flutter run \
///   --dart-define=SUPABASE_FUNCTIONS_URL=https://xxx.supabase.co/functions/v1
/// ```
///
/// One knob rather than one per function: they are deployed together, they are
/// guarded the same way (a Supabase session), and there is no build that wants
/// half of them. When the URL is absent both features degrade honestly — route
/// planning falls back to a rider-supplied key or a straight line, and account
/// deletion says it is unavailable rather than pretending.
///
/// What lives at the other end, and why the keys are not in the app:
/// [docs/map.md] for the routing relay, `supabase/functions/delete-account`
/// for self-service deletion.
abstract final class FunctionsConfig {
  static const String baseUrl =
      String.fromEnvironment('SUPABASE_FUNCTIONS_URL');

  static bool get isConfigured => _trimmed.isNotEmpty;

  /// The routing relay: holds the AMap key (docs/map.md).
  static String? get routeUrl => isConfigured ? '$_trimmed/route' : null;

  /// Self-service account deletion.
  static String? get deleteAccountUrl =>
      isConfigured ? '$_trimmed/delete-account' : null;

  /// Trailing slashes in a `--dart-define` are easy to type and would turn
  /// into `//route`, which some gateways treat as a different path.
  static String get _trimmed => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
}
