import 'package:flutter_tts/flutter_tts.dart';

import '../domain/voice_backend.dart';

/// Speaks through the platform's own text-to-speech engine.
///
/// The engine is created on first use rather than in the constructor. Building
/// a [FlutterTts] touches a platform channel, voice prompts are off by default,
/// and the widget tests run with no plugin registry at all — a rider who never
/// enables voice, and a test that never speaks, should never load a speech
/// engine.
class FlutterTtsVoiceBackend implements VoiceBackend {
  FlutterTts? _tts;
  bool _configured = false;

  @override
  Future<void> speak(String text) async {
    try {
      final tts = await _ensure();
      await tts.speak(text);
    } catch (_) {
      // A missing engine, a denied audio session, a channel that throws on an
      // exotic ROM: none of them are worth interrupting a ride over. The
      // prompt is simply not heard.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {
      // Nothing playing, or nothing to play it with.
    }
  }

  Future<FlutterTts> _ensure() async {
    final existing = _tts;
    if (existing != null && _configured) return existing;

    final tts = existing ?? FlutterTts();
    _tts = tts;
    try {
      // Speak must complete when the utterance does: the coach serializes
      // prompts, and a `speak` that returns immediately would let the next
      // line start on top of this one.
      await tts.awaitSpeakCompletion(true);

      // Only select Chinese when the device actually has it. A phone without a
      // zh-CN voice is better served by its own default voice attempting the
      // text than by a language the engine cannot pronounce at all.
      final available = await tts.isLanguageAvailable('zh-CN');
      if (available == true) {
        await tts.setLanguage('zh-CN');
      }

      // 0.5 is normal speed on every platform: Android maps it to the native
      // 1.0, while iOS and macOS use AVSpeechUtterance's 0.5 default.
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1.0);

      // Duck the rider's music instead of stopping it, and keep speaking with
      // the ring/silent switch off — a phone on the handlebars is usually
      // muted, and a silent navigation prompt is a missing one. The call is a
      // no-op off iOS.
      await tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        const [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );

      _configured = true;
    } catch (_) {
      // Configuration failed but the engine may still speak; leaving
      // `_configured` false lets the next prompt retry the setup.
    }
    return tts;
  }
}
