/// Supabase credentials, supplied at build time.
///
/// ```sh
/// flutter run \
///   --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///   --dart-define=SUPABASE_ANON_KEY=eyJhbGci...
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

  /// Storage bucket for GPX files. Private: location traces are among the
  /// most sensitive data a phone holds (spec §44).
  static const String gpxBucket = 'rides';

  /// Storage object path for a ride's GPX (spec §24).
  static String gpxPath(String userId, String rideId) =>
      'rides/$userId/$rideId/original.gpx';
}
