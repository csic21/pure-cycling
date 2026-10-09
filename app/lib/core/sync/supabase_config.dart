/// Supabase credentials, supplied at build time.
///
/// ```sh
/// flutter run \
///   --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///   --dart-define=SUPABASE_ANON_KEY=sb_publishable_...
/// ```
///
/// The **publishable / anon key only**. The `service_role` key bypasses row
/// level security entirely and must never be shipped in a mobile binary —
/// anyone who unpacks the app would have full read and write access to every
/// user's data (spec §25).
///
/// When these are absent the app runs in local-only mode: recording,
/// dashboard, history, GPX and navigation all work, and the sync screens say
/// plainly that the cloud is not configured. That is a supported state, not an
/// error — the spec's local-first principle (spec §15) means the app must be
/// fully useful with no backend at all.
abstract final class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');

  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured =>
      url.trim().isNotEmpty && anonKey.trim().isNotEmpty;

  /// Explains what is missing, for the settings screen.
  static String get configurationHint {
    if (isConfigured) return '已配置';
    final missing = <String>[
      if (url.trim().isEmpty) 'SUPABASE_URL',
      if (anonKey.trim().isEmpty) 'SUPABASE_ANON_KEY',
    ];
    return '未配置（缺少 ${missing.join('、')}）';
  }

  // -------------------------------------------------------------------------
  // Auth redirect
  // -------------------------------------------------------------------------

  /// The custom URL scheme the app registers to receive auth callbacks.
  ///
  /// Every email Supabase sends — address confirmation, password reset, email
  /// change — ends in a link. Without a scheme of its own the app cannot be
  /// the destination of that link, so the rider taps it, lands in a browser,
  /// confirms their address there, and never gets back to the app they were
  /// trying to use. The account is confirmed and the app still shows a sign-in
  /// form, which reads as "the confirmation did not work".
  ///
  /// `purecycling` rather than the reverse-DNS bundle id: URL schemes are a
  /// single global namespace per device, and a short distinctive one is less
  /// likely to collide with another app than `app.purecycling.cycling` would
  /// be to collide with… itself.
  static const String redirectScheme = 'purecycling';

  /// The path component. Distinguishes an auth callback from any other deep
  /// link the app may register later.
  static const String redirectPath = 'login-callback';

  /// Passed to every auth call that sends an email, and registered in
  /// `Info.plist` / `AndroidManifest.xml`.
  ///
  /// **It must also be listed in the Supabase dashboard** under
  /// Authentication → URL Configuration → Redirect URLs. Supabase refuses to
  /// redirect anywhere not on that allow-list, and the failure is silent from
  /// the app's side — the email simply arrives with a link that goes to the
  /// project's Site URL instead.
  static const String redirectUrl = '$redirectScheme://$redirectPath';

  /// Every redirect URL a Supabase project needs to allow for this build to
  /// work, for the setup instructions.
  static const List<String> requiredRedirectUrls = [redirectUrl];

  /// Storage bucket for GPX files. Private: location traces are among the
  /// most sensitive data a phone holds (spec §44).
  static const String gpxBucket = 'rides';

  /// Storage object path for a ride's GPX (spec §24).
  static String gpxPath(String userId, String rideId) =>
      'rides/$userId/$rideId/original.gpx';

  /// Accept only a single GPX filename beneath this exact account/ride prefix.
  static bool isRideGpxPath(String? path, String userId, String rideId) {
    final prefix = 'rides/$userId/$rideId/';
    if (path == null || !path.startsWith(prefix)) return false;
    final name = path.substring(prefix.length);
    // Epoch-bearing paths fence uploads begun before a cloud wipe. Keep
    // previously stored single-filename paths readable during upgrades.
    if (!name.contains('/')) {
      return RegExp(r'^[a-zA-Z0-9_-]+\.gpx$').hasMatch(name);
    }
    const uuid =
        r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
    return RegExp('^$uuid/$uuid\\.gpx\$').hasMatch(name);
  }
}
