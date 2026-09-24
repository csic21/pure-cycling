import 'package:cycling_app/features/navigation/domain/navigation_state.dart';
import 'package:cycling_app/features/navigation/domain/voice_coach.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_voice_backend.dart';

RouteInstruction turn(
  int index,
  Maneuver maneuver, {
  String? road,
}) =>
    RouteInstruction(
      index: index,
      maneuver: maneuver,
      text: 'provider text',
      distanceMeters: 400,
      durationSeconds: 60,
      startPolylineIndex: index,
      endPolylineIndex: index + 1,
      roadName: road,
    );

NavigationSnapshot snapshot({
  RouteInstruction? instruction,
  double? distanceToTurn,
  bool offRoute = false,
  int rerouteCount = 0,
  double progress = 0,
  double remaining = 5000,
}) =>
    NavigationSnapshot(
      routeId: 'route',
      routeName: '测试路线',
      currentInstruction: instruction,
      distanceToNextTurnMeters: distanceToTurn,
      offRoute: offRoute,
      rerouteCount: rerouteCount,
      progress: progress,
      distanceToDestinationMeters: remaining,
    );

VoiceCoach buildCoach(
  FakeVoiceBackend backend, {
  bool enabled = true,
}) =>
    VoiceCoach(
      backend: backend,
      config: NavigationConfig(voicePrompts: enabled),
    );

/// Lets the coach's queue drain. Plain microtask turns, because nothing here
/// depends on wall-clock time.
Future<void> drain() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('stays silent while the setting is off', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend, enabled: false);

    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.left), distanceToTurn: 100),
    );
    await drain();

    expect(backend.spoken, isEmpty);
  });

  test('announces a turn at the far band, then once more up close', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);
    final instruction = turn(0, Maneuver.left, road: '人民大道');

    // Further away than the far band: the rider does not need to know yet.
    coach.onSnapshot(snapshot(instruction: instruction, distanceToTurn: 300));
    await drain();
    expect(backend.spoken, isEmpty);

    coach.onSnapshot(snapshot(instruction: instruction, distanceToTurn: 240));
    await drain();
    expect(backend.spoken, ['前方 250 米左转进入人民大道']);

    // Still in the far band: no repetition.
    coach.onSnapshot(snapshot(instruction: instruction, distanceToTurn: 180));
    await drain();
    expect(backend.spoken.length, 1);

    coach.onSnapshot(snapshot(instruction: instruction, distanceToTurn: 55));
    await drain();
    expect(backend.spoken, ['前方 250 米左转进入人民大道', '左转进入人民大道']);

    // Past the near band: still no repetition.
    coach.onSnapshot(snapshot(instruction: instruction, distanceToTurn: 20));
    await drain();
    expect(backend.spoken.length, 2);
  });

  test('skips the far announcement when the near band is crossed first',
      () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);
    final instruction = turn(0, Maneuver.right);

    // A tunnel: no fix for long enough that the rider emerges 40 m from the
    // turn. The useful line is the turn itself, not a stale distance.
    coach.onSnapshot(snapshot(instruction: instruction, distanceToTurn: 300));
    coach.onSnapshot(snapshot(instruction: instruction, distanceToTurn: 40));
    await drain();

    expect(backend.spoken, ['右转']);
  });

  test('a new instruction gets its own announcements', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.left), distanceToTurn: 240),
    );
    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.left), distanceToTurn: 50),
    );
    coach.onSnapshot(
      snapshot(instruction: turn(1, Maneuver.right), distanceToTurn: 240),
    );
    await drain();

    expect(backend.spoken, ['前方 250 米左转', '左转', '前方 250 米右转']);
  });

  test('a reroute resets the bands for the new geometry', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    // The first route's turn zero has been announced at the far band.
    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.left), distanceToTurn: 240),
    );
    await drain();
    expect(backend.spoken.length, 1);

    // The reroute also numbers its first turn zero. Without the reset, the
    // new turn would be treated as already announced and never spoken.
    coach.onSnapshot(
      snapshot(
        instruction: turn(0, Maneuver.right),
        distanceToTurn: 200,
        rerouteCount: 1,
      ),
    );
    await drain();

    expect(backend.spoken, [
      '前方 250 米左转',
      '已重新规划路线',
      '前方 200 米右转',
    ]);
  });

  test('off route is announced once per episode', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    coach.onSnapshot(snapshot(offRoute: true));
    coach.onSnapshot(snapshot(offRoute: true));
    await drain();
    expect(backend.spoken, ['已偏离路线']);

    // Back on the route re-arms the announcement for the next episode.
    coach.onSnapshot(snapshot(offRoute: false));
    coach.onSnapshot(snapshot(offRoute: true));
    await drain();
    expect(backend.spoken, ['已偏离路线', '已偏离路线']);
  });

  test('each reroute is announced', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    coach.onSnapshot(snapshot());
    coach.onSnapshot(snapshot(rerouteCount: 1));
    coach.onSnapshot(snapshot(rerouteCount: 1));
    coach.onSnapshot(snapshot(rerouteCount: 2));
    await drain();

    expect(backend.spoken, ['已重新规划路线', '已重新规划路线']);
  });

  test('turning voice on mid-ride does not replay an earlier reroute',
      () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend, enabled: false);

    // The rider rode with voice off, and the route was replanned twice.
    coach.onSnapshot(snapshot(rerouteCount: 2));
    coach.applyConfig(const NavigationConfig(voicePrompts: true));
    coach.onSnapshot(snapshot(rerouteCount: 2));
    await drain();

    expect(backend.spoken, isEmpty,
        reason: 'guidance starts from now, not from the ride history');
  });

  test('switching voice off and on again does not replay a reroute', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    coach.onSnapshot(snapshot());
    coach.applyConfig(const NavigationConfig(voicePrompts: false));
    coach.onSnapshot(snapshot(rerouteCount: 1));
    coach.applyConfig(const NavigationConfig(voicePrompts: true));
    coach.onSnapshot(snapshot(rerouteCount: 1));
    await drain();

    expect(backend.spoken, isEmpty);
  });

  test('arrival is announced once, on distance or on progress', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    coach.onSnapshot(snapshot(remaining: 100));
    await drain();
    expect(backend.spoken, isEmpty);

    coach.onSnapshot(snapshot(remaining: 20));
    coach.onSnapshot(snapshot(remaining: 10));
    await drain();
    expect(backend.spoken, ['已到达目的地']);

    // The progress path covers a fix that never quite reaches zero metres.
    final second = FakeVoiceBackend();
    final other = buildCoach(second);
    other.onSnapshot(snapshot(remaining: 60, progress: 0.995));
    await drain();
    expect(second.spoken, ['已到达目的地']);
  });

  test('an arrival instruction does not get the up-close turn line', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    coach.onSnapshot(
      snapshot(
        instruction: turn(3, Maneuver.arrive),
        distanceToTurn: 55,
        remaining: 55,
      ),
    );
    await drain();
    expect(backend.spoken, ['前方 50 米到达终点']);

    coach.onSnapshot(
      snapshot(
        instruction: turn(3, Maneuver.arrive),
        distanceToTurn: 20,
        remaining: 20,
      ),
    );
    await drain();
    expect(backend.spoken, ['前方 50 米到达终点', '已到达目的地']);
  });

  test('maneuvers are spoken unambiguously', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.roundabout), distanceToTurn: 55),
    );
    coach.onSnapshot(
      snapshot(instruction: turn(1, Maneuver.uturn), distanceToTurn: 55),
    );
    coach.onSnapshot(
      snapshot(instruction: turn(2, Maneuver.slightLeft), distanceToTurn: 55),
    );
    await drain();

    expect(backend.spoken, ['进入环岛', '调头', '稍向左转']);
  });

  test('switching voice off silences the current line and the queue',
      () async {
    final backend = FakeVoiceBackend()..manual = true;
    final coach = buildCoach(backend);

    // One line is being spoken, another waits behind it.
    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.left), distanceToTurn: 240),
    );
    coach.onSnapshot(
      snapshot(instruction: turn(1, Maneuver.right), distanceToTurn: 240),
    );
    await drain();
    expect(backend.spoken, ['前方 250 米左转']);

    coach.applyConfig(const NavigationConfig(voicePrompts: false));
    await drain();

    expect(backend.stopCalls, 1);
    expect(backend.spoken, ['前方 250 米左转'],
        reason: 'the queued turn must not be spoken after the rider opted out');
  });

  test('an urgent line preempts queued turn announcements', () async {
    final backend = FakeVoiceBackend()..manual = true;
    final coach = buildCoach(backend);

    // The first turn is being spoken; a second turn is queued behind it.
    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.left), distanceToTurn: 240),
    );
    coach.onSnapshot(
      snapshot(instruction: turn(1, Maneuver.right), distanceToTurn: 240),
    );
    await drain();

    // The rider leaves the route while the queue is still waiting.
    coach.onSnapshot(snapshot(offRoute: true));
    backend.finishUtterance();
    await drain();

    expect(backend.spoken, ['前方 250 米左转', '已偏离路线'],
        reason: 'the deviation is what the rider has not heard yet');
  });

  test('the queue is bounded when the engine never finishes', () async {
    final backend = FakeVoiceBackend()..manual = true;
    final coach = buildCoach(backend);

    for (var i = 0; i < 10; i++) {
      coach.onSnapshot(
        snapshot(instruction: turn(i, Maneuver.left), distanceToTurn: 240),
      );
    }
    await drain();

    expect(backend.spoken.length, 1,
        reason: 'only the utterance in flight was started');
    // Unblock and drain so the bounded queue becomes visible.
    backend.finishUtterance();
    await drain();
    expect(backend.spoken.length, lessThanOrEqualTo(4),
        reason: 'a hung platform channel must not grow the queue all ride');

    // Leave nothing awaiting a completer, or the test zone never settles.
    await coach.dispose();
  });

  test('dispose stops the engine', () async {
    final backend = FakeVoiceBackend();
    final coach = buildCoach(backend);

    await coach.dispose();
    coach.onSnapshot(
      snapshot(instruction: turn(0, Maneuver.left), distanceToTurn: 50),
    );
    await drain();

    expect(backend.stopCalls, 1);
    expect(backend.spoken, isEmpty);
  });
}
