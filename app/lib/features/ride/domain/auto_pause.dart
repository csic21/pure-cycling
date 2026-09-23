/// Speed-driven auto-pause (spec §14).
///
/// Two thresholds rather than one, each with its own dwell time. A single
/// threshold would chatter: at exactly 2 km/h the ride would pause and resume
/// several times a second, which produces a stuttering readout, a fragmented
/// moving-time figure, and — worse — a stream of pause/resume events that the
/// GPS filter would have to re-anchor across.
///
/// With hysteresis the pause happens once, at the red light, and the resume
/// happens once, when the rider pulls away.
class AutoPauseController {
  AutoPauseController({
    this.pauseSpeedMps = 2.0 / 3.6,
    this.resumeSpeedMps = 3.0 / 3.6,
    this.pauseDelay = const Duration(seconds: 5),
    this.resumeDelay = const Duration(seconds: 2),
    this.enabled = true,
  });

  /// Below this the pause timer starts (2 km/h).
  final double pauseSpeedMps;

  /// Above this the resume timer starts (3 km/h). Strictly greater than
  /// [pauseSpeedMps] — that gap *is* the hysteresis.
  final double resumeSpeedMps;

  final Duration pauseDelay;
  final Duration resumeDelay;

  bool enabled;

  DateTime? _belowSince;
  DateTime? _aboveSince;

  bool _paused = false;
  bool get isAutoPaused => _paused;

  /// True while the pause condition is building but has not yet triggered.
  /// The UI uses it to show a dimmed "about to pause" hint rather than
  /// snapping to paused.
  bool get pausePending => !_paused && _belowSince != null;

  /// Advances the state machine. Returns the new auto-paused state.
  ///
  /// [speedMps] is the engine's smoothed speed, not a raw GPS value — a
  /// single bad sample must not be able to pause the ride.
  bool update(double speedMps, DateTime now) {
    if (!enabled) {
      _reset();
      return false;
    }

    if (_paused) {
      if (speedMps > resumeSpeedMps) {
        _aboveSince ??= now;
        if (now.difference(_aboveSince!) >= resumeDelay) {
          _paused = false;
          _aboveSince = null;
        }
      } else {
        _aboveSince = null;
      }
    } else {
      if (speedMps < pauseSpeedMps) {
        _belowSince ??= now;
        if (now.difference(_belowSince!) >= pauseDelay) {
          _paused = true;
          _belowSince = null;
        }
      } else {
        _belowSince = null;
      }
    }

    return _paused;
  }

  /// User-driven pause. Auto-pause must not fight it: while manually paused,
  /// the controller stays quiet until the user resumes.
  void suppress() => _reset();

  void _reset() {
    _belowSince = null;
    _aboveSince = null;
    _paused = false;
  }

  void reset() => _reset();
}
