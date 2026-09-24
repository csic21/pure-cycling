import 'dart:async';

import 'package:cycling_app/features/navigation/domain/voice_backend.dart';

/// Records what was said, and can hold an utterance open so the queueing
/// behaviour is observable.
class FakeVoiceBackend implements VoiceBackend {
  final List<String> spoken = [];
  int stopCalls = 0;

  /// When true, `speak` does not complete until [finishUtterance] is called.
  bool manual = false;

  final List<Completer<void>> _pending = [];

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (!manual) return;
    final completer = Completer<void>();
    _pending.add(completer);
    await completer.future;
  }

  /// Completes the utterance currently being spoken.
  void finishUtterance() {
    if (_pending.isNotEmpty) _pending.removeAt(0).complete();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    // The platform's stop ends the current utterance, which is what unblocks
    // a serialized speaker.
    for (final completer in _pending) {
      if (!completer.isCompleted) completer.complete();
    }
    _pending.clear();
  }
}
