import 'dart:async';

/// One cancellable wake for the durable outbox. Queue notifications are hints;
/// the caller supplies the earliest persisted deadline after every change/run.
class SyncWakeScheduler {
  SyncWakeScheduler({required void Function() onWake, DateTime Function()? now})
    : _onWake = onWake,
      _now = now ?? DateTime.now;

  final void Function() _onWake;
  final DateTime Function() _now;
  Timer? _timer;
  bool _disposed = false;

  void schedule(DateTime? deadline, {Duration minimumDelay = Duration.zero}) {
    cancel();
    if (_disposed || deadline == null) return;
    final delay = deadline.difference(_now());
    _timer = Timer(delay < minimumDelay ? minimumDelay : delay, () {
      _timer = null;
      if (!_disposed) _onWake();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
