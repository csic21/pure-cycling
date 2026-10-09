import 'github_release_checker.dart';

/// One application-owned operation, from checking through installer handoff.
/// A late automatic result is retained until the host becomes safe again.
class AppUpdateCoordinator {
  AppUpdateCoordinator({required this.loadRelease});

  final Future<AppRelease?> Function(bool automatic) loadRelease;

  /// Bound by the application host, so About cannot bypass ride/lifecycle gates.
  bool Function(bool automatic)? hostIsEligible;
  Future<void>? _active;
  UpdateRequest? _pending;
  AppRelease? _deferred;
  bool _disposed = false;
  bool _checking = false;
  UpdateRequest? _joinedManual;

  bool get isBusy => _active != null;

  Future<void> check(UpdateRequest request) {
    if (_disposed) return Future.value();
    if (_active != null) {
      if (_checking && !request.automatic && request.canPresent()) {
        _joinedManual = request;
      }
      return _active!;
    }
    if (!request.canPresent()) {
      if (request.automatic) _pending = request;
      return Future.value();
    }
    final done = _run(request).whenComplete(() => _active = null);
    _active = done;
    return done;
  }

  Future<void> _run(UpdateRequest request) async {
    try {
      final cached = request.automatic ? _deferred : null;
      _pending = null;
      _deferred = null;
      final loadedAutomatically = request.automatic;
      _checking = true;
      var release = cached ?? await loadRelease(loadedAutomatically);
      final manual = _joinedManual;
      _joinedManual = null;
      if (manual != null) {
        request = manual;
        // A null automatic result may mean the daily check was skipped.
        // An explicit About tap still deserves one fresh check in that case.
        if (loadedAutomatically && release == null) {
          release = await loadRelease(false);
        }
      }
      // About can have been popped and reopened during either await. Transfer
      // ownership to the latest eligible manual caller without a second fetch.
      request = _joinedManual ?? request;
      _joinedManual = null;
      _checking = false;
      if (_disposed) return;
      // Check current state AFTER every network/platform/preferences await.
      // A ride, another route, or backgrounding may have started meanwhile.
      if (!request.canPresent()) {
        if (request.automatic && release != null) {
          _pending = request;
          _deferred = release;
        }
        return;
      }
      if (release == null) {
        if (!request.automatic) request.message('已经是最新版本');
        return;
      }
      // Await the complete prompt/download/install flow, not just the first
      // dialog. Manual taps and a second automatic check share this future.
      await request.present(release);
    } on ReleaseCheckException catch (error) {
      final feedback = _joinedManual ?? request;
      if (!_disposed && !feedback.automatic && feedback.canPresent()) {
        feedback.message(error.message);
      }
    } catch (_) {
      final feedback = _joinedManual ?? request;
      if (!_disposed && !feedback.automatic && feedback.canPresent()) {
        feedback.message('检查更新失败，请稍后重试');
      }
    } finally {
      _checking = false;
      _joinedManual = null;
    }
  }

  Future<void> resumeDeferred() {
    final request = _pending;
    if (request == null || _disposed) return Future.value();
    return check(request);
  }

  void dispose() {
    _disposed = true;
    hostIsEligible = null;
    _pending = null;
    _deferred = null;
  }
}

class UpdateRequest {
  const UpdateRequest({
    required this.automatic,
    required this.canPresent,
    required this.present,
    required this.message,
  });

  final bool automatic;
  final bool Function() canPresent;
  final Future<void> Function(AppRelease release) present;
  final void Function(String message) message;
}
