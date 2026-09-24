import 'dart:async';

import '../../routes/domain/route.dart';
import '../../settings/domain/app_settings.dart';
import 'navigation_state.dart';
import 'voice_backend.dart';

/// How important a line is when several are waiting.
enum VoicePriority {
  /// Turn announcements. The rider has time; these can wait their turn.
  normal,

  /// Deviations, reroutes and arrival. These preempt whatever is queued,
  /// because they are the lines the rider has not heard before and cannot
  /// infer from the road ahead.
  urgent,
}

/// One line waiting to be spoken.
class VoicePrompt {
  const VoicePrompt(this.text, [this.priority = VoicePriority.normal]);

  final String text;
  final VoicePriority priority;

  @override
  String toString() => '${priority.name}: $text';
}

/// Turns navigation snapshots into spoken instructions (spec §2.2, §8).
///
/// This is deliberately a pure object: it consumes [NavigationSnapshot]s and
/// pushes text at a [VoiceBackend]. It has no clock, no timers and no platform
/// code, so the whole announcement policy — how far ahead, what gets repeated,
/// what interrupts what — is tested on a fake backend in
/// `test/voice_coach_test.dart` rather than on a bicycle.
///
/// The coach owns the *policy*, not the audio: it never creates an engine and
/// never checks whether one is available. A backend that fails silently simply
/// produces a quiet ride.
class VoiceCoach {
  VoiceCoach({
    required VoiceBackend backend,
    NavigationConfig config = const NavigationConfig(),
  })  : _backend = backend,
        _config = config;

  /// How far before a turn the first announcement is made.
  ///
  /// At a typical 20 km/h this is about 45 seconds of warning: early enough to
  /// look up and plan, late enough that the instruction is not forgotten before
  /// the junction arrives.
  static const double farAnnouncementMeters = 250;

  /// How far before a turn the second, short announcement is made.
  static const double nearAnnouncementMeters = 60;

  /// Remaining distance at which the rider is considered to have arrived.
  static const double arrivalMeters = 25;

  /// How many normal prompts may wait behind the one being spoken.
  ///
  /// A backstop, not a feature: if the platform channel ever hangs, the queue
  /// must not grow for the rest of the ride. Urgent prompts are never dropped.
  static const int _maxQueuedNormal = 2;

  final VoiceBackend _backend;
  NavigationConfig _config;

  final List<VoicePrompt> _queue = [];
  bool _speaking = false;
  bool _disposed = false;

  /// Identity of the instruction whose bands have been announced. The index is
  /// stable for the life of the route, so a new index means a new turn.
  int? _announcedInstruction;
  bool _farAnnounced = false;
  bool _nearAnnounced = false;

  /// Latched per off-route episode, re-armed on re-acquisition.
  bool _offRouteAnnounced = false;

  /// Latched for the whole ride: arriving is announced once.
  bool _arrivalAnnounced = false;

  /// The reroute count is adopted from the first snapshot rather than assumed
  /// to start at zero. Voice can be switched on mid-ride, after the route has
  /// already been replanned; announcing a reroute that happened before the
  /// rider opted in would be reporting history, not guidance.
  bool _seenFirstSnapshot = false;
  int _lastRerouteCount = 0;

  bool get enabled => _config.voicePrompts;

  /// Feeds one navigation update. Call on every snapshot.
  void onSnapshot(NavigationSnapshot snapshot) {
    if (_disposed || !enabled) return;

    if (!_seenFirstSnapshot) {
      _seenFirstSnapshot = true;
      _lastRerouteCount = snapshot.rerouteCount;
    } else if (snapshot.rerouteCount > _lastRerouteCount) {
      _lastRerouteCount = snapshot.rerouteCount;
      // A new route numbers its instructions from zero again, so the index
      // alone cannot tell 「the turn I already announced」 from 「the first turn
      // of the new route」. Reset the bands with the geometry.
      _announcedInstruction = null;
      _farAnnounced = false;
      _nearAnnounced = false;
      _enqueue(const VoicePrompt('已重新规划路线', VoicePriority.urgent));
    }

    if (snapshot.offRoute) {
      if (!_offRouteAnnounced) {
        _offRouteAnnounced = true;
        _enqueue(const VoicePrompt('已偏离路线', VoicePriority.urgent));
      }
    } else {
      _offRouteAnnounced = false;
    }

    final instruction = snapshot.currentInstruction;
    final distance = snapshot.distanceToNextTurnMeters;
    if (instruction != null && distance != null) {
      if (instruction.index != _announcedInstruction) {
        _announcedInstruction = instruction.index;
        _farAnnounced = false;
        _nearAnnounced = false;
      }

      final isArrival = instruction.maneuver == Maneuver.arrive;
      if (!_nearAnnounced && !isArrival && distance <= nearAnnouncementMeters) {
        // Crossing the near band settles the far one too: a rider who emerges
        // from a tunnel 40 m from the turn must hear 「左转」, not a stale
        // 「前方 250 米」 followed by the turn itself.
        _farAnnounced = true;
        _nearAnnounced = true;
        _enqueue(VoicePrompt(_phrase(instruction)));
      } else if (!_farAnnounced && distance <= farAnnouncementMeters) {
        _farAnnounced = true;
        _enqueue(
          VoicePrompt(
            '前方 ${_roundedMeters(distance)} 米${_phrase(instruction)}',
          ),
        );
      }
    }

    if (!_arrivalAnnounced && _hasArrived(snapshot)) {
      _arrivalAnnounced = true;
      _enqueue(const VoicePrompt('已到达目的地', VoicePriority.urgent));
    }
  }

  /// Applies a settings change mid-ride.
  ///
  /// Switching voice off silences the current utterance and drops what is
  /// queued; switching it back on takes effect from the next snapshot, so the
  /// rider never hears instructions for a junction they have already passed.
  void applyConfig(NavigationConfig config) {
    final wasEnabled = _config.voicePrompts;
    _config = config;
    if (wasEnabled && !config.voicePrompts) {
      _queue.clear();
      unawaited(_backend.stop());
    } else if (!wasEnabled && config.voicePrompts) {
      // Re-adopt the counters on the next snapshot: a reroute that happened
      // while voice was off is history, not guidance.
      _seenFirstSnapshot = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _queue.clear();
    await _backend.stop();
  }

  // ---- Internals ----

  void _enqueue(VoicePrompt prompt) {
    if (_disposed) return;

    if (prompt.priority == VoicePriority.urgent) {
      _queue.removeWhere((p) => p.priority == VoicePriority.normal);
    }
    _queue.add(prompt);

    while (_queue.where((p) => p.priority == VoicePriority.normal).length >
        _maxQueuedNormal) {
      _queue.removeAt(
        _queue.indexWhere((p) => p.priority == VoicePriority.normal),
      );
    }

    unawaited(_pump());
  }

  /// Speaks the queue one line at a time.
  ///
  /// Serialized rather than fired in parallel: two utterances overlapping are
  /// unintelligible, and a reroute announcement must not talk over the turn
  /// instruction the rider is acting on.
  Future<void> _pump() async {
    if (_speaking || _disposed || !enabled) return;
    _speaking = true;
    try {
      while (!_disposed && enabled && _queue.isNotEmpty) {
        final prompt = _queue.removeAt(0);
        await _backend.speak(prompt.text);
      }
    } finally {
      _speaking = false;
    }
  }

  bool _hasArrived(NavigationSnapshot snapshot) {
    if (snapshot.distanceToDestinationMeters <= arrivalMeters) return true;
    // A GPS fix a few metres off the end of the polyline leaves a small
    // remaining distance that will never be ridden; progress catches that.
    return snapshot.progress >= 0.99;
  }

  /// Rounds to the nearest 50 m, with a floor.
  ///
  /// Speaking 「前方 247 米」 implies a precision the GPS does not have, and a
  /// number that precise takes longer to say. The floor keeps a rider who
  /// crosses the far band at 70 m from hearing 「前方 50 米」 twice.
  static int _roundedMeters(double meters) {
    final rounded = (meters / 50).round() * 50;
    return rounded < 50 ? 50 : rounded;
  }

  /// The instruction as a spoken line, e.g. 「左转进入人民大道」.
  static String _phrase(RouteInstruction instruction) {
    final maneuver = _spokenManeuver(instruction.maneuver);
    final road = instruction.roadName?.trim();
    if (road == null ||
        road.isEmpty ||
        instruction.maneuver == Maneuver.arrive) {
      return maneuver;
    }
    return '$maneuver进入$road';
  }

  /// Spoken forms of the maneuvers.
  ///
  /// Deliberately separate from [Maneuver.label]: the label is a caption read
  /// at a glance on the dashboard, while these are read aloud and need to be
  /// unambiguous in a single hearing.
  static String _spokenManeuver(Maneuver maneuver) => switch (maneuver) {
        Maneuver.straight => '直行',
        Maneuver.slightLeft => '稍向左转',
        Maneuver.left => '左转',
        Maneuver.sharpLeft => '向左急转',
        Maneuver.slightRight => '稍向右转',
        Maneuver.right => '右转',
        Maneuver.sharpRight => '向右急转',
        Maneuver.uturn => '调头',
        Maneuver.roundabout => '进入环岛',
        Maneuver.merge => '汇入主路',
        Maneuver.fork => '注意岔路',
        Maneuver.ramp => '上匝道',
        Maneuver.ferry => '乘轮渡',
        Maneuver.waypoint => '经过途经点',
        Maneuver.arrive => '到达终点',
        Maneuver.depart => '出发',
        Maneuver.unknown => '继续直行',
      };
}
