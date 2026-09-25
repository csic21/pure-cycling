/// The routing relay endpoint: our own function that holds the vendor key.
///
/// ```sh
/// flutter run \
///   --dart-define=ROUTING_RELAY_URL=https://xxx.supabase.co/functions/v1/route
/// ```
///
/// Set at build time. When absent the app falls back to a rider-supplied key
/// (self-hosted and development use), and then to straight lines — the relay
/// is an upgrade, never a requirement.
///
/// Why the key cannot live in the binary, and what the relay does instead, is
/// in [docs/map.md] — the short version: anything the client sends, the device
/// owner can read.
abstract final class RoutingRelayConfig {
  static const String endpoint = String.fromEnvironment('ROUTING_RELAY_URL');

  static bool get isConfigured => endpoint.trim().isNotEmpty;
}
