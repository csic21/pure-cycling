/// Where spoken navigation prompts go.
///
/// An interface rather than a direct `flutter_tts` call, for the same reason
/// [RouteProvider] is an interface: the interesting behaviour is *when* the app
/// speaks, and that has to be testable without a speech engine. The platform
/// implementation is the boring part.
abstract interface class VoiceBackend {
  /// Speaks [text], completing when the utterance has finished.
  ///
  /// Implementations must never throw. Voice is an enhancement to a ride: a
  /// phone with no TTS engine, a denied audio session or a platform channel
  /// that misbehaves must leave the ride — and the recording — untouched.
  Future<void> speak(String text);

  /// Stops the current utterance and discards anything the engine queued.
  Future<void> stop();
}
