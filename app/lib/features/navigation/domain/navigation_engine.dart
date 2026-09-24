import 'dart:async';

import '../../../core/map/map_providers.dart';
import '../../../core/utils/geo.dart';
import '../../routes/domain/route.dart';
import '../../settings/domain/app_settings.dart';
import 'navigation_state.dart';

/// Turns a position stream into turn-by-turn guidance.
///
/// ## How progress is measured
///
/// Everything is expressed as a distance *along the route geometry*, not as a
/// distance from the rider to a waypoint. The rider's position is projected
/// onto the nearest polyline segment, and progress is that segment's
/// cumulative length plus the projected fraction of it.
///
/// The projection is anchored to the previously matched segment and only scans
/// a window around it. A full scan would occasionally snap to a parallel road
/// 30 m away and teleport progress by a kilometre; the window makes that
/// mistake impossible as long as the rider is actually on the route, and the
/// off-route detector handles the case where they are not.
///
/// ## Off-route and rerouting
///
/// Deviation has to *persist* before it counts. A single fix under a bridge or
/// beside a tall building can read 60 m off; treating that as a deviation would
/// fire a reroute request at a rider who never left the road. The engine
/// requires the condition to hold for [NavigationConfig.rerouteThresholdMeters]
/// of distance and a fixed dwell time before latching.
class NavigationEngine {
  NavigationEngine({
    required Route route,
    required RouteProvider provider,
    NavigationConfig config = const NavigationConfig(),
    GroundSpeedProvider? groundSpeed,
  })  : _route = route,
        _provider = provider,
        _config = config,
        _groundSpeed = groundSpeed;

  Route _route;
  final RouteProvider _provider;
  NavigationConfig _config;

  /// Supplied by the ride engine: the rider's speed and ride average, used to
  /// make the ETA reflect how *this* rider is going rather than what the map
  /// service assumed.
  final GroundSpeedProvider? _groundSpeed;

  final _controller = StreamController<NavigationSnapshot>.broadcast();
  Stream<NavigationSnapshot> get snapshots => _controller.stream;

  /// Cumulative distance from the route start to each polyline vertex.
  late List<double> _cumulative;

  /// Distance along the route at which each instruction's maneuver occurs.
  late List<double> _instructionDistance;

  late NavigationSnapshot _snapshot;

  int _lastSegment = 0;
  double _along = 0;
  bool _disposed = false;

  /// When the rider first went off route, or null while on it.
  DateTime? _offRouteSince;

  /// How far the last fix was from the route, in meters. Surfaced so the
  /// banner can say "偏离 60 米" rather than just "偏离路线".
  double _lastOffsetMeters = 0;

  /// A reroute is already in flight.
  bool _rerouting = false;

  /// Snapshot of the last position, so a reroute can be expressed from where
  /// the rider is now.
  GeoPoint? _lastPosition;

  NavigationMode _mode = NavigationMode.minimal;

  /// When the map should revert to the minimal view, or null if it should not.
  DateTime? _mapUntil;

  int _rerouteCount = 0;

  NavigationSnapshot get snapshot => _snapshot;

  Route get route => _route;

  int get rerouteCount => _rerouteCount;

  /// Builds the geometry index and emits the first snapshot.
  void initialize({NavigationMode? mode}) {
    _rebuildIndex();
    _mode = mode ??
        (_config.minimalByDefault
            ? NavigationMode.minimal
            : NavigationMode.map);

    _snapshot = NavigationSnapshot(
      routeId: _route.id,
      routeName: _route.name,
      mode: _mode,
      distanceToDestinationMeters: _route.distanceMeters,
      remainingDuration: _route.estimatedDuration,
      eta: DateTime.now().add(_route.estimatedDuration),
      progress: 0,
    );
    _emit();
  }

  void _rebuildIndex() {
    final points = _route.points;
    _cumulative = List<double>.filled(points.length, 0);
    for (var i = 1; i < points.length; i++) {
      _cumulative[i] = _cumulative[i - 1] +
          haversineMeters(
            points[i - 1].lat,
            points[i - 1].lng,
            points[i].lat,
            points[i].lng,
          );
    }

    _instructionDistance = List<double>.filled(_route.instructions.length, 0);
    for (var i = 0; i < _route.instructions.length; i++) {
      final index = _route.instructions[i].startPolylineIndex;
      _instructionDistance[i] =
          (index >= 0 && index < _cumulative.length) ? _cumulative[index] : 0;
    }
  }

  double get totalDistance =>
      _cumulative.isEmpty ? 0 : _cumulative.last;

  /// Feeds a position.
  void onPosition(
    GeoPoint position,
    double? headingDegrees, {
    DateTime? now,
  }) {
    if (_disposed || _route.points.length < 2) return;

    final at = now ?? DateTime.now();
    _lastPosition = position;

    final match = _project(position);
    if (match == null) return;

    // Progress is monotonic between reroutes. A projection that jumps
    // backwards is almost always the window latching onto the wrong segment
    // briefly; allowing it would make the remaining distance tick *up* mid-ride
    // and the ETA jump around.
    if (match.along > _along) {
      _along = match.along;
    }
    _lastSegment = match.segment;

    _updateOffRoute(position, match, at);
    _updateAutoMap(at);

    _emit(buildSnapshot(at));

    // Started after the emit, so a reroute triggered by this position cannot
    // re-enter `onPosition` and corrupt the projection state mid-update.
    //
    // The fix's own timestamp is passed through rather than reading the clock
    // again: the dwell test compares against when the rider went off route,
    // and mixing two clocks there is how a deviation that has clearly
    // persisted refuses to trigger.
    unawaited(_maybeReroute(at));
  }

  /// Rider tapped the navigation area — show the map, and keep it up.
  void requestMap() {
    _mode = NavigationMode.map;
    // A user request does not auto-dismiss: they asked for it.
    _mapUntil = null;
    _emit(buildSnapshot(DateTime.now())
        .copyWith(mode: _mode, autoMapReason: MapAutoReason.userRequest));
  }

  /// Return to the minimal view, cancelling any pending auto-dismiss.
  void requestMinimal() {
    _mode = NavigationMode.minimal;
    _mapUntil = null;
    _emit(buildSnapshot(DateTime.now()).copyWith(mode: _mode));
  }

  /// Applies a changed navigation configuration mid-ride.
  void applyConfig(NavigationConfig config) {
    _config = config;
    if (!config.minimalByDefault && _mode == NavigationMode.minimal) {
      _mode = NavigationMode.map;
    }
  }

  /// Replaces the active route, after a successful reroute or because the user
  /// chose a different one.
  void replaceRoute(Route route) {
    _route = route;
    _rebuildIndex();
    _along = 0;
    _lastSegment = 0;
    _offRouteSince = null;
    _rerouting = false;
    _mapUntil = null;
    _mode = _config.minimalByDefault
        ? NavigationMode.minimal
        : NavigationMode.map;
    _emit();
  }

  /// Forces a reroute, e.g. from a manual "重新规划" action.
  Future<void> rerouteNow() => _performReroute();

  Future<void> dispose() async {
    _disposed = true;
    await _controller.close();
  }

  // ---- Projection ----

  ({double along, int segment, double offsetMeters})? _project(
    GeoPoint position,
  ) {
    final points = _route.points;
    final last = points.length - 1;

    // Window around the last match. Wide enough to cover a fast rider between
    // fixes, narrow enough that a parallel road cannot win.
    const window = 40;
    final start = (_lastSegment - window).clamp(0, last);
    final end = (_lastSegment + window).clamp(0, last);

    var best = _bestSegment(position, start, end);

    // First fix, or a genuinely large deviation: widen to the whole route
    // rather than reporting the rider as off-route because the window was in
    // the wrong place.
    if (best == null || best.offsetMeters > 200) {
      final full = _bestSegment(position, 0, last);
      if (full != null &&
          (best == null || full.offsetMeters < best.offsetMeters)) {
        best = full;
      }
    }

    if (best == null) return null;

    // A match more than 200 m off is not a match — the rider left the route.
    // Reporting their position as the nearest point on the route would make
    // the remaining distance lie to them, so the position is reported with the
    // deviation and the caller decides.
    return best;
  }

  ({double along, int segment, double offsetMeters})? _bestSegment(
    GeoPoint position,
    int startIndex,
    int endIndex,
  ) {
    final points = _route.points;
    double? bestDistance;
    var bestSegment = -1;
    var bestT = 0.0;

    for (var i = startIndex; i < endIndex; i++) {
      if (i + 1 >= points.length) break;
      final a = points[i];
      final b = points[i + 1];

      final t = projectionFactorOnSegment(
        position.lat,
        position.lng,
        a.lat,
        a.lng,
        b.lat,
        b.lng,
      );

      final projected = interpolate(a.lat, a.lng, b.lat, b.lng, t);
      final d = haversineMeters(
        position.lat,
        position.lng,
        projected.lat,
        projected.lng,
      );

      if (bestDistance == null || d < bestDistance) {
        bestDistance = d;
        bestSegment = i;
        bestT = t;
        // 2 m is below GPS noise; no later segment can meaningfully beat it.
        if (d < 2.0) break;
      }
    }

    if (bestSegment < 0 || bestDistance == null) return null;

    final segmentLength = _cumulative[bestSegment + 1] - _cumulative[bestSegment];
    final along = _cumulative[bestSegment] + segmentLength * bestT;

    return (along: along, segment: bestSegment, offsetMeters: bestDistance);
  }

  // ---- Off-route and reroute ----

  void _updateOffRoute(
    GeoPoint position,
    ({double along, int segment, double offsetMeters}) match,
    DateTime now,
  ) {
    final offBy = match.offsetMeters;
    _lastOffsetMeters = offBy;
    // The threshold has to exceed the accuracy of a fix in a city — 30-40 m is
    // routine between buildings — or every ride would be a deviation.
    final threshold = _config.rerouteThresholdMeters < 30
        ? 30.0
        : _config.rerouteThresholdMeters;

    if (offBy > threshold) {
      _offRouteSince ??= now;
    } else if (offBy < threshold * 0.6) {
      // Re-acquired with hysteresis, so a rider riding parallel to the route
      // 25 m away does not oscillate between states.
      _offRouteSince = null;
    }
  }

  bool _isOffRouteAt(DateTime now) {
    final since = _offRouteSince;
    if (since == null) return false;
    // Five seconds: long enough to exclude a single bad fix, short enough that
    // the reroute still feels immediate when the rider really did turn off.
    return now.difference(since) >= const Duration(seconds: 5);
  }

  Future<void> _maybeReroute(DateTime now) async {
    if (!_config.rerouteOnDeviation || _rerouting || !_isOffRouteAt(now)) return;
    final from = _lastPosition;
    if (from == null) return;

    // Reroute at most once every 30 s while off route. Without this, a rider
    // who has deliberately left the route for a detour would generate a
    // request per fix.
    if (_lastRerouteAt != null &&
        now.difference(_lastRerouteAt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastRerouteAt = now;

    await _performReroute();
  }

  DateTime? _lastRerouteAt;

  Future<void> _performReroute() async {
    final from = _lastPosition;
    if (from == null || _rerouting) return;

    _rerouting = true;
    _emit(buildSnapshot(DateTime.now()));
    try {
      final rerouted = await _provider.rerouteFrom(
        from: from,
        original: _route,
      );
      _rerouteCount++;
      replaceRoute(
        Route(
          id: _route.id,
          name: _route.name,
          points: rerouted.points,
          instructions: rerouted.instructions,
          distanceMeters: rerouted.distanceMeters,
          estimatedDuration: rerouted.estimatedDuration,
          elevationGainMeters: rerouted.elevationGainMeters,
          provider: rerouted.provider,
          createdAt: _route.createdAt,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } catch (_) {
      // Offline is normal on a bike. Keep the rider on the old geometry and
      // try again; the banner already says they are off route.
      _rerouting = false;
      _offRouteSince = null;
      _emit();
    }
  }

  // ---- Auto map (spec §8.2) ----

  void _updateAutoMap(DateTime now) {
    if (!_config.autoShowMap) {
      if (_mode == NavigationMode.map && _mapUntil != null) {
        _mode = NavigationMode.minimal;
        _mapUntil = null;
      }
      return;
    }

    // A user-requested map stays up until they dismiss it.
    if (_mode == NavigationMode.map && _mapUntil == null) return;

    if (_mapUntil != null && now.isAfter(_mapUntil!)) {
      _mode = NavigationMode.minimal;
      _mapUntil = null;
      return;
    }

    final reason = _autoMapReason(now);
    if (reason != MapAutoReason.none) {
      _mode = NavigationMode.map;
      // The dismiss timer starts now and is refreshed while the trigger keeps
      // firing, so the map stays up through a run of consecutive turns and
      // clears a few seconds after the last one.
      _mapUntil = now.add(Duration(seconds: _config.autoMapDismissSeconds));
    }
  }

  MapAutoReason _autoMapReason(DateTime now) {
    if (_isOffRouteAt(now)) return MapAutoReason.offRoute;

    final next = _nextTurn();
    if (next == null) return MapAutoReason.none;

    final distance = _instructionDistance[next.index] - _along;

    if (distance <= _config.approachingTurnMeters) {
      return next.maneuver.isComplex
          ? MapAutoReason.complexJunction
          : MapAutoReason.approachingTurn;
    }

    // Two turns close enough together that reading them from the banner alone
    // would have the rider memorising directions.
    final after = _nextTurn(after: next.index);
    if (after != null &&
        _instructionDistance[next.index] - _along < 300 &&
        after.maneuver != Maneuver.straight &&
        _instructionDistance[after.index] - _instructionDistance[next.index] <
            150) {
      return MapAutoReason.consecutiveTurns;
    }

    return MapAutoReason.none;
  }

  // ---- Instruction resolution ----

  /// How far past a maneuver the rider can be before it stops being "next".
  ///
  /// A few metres of slack so a maneuver exactly at the rider's position still
  /// reads as ahead rather than behind — GPS puts them a little short of the
  /// junction as often as a little past it.
  static const double _passedSlackMeters = 15;

  /// The next instruction that asks the rider to do something, at or after
  /// their current position.
  ///
  /// Straight-through steps are skipped: a banner reading 「继续直行」 for two
  /// kilometres is noise, and the rider needs the *next* decision, not a
  /// description of what they are already doing. The final instruction is an
  /// exception — it is usually 「到达终点」, which is a decision — but it is
  /// still dropped once the rider has ridden past it. Returning a passed
  /// maneuver with a distance of zero would put 「左转 0 米」 on the banner
  /// after the turn had already been made, which is worse than saying nothing.
  RouteInstruction? _nextTurn({int after = -1}) {
    final instructions = _route.instructions;
    for (var i = after + 1; i < instructions.length; i++) {
      final at = _instructionDistance[i];
      if (at < _along - _passedSlackMeters) continue;

      final isLast = i == instructions.length - 1;
      if (!isLast && instructions[i].maneuver == Maneuver.straight) continue;

      return instructions[i];
    }
    return null;
  }

  NavigationSnapshot buildSnapshot(DateTime now) {
    final remaining = (totalDistance - _along).clamp(0.0, double.infinity);

    final nextTurn = _nextTurn();
    final following = nextTurn == null ? null : _nextTurn(after: nextTurn.index);

    final distanceToTurn =
        nextTurn == null ? null : (_instructionDistance[nextTurn.index] - _along)
            .clamp(0.0, double.infinity);

    // Once the rider has covered some ground, their own average is a better
    // predictor than the service's estimate — it knows about their bike, their
    // fitness and the hill they are on. Before that there is nothing to go on.
    final ground = _groundSpeed?.call();
    var speedForEta = _route.assumedSpeedMps;
    if (ground != null && ground.avgSpeedMps > 1.2 && _along > 500) {
      speedForEta = ground.avgSpeedMps * 0.95;
    }
    if (speedForEta <= 0.5) speedForEta = 4.2;

    final remainingDuration =
        Duration(seconds: (remaining / speedForEta).round());

    return NavigationSnapshot(
      routeId: _route.id,
      routeName: _route.name,
      mode: _mode,
      distanceAlongRouteMeters: _along,
      distanceToDestinationMeters: remaining,
      remainingDuration: remainingDuration,
      distanceToNextTurnMeters: distanceToTurn,
      currentInstruction: nextTurn,
      nextInstruction: following,
      eta: now.add(remainingDuration),
      offRoute: _isOffRouteAt(now),
      offRouteMeters: _lastOffsetMeters,
      snappedPoint: _route.points.isEmpty
          ? null
          : _pointAtDistance(_along),
      progress: totalDistance <= 0 ? 0 : (_along / totalDistance).clamp(0.0, 1.0),
      autoMapReason: _mode == NavigationMode.map
          ? (_mapUntil == null
              ? MapAutoReason.userRequest
              : _autoMapReason(now))
          : MapAutoReason.none,
      rerouteCount: _rerouteCount,
    );
  }

  /// Interpolates the point at a given distance along the route.
  GeoPoint? _pointAtDistance(double distance) {
    final points = _route.points;
    if (points.isEmpty) return null;
    if (distance <= 0) return points.first;
    if (distance >= _cumulative.last) return points.last;

    var low = 0;
    var high = _cumulative.length - 1;
    while (low < high - 1) {
      final mid = (low + high) ~/ 2;
      if (_cumulative[mid] <= distance) {
        low = mid;
      } else {
        high = mid;
      }
    }

    final segLength = _cumulative[low + 1] - _cumulative[low];
    if (segLength <= 0) return points[low];
    final t = (distance - _cumulative[low]) / segLength;
    final p = interpolate(
      points[low].lat,
      points[low].lng,
      points[low + 1].lat,
      points[low + 1].lng,
      t,
    );
    return GeoPoint(p.lat, p.lng);
  }

  void _emit([NavigationSnapshot? snapshot]) {
    if (_disposed || _controller.isClosed) return;
    if (snapshot != null) _snapshot = snapshot;
    _controller.add(_snapshot);
  }
}

/// Supplies the rider's current and average speed to the navigation engine.
typedef GroundSpeedProvider = ({double currentSpeedMps, double avgSpeedMps})
    Function();
