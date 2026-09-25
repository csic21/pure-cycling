/// Who to write to, supplied at build time.
///
/// ```sh
/// flutter build apk --dart-define=SUPPORT_EMAIL=support@example.com
/// ```
///
/// Deliberately not a hard-coded address or a placeholder: a support address
/// that does not exist is worse than no address at all, and this app ships
/// without a backend of its own to route messages through. When it is absent
/// the About screen simply does not offer a contact row — it does not show a
/// dead one.
///
/// The stores require a contact for the listing as well; keep this and that
/// in sync when the address is decided.
abstract final class AppContact {
  static const String supportEmail =
      String.fromEnvironment('SUPPORT_EMAIL');

  static bool get hasSupportEmail => supportEmail.trim().isNotEmpty;
}
