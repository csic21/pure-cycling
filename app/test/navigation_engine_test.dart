import 'package:cycling_app/core/map/map_providers.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/navigation/domain/navigation_engine.dart';
import 'package:cycling_app/features/navigation/domain/navigation_state.dart';
import 'package:cycling_app/features/routes/domain/route.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Navigation is where a bug is measured in wrong turns. These tests pin down
/// the two things that determine whether it works: where the rider is on the
/// route, and what they are told to do next.
void main() {
  const origin = GeoPoint(39.9042, 116.4074);

  /// A point [meters] east of [origin]. 1 degree of longitude at this latitude
  /// is about 85.4 km.
  GeoPoint east(double meters) =>
      GeoPoint(origin.lat, origin.lng + meters / 85300.0);

  /// A point [meters] north of [origin].
  GeoPoint north(double meters) =>
      GeoPoint(origin.lat + meters / 111132.0, origin.lng);

  /// An L-shaped route: 1000 m east, then 1000 m north, with a left turn at
  /// the corner.
  ///
  /// Vertices every 25 m so the projection has something to work with, which
  /// is what a real routing provider gives.
  Route lRoute({double legMeters = 1000}) {
    final points = <GeoPoint>[];
    const step = 25.0;
    final segments = (legMeters / step).round();

    for (var i = 0; i <= segments; i++) {
      points.add(east(i * step));
    }
    final corner = points.last;
    for (var i = 1; i <= segments; i++) {
      points.add(GeoPoint(corner.lat + (i * step) / 111132.0, corner.lng));
    }

    return Route(
      id: 'route-1',
      name: 'L 路线',
      points: points,
      distanceMeters: legMeters * 2,
      estimatedDuration: Duration(seconds: (legMeters * 2 / 4.17).round()),
      instructions: [
        RouteInstruction(
          index: 0,
          maneuver: Maneuver.depart,
          text: '向东出发',
          distanceMeters: legMeters,
          durationSeconds: legMeters / 4.17,
          startPolylineIndex: 0,
          endPolylineIndex: segments,
        ),
        RouteInstruction(
          index: 1,
          maneuver: Maneuver.left,
          text: '左转进入北向道路',
          distanceMeters: legMeters,
          durationSeconds: legMeters / 4.17,
          startPolylineIndex: segments,
          endPolylineIndex: points.length - 1,
          roadName: '北向道路',
        ),
      ],
      provider: 'test',
    );
  }

  /// East, north, then east again: a left turn and then a right turn.
  ///
  /// The second corner is 400 m after the first, far enough that dismissing
  /// the first junction is a different event from arriving at the second.
  Route twoTurnRoute() {
    const step = 25.0;
    final points = <GeoPoint>[];

    void addLeg(GeoPoint Function(double meters) at, int segments) {
      final start = points.isEmpty ? 0 : 1;
      for (var i = start; i <= segments; i++) {
        points.add(at(i * step));
      }
    }

    addLeg(east, 40); // 1000 m east
    final corner = points.last;
    addLeg(
      (meters) => GeoPoint(corner.lat + meters / 111132.0, corner.lng),
      16, // 400 m north
    );
    final second = points.last;
    addLeg(
      (meters) => GeoPoint(second.lat, second.lng + meters / 85300.0),
      40, // 1000 m east
    );

    final firstCorner = 40; // vertex index of the left turn
    final secondCorner = 40 + 16;

    return Route(
      id: 'route-2',
      name: '两转弯',
      points: points,
      distanceMeters: 2400,
      estimatedDuration: const Duration(minutes: 10),
      instructions: [
        RouteInstruction(
          index: 0,
          maneuver: Maneuver.depart,
          text: '向东出发',
          distanceMeters: 1000,
          durationSeconds: 240,
          startPolylineIndex: 0,
          endPolylineIndex: firstCorner,
        ),
        RouteInstruction(
          index: 1,
          maneuver: Maneuver.left,
          text: '左转',
          distanceMeters: 400,
          durationSeconds: 100,
          startPolylineIndex: firstCorner,
          endPolylineIndex: secondCorner,
        ),
        RouteInstruction(
          index: 2,
          maneuver: Maneuver.right,
          text: '右转',
          distanceMeters: 1000,
          durationSeconds: 240,
          startPolylineIndex: secondCorner,
          endPolylineIndex: points.length - 1,
        ),
      ],
      provider: 'test',
    );
  }

  /// A provider that always fails, for tests that must not reroute.
  RouteProvider failingProvider() => _FakeRouteProvider(shouldFail: true);

  NavigationEngine build({
    Route? route,
    NavigationConfig config = const NavigationConfig(),
    RouteProvider? provider,
  }) {
    return NavigationEngine(
      route: route ?? lRoute(),
      provider: provider ?? failingProvider(),
      config: config,
    )..initialize();
  }

  group('projection', () {
    test('progress is measured along the route, not from the start', () {
      final engine = build();

      engine.onPosition(east(500), 90);
      expect(engine.snapshot.distanceAlongRouteMeters, closeTo(500, 20));
      expect(engine.snapshot.distanceToDestinationMeters, closeTo(1500, 20));
      expect(engine.snapshot.progress, closeTo(0.25, 0.02));

      // Past the corner and up the second leg.
      engine.onPosition(GeoPoint(north(500).lat, east(1000).lng), 0);
      expect(engine.snapshot.distanceAlongRouteMeters, closeTo(1500, 30));
    });

    test('progress never goes backwards', () {
      final engine = build();

      engine.onPosition(east(800), 90);
      final advanced = engine.snapshot.distanceAlongRouteMeters;

      // A brief bad fix, then a good one. The remaining distance must not
      // tick upward mid-ride — that reads as the app losing confidence.
      engine.onPosition(east(600), 90);
      expect(engine.snapshot.distanceAlongRouteMeters, advanced);

      engine.onPosition(east(900), 90);
      expect(engine.snapshot.distanceAlongRouteMeters, greaterThan(advanced));
    });

    test('a fix far off the route is reported as a deviation', () {
      final engine = build();

      // 200 m north of the eastbound leg — a genuinely different road.
      engine.onPosition(east(500 + 0), 90);
      engine.onPosition(
        GeoPoint(east(500).lat + 200 / 111132.0, east(500).lng),
        0,
      );

      expect(engine.snapshot.offRouteMeters, greaterThan(150));
    });

    test('the route geometry is not corrupted by a single outlier', () {
      final engine = build();

      engine.onPosition(east(300), 90);
      engine.onPosition(east(325), 90);

      // A 500 m glitch, then back on the route.
      engine.onPosition(
        GeoPoint(origin.lat + 500 / 111132.0, east(325).lng),
        0,
      );
      engine.onPosition(east(350), 90);

      expect(engine.snapshot.distanceAlongRouteMeters, closeTo(350, 40));
      expect(engine.snapshot.progress, closeTo(0.175, 0.03));
    });
  });

  group('turn guidance', () {
    test('the banner points at the next maneuver, not the one just made', () {
      final engine = build();

      engine.onPosition(east(200), 90);

      // The player is on the first leg; the next thing to do is the left turn
      // at 1000 m.
      expect(engine.snapshot.currentInstruction!.maneuver, Maneuver.left);
      expect(engine.snapshot.distanceToNextTurnMeters, closeTo(800, 30));
    });

    test(
      'straight-through steps are skipped in favour of the next decision',
      () {
        final route = lRoute();
        final withStraight = Route(
          id: route.id,
          name: route.name,
          points: route.points,
          distanceMeters: route.distanceMeters,
          estimatedDuration: route.estimatedDuration,
          instructions: [
            route.instructions.first,
            // A provider-supplied "continue straight" step, which is noise on a
            // banner.
            RouteInstruction(
              index: 1,
              maneuver: Maneuver.straight,
              text: '继续直行',
              distanceMeters: 200,
              durationSeconds: 48,
              startPolylineIndex: 20,
              endPolylineIndex: 28,
            ),
            route.instructions.last,
          ],
          provider: 'test',
        );

        final engine = build(route: withStraight);
        engine.onPosition(east(200), 90);

        expect(engine.snapshot.currentInstruction!.maneuver, Maneuver.left);
      },
    );

    test('a maneuver the rider has ridden past stops being the next turn', () {
      final engine = build();

      // On the first leg, approaching the corner.
      engine.onPosition(east(200), 90);
      expect(engine.snapshot.currentInstruction!.maneuver, Maneuver.left);

      // Around the corner and up the second leg. The left turn is behind the
      // rider; reporting it with a distance of zero would put 「左转 0 米」 on
      // the banner after the turn had already been made.
      engine.onPosition(GeoPoint(north(500).lat, east(1000).lng), 0);

      expect(engine.snapshot.currentInstruction, isNull);
      expect(
        engine.snapshot.maneuver,
        Maneuver.unknown,
        reason: 'the banner falls back to 「即将到达终点」',
      );
    });

    test('road names come through for the banner', () {
      final engine = build();
      engine.onPosition(east(200), 90);

      expect(engine.snapshot.currentInstruction!.roadName, '北向道路');
    });
  });

  group('off-route handling', () {
    test('a deviation has to persist before it latches', () {
      final engine = build();

      engine.onPosition(east(500), 90);
      expect(engine.snapshot.offRoute, isFalse);

      // One fix 100 m off the route — a bad fix under a bridge, not a wrong
      // turn.
      engine.onPosition(
        GeoPoint(east(500).lat + 100 / 111132.0, east(500).lng),
        0,
      );
      expect(
        engine.snapshot.offRoute,
        isFalse,
        reason: 'a single bad fix must not be treated as leaving the route',
      );
    });

    test('reroutes once the deviation has persisted', () async {
      final provider = _FakeRouteProvider();
      final engine = build(
        provider: provider,
        config: const NavigationConfig(rerouteOnDeviation: true),
      );

      final t0 = DateTime.now();
      engine.onPosition(east(500), 90, now: t0);

      // Sustained deviation across the five-second dwell.
      final off = GeoPoint(east(500).lat + 300 / 111132.0, east(500).lng);
      engine.onPosition(off, 0, now: t0);
      for (var i = 1; i <= 3; i++) {
        engine.onPosition(off, 0, now: t0.add(Duration(seconds: 3 * i)));
      }

      // The reroute is kicked off asynchronously so it cannot re-enter the
      // projection update; give it a turn of the event loop.
      await Future<void>.delayed(Duration.zero);

      expect(
        provider.rerouteCalls,
        greaterThan(0),
        reason: 'a rider who really left the route must be brought back',
      );

      // The counter the voice coach announces from is only on the next
      // snapshot: a reroute re-emits the previous one rather than flashing a
      // half-updated route on screen.
      engine.onPosition(off, 0, now: t0.add(const Duration(seconds: 12)));
      expect(
        engine.snapshot.rerouteCount,
        1,
        reason: 'the coach learns about a reroute by watching this counter',
      );
    });

    test('does not reroute when the setting is off', () {
      final provider = _FakeRouteProvider();
      final engine = build(
        provider: provider,
        config: const NavigationConfig(rerouteOnDeviation: false),
      );

      engine.onPosition(east(500), 90);
      final off = GeoPoint(east(500).lat + 300 / 111132.0, east(500).lng);
      for (var i = 0; i < 5; i++) {
        engine.onPosition(
          off,
          0,
          now: DateTime.now().add(Duration(seconds: 3 * (i + 1))),
        );
      }

      expect(provider.rerouteCalls, 0);
    });

    test('re-acquiring the route clears the deviation', () {
      final engine = build();

      engine.onPosition(east(500), 90);
      final off = GeoPoint(east(500).lat + 300 / 111132.0, east(500).lng);
      engine.onPosition(off, 0, now: DateTime.now());
      engine.onPosition(
        off,
        0,
        now: DateTime.now().add(const Duration(seconds: 8)),
      );

      // Back on the road.
      engine.onPosition(east(520), 90);

      expect(engine.snapshot.offRoute, isFalse);
    });
  });

  group('auto map (spec §8.2)', () {
    test('stays minimal when the next turn is far away', () {
      final engine = build(
        config: const NavigationConfig(
          minimalByDefault: true,
          autoShowMap: true,
          approachingTurnMeters: 150,
        ),
      );

      engine.onPosition(east(100), 90);
      expect(engine.snapshot.mode, NavigationMode.minimal);
    });

    test('switches to the map when a turn is close', () {
      final engine = build(
        config: const NavigationConfig(
          minimalByDefault: true,
          autoShowMap: true,
          approachingTurnMeters: 150,
        ),
      );

      // 100 m from the left turn.
      engine.onPosition(east(900), 90);

      expect(engine.snapshot.mode, NavigationMode.map);
      expect(engine.snapshot.autoMapReason, MapAutoReason.approachingTurn);
    });

    test('returns to minimal a few seconds after the turn is cleared', () {
      final engine = build(
        config: const NavigationConfig(
          minimalByDefault: true,
          autoShowMap: true,
          approachingTurnMeters: 150,
          autoMapDismissSeconds: 8,
        ),
      );

      final t0 = DateTime.now();
      engine.onPosition(east(900), 90, now: t0);
      expect(engine.snapshot.mode, NavigationMode.map);

      // Around the corner, well clear of the junction.
      final corner = GeoPoint(north(300).lat, east(1000).lng);
      engine.onPosition(corner, 0, now: t0.add(const Duration(seconds: 2)));
      expect(
        engine.snapshot.mode,
        NavigationMode.map,
        reason: 'the map should linger briefly after a junction',
      );

      engine.onPosition(
        GeoPoint(north(400).lat, east(1000).lng),
        0,
        now: t0.add(const Duration(seconds: 12)),
      );
      expect(engine.snapshot.mode, NavigationMode.minimal);
    });

    test('a user-requested map never dismisses itself', () {
      final engine = build(
        config: const NavigationConfig(
          minimalByDefault: true,
          autoShowMap: true,
          autoMapDismissSeconds: 5,
        ),
      );

      engine.requestMap();
      expect(engine.snapshot.mode, NavigationMode.map);
      expect(engine.snapshot.autoMapReason, MapAutoReason.userRequest);

      // Far from any junction, long after a dismissal would have fired.
      final t = DateTime.now().add(const Duration(minutes: 5));
      engine.onPosition(east(100), 90, now: t);

      expect(
        engine.snapshot.mode,
        NavigationMode.map,
        reason: 'the rider asked for the map; it should stay until dismissed',
      );

      engine.requestMinimal();
      expect(engine.snapshot.mode, NavigationMode.minimal);
    });

    test(
      'leaving the map for the computer sticks through the same junction',
      () {
        final engine = build(
          config: const NavigationConfig(
            minimalByDefault: true,
            autoShowMap: true,
            approachingTurnMeters: 150,
          ),
        );

        final t0 = DateTime.now();
        // 100 m from the left turn: the map comes up on its own.
        engine.onPosition(east(900), 90, now: t0);
        expect(engine.snapshot.mode, NavigationMode.map);

        engine.requestMinimal();
        expect(engine.snapshot.mode, NavigationMode.minimal);

        // The next fixes are still inside that same junction. The map must not
        // reclaim the screen — that is the button appearing to do nothing.
        engine.onPosition(
          east(920),
          90,
          now: t0.add(const Duration(seconds: 1)),
        );
        engine.onPosition(
          east(960),
          90,
          now: t0.add(const Duration(seconds: 3)),
        );
        expect(engine.snapshot.mode, NavigationMode.minimal);
      },
    );

    test('the following junction still raises the map after a dismissal', () {
      final engine = build(
        route: twoTurnRoute(),
        config: const NavigationConfig(
          minimalByDefault: true,
          autoShowMap: true,
          approachingTurnMeters: 150,
        ),
      );

      final t0 = DateTime.now();
      engine.onPosition(east(900), 90, now: t0);
      expect(engine.snapshot.mode, NavigationMode.map);

      engine.requestMinimal();
      engine.onPosition(east(950), 90, now: t0.add(const Duration(seconds: 2)));
      expect(engine.snapshot.mode, NavigationMode.minimal);

      // Around the first corner and closing on the second turn, 100 m out.
      // 1000 m east plus 300 m north is 100 m short of the right turn.
      final closing = GeoPoint(north(300).lat, east(1000).lng);
      engine.onPosition(closing, 0, now: t0.add(const Duration(seconds: 20)));
      expect(engine.snapshot.mode, NavigationMode.map);
    });

    test('respects a configuration that turns auto-switching off', () {
      final engine = build(
        config: const NavigationConfig(
          minimalByDefault: true,
          autoShowMap: false,
        ),
      );

      engine.onPosition(east(900), 90);
      expect(engine.snapshot.mode, NavigationMode.minimal);
    });
  });

  group('ETA', () {
    test('falls back to the provider estimate before the rider has data', () {
      final engine = build();
      engine.onPosition(east(100), 90);

      // 1900 m remaining at the provider's assumed pace.
      final expected =
          engine.snapshot.distanceToDestinationMeters /
          engine.route.assumedSpeedMps;
      expect(
        engine.snapshot.remainingDuration.inSeconds,
        closeTo(expected, expected * 0.1),
      );
    });

    test('switches to the rider\'s own pace once they have covered ground', () {
      final engine = NavigationEngine(
        route: lRoute(),
        provider: failingProvider(),
        config: const NavigationConfig(),
        // The rider is going considerably faster than the provider assumed.
        groundSpeed: () => (currentSpeedMps: 8, avgSpeedMps: 8),
      )..initialize();

      engine.onPosition(east(900), 90);

      // 1100 m at roughly 8 m/s is about two and a half minutes, not the four
      // the provider's 4.17 m/s would give.
      expect(engine.snapshot.remainingDuration.inMinutes, lessThan(4));
    });
  });

  test('along-route speed appears on the second sample', () {
    final engine = build();
    final start = DateTime.utc(2026, 9, 29, 8);

    engine.onPosition(east(100), 90, now: start);
    expect(engine.snapshot.matchedSpeedMps, isNull);

    engine.onPosition(
      east(200),
      90,
      now: start.add(const Duration(seconds: 10)),
    );
    expect(engine.snapshot.matchedSpeedMps, closeTo(10, 0.5));
  });

  test('a route with too few points is handled without throwing', () {
    final tiny = Route(
      id: 'tiny',
      name: 'one point',
      points: const [origin],
      provider: 'test',
    );

    final engine = build(route: tiny);
    engine.onPosition(origin, 0);
    expect(engine.snapshot.hasRoute, isTrue);
  });
}

/// A stub route provider.
///
/// Returns a plausible straight line so the reroute path can be exercised, and
/// counts calls so a test can assert that rerouting did — or did not — happen.
class _FakeRouteProvider implements RouteProvider {
  _FakeRouteProvider({this.shouldFail = false});

  final bool shouldFail;
  int rerouteCalls = 0;

  @override
  String get id => 'test';

  @override
  String get displayName => 'test';

  @override
  bool get isConfigured => true;

  @override
  bool get isDegraded => false;

  @override
  MapDatum get datum => MapDatum.wgs84;

  @override
  Future<Route> planRoute({
    required GeoPoint origin,
    required GeoPoint destination,
    List<GeoPoint> waypoints = const [],
    RoutePreference preference = RoutePreference.recommended,
  }) async {
    throw const RoutePlanningException('not used');
  }

  @override
  Future<Route> rerouteFrom({
    required GeoPoint from,
    required Route original,
  }) async {
    rerouteCalls++;
    if (shouldFail) {
      throw const RoutePlanningException('offline');
    }

    final end = original.end ?? from;
    return Route(
      id: original.id,
      name: original.name,
      points: [
        from,
        GeoPoint((from.lat + end.lat) / 2, (from.lng + end.lng) / 2),
        end,
      ],
      distanceMeters: 100,
      estimatedDuration: const Duration(seconds: 30),
      provider: 'test',
    );
  }
}
