/// The HTTP surface the AMap route provider needs.
///
/// Two implementations, one provider: talking to the vendor with the rider's
/// own key ([AmapClient]), or to our routing relay with the rider's session
/// ([AmapRelayClient]). Everything downstream — parsing, the GCJ-02 ⇄ WGS-84
/// conversion, waypoint stitching — is indifferent to which one it holds.
abstract interface class AmapRouteClient {
  /// Whether a request has a chance of succeeding.
  ///
  /// For the relay that includes "and the rider is signed in": the relay's
  /// quota is per account, so a session is part of being configured.
  bool get isConfigured;

  /// Fetches [path] and returns the decoded AMap envelope.
  ///
  /// The route provider only ever asks for `/v5/direction/bicycling`. The
  /// relay asserts the same thing at its end — it is not a general gateway.
  Future<Map<String, dynamic>> get(String path, Map<String, String> params);
}
