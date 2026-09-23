import '../../../core/utils/geo.dart';
import '../../routes/domain/route.dart';

/// Which of the two navigation presentations is on screen (spec §8).
enum NavigationMode {
  /// Turn-by-turn text only. The default while riding: lower power, better
  /// sunlight legibility, and it removes the temptation to stare at a map.
  minimal('minimal', '极简导航'),

  /// Full map with the route drawn on it.
  map('map', '地图导航');

  const NavigationMode(this.id, this.label);

  final String id;
  final String label;
}

/// Why the map is being shown, when it was switched automatically.
///
/// Recorded so the automatic return to the dashboard can distinguish "the
/// junction passed" from "the user asked for the map and should keep it".
enum MapAutoReason {
  none,
  complexJunction,
  roundabout,
  consecutiveTurns,
  approachingTurn,
  offRoute,
  userRequest,
}

/// An immutable view of navigation progress.
///
/// Produced by [NavigationEngine] on every accepted fix and consumed by the
/// navigation UI *and* by the dashboard's route-dependent fields. There is one
/// source of truth for "where am I on this route", which is what keeps the
/// remaining-distance tile and the turn banner from ever disagreeing.
class NavigationSnapshot {
  const NavigationSnapshot({
    required this.routeId,
    required this.routeName,
    this.mode = NavigationMode.minimal,
    this.distanceAlongRouteMeters = 0,
    this.distanceToDestinationMeters = 0,
    this.remainingDuration = Duration.zero,
    this.distanceToNextTurnMeters,
    this.currentInstruction,
    this.nextInstruction,
    this.eta,
    this.offRoute = false,
    this.offRouteMeters = 0,
    this.snappedPoint,
    this.progress = 0,
    this.autoMapReason = MapAutoReason.none,
  });

  final String routeId;
  final String routeName;
  final NavigationMode mode;

  /// Distance covered along the route, measured on the route geometry rather
  /// than from raw GPS — so a detour into a side street does not inflate it.
  final double distanceAlongRouteMeters;

  final double distanceToDestinationMeters;
  final Duration remainingDuration;

  /// Null once the last maneuver has been passed.
  final double? distanceToNextTurnMeters;
  final RouteInstruction? currentInstruction;
  final RouteInstruction? nextInstruction;

  final DateTime? eta;

  final bool offRoute;

  /// How far off the route the rider currently is, in meters. Only meaningful
  /// once [offRoute] latches true.
  final double offRouteMeters;

  /// The point on the route the rider is currently nearest to.
  final GeoPoint? snappedPoint;

  /// Fraction of the route completed, `0..1`.
  final double progress;

  final MapAutoReason autoMapReason;

  Maneuver get maneuver =>
      currentInstruction?.maneuver ?? Maneuver.unknown;

  bool get hasRoute => routeId.isNotEmpty;

  /// Time remaining, preferring the rider's own recent pace over the
  /// provider's estimate once there is enough of it.
  NavigationSnapshot copyWith({
    NavigationMode? mode,
    double? distanceAlongRouteMeters,
    double? distanceToDestinationMeters,
    Duration? remainingDuration,
    double? distanceToNextTurnMeters,
    RouteInstruction? currentInstruction,
    RouteInstruction? nextInstruction,
    DateTime? eta,
    bool? offRoute,
    double? offRouteMeters,
    GeoPoint? snappedPoint,
    double? progress,
    MapAutoReason? autoMapReason,
  }) {
    return NavigationSnapshot(
      routeId: routeId,
      routeName: routeName,
      mode: mode ?? this.mode,
      distanceAlongRouteMeters:
          distanceAlongRouteMeters ?? this.distanceAlongRouteMeters,
      distanceToDestinationMeters:
          distanceToDestinationMeters ?? this.distanceToDestinationMeters,
      remainingDuration: remainingDuration ?? this.remainingDuration,
      distanceToNextTurnMeters:
          distanceToNextTurnMeters ?? this.distanceToNextTurnMeters,
      currentInstruction: currentInstruction ?? this.currentInstruction,
      nextInstruction: nextInstruction ?? this.nextInstruction,
      eta: eta ?? this.eta,
      offRoute: offRoute ?? this.offRoute,
      offRouteMeters: offRouteMeters ?? this.offRouteMeters,
      snappedPoint: snappedPoint ?? this.snappedPoint,
      progress: progress ?? this.progress,
      autoMapReason: autoMapReason ?? this.autoMapReason,
    );
  }

  /// Clears the turn banner, which must be possible explicitly — a non-null
  /// `copyWith` cannot express "no next turn".
  NavigationSnapshot clearInstruction() => NavigationSnapshot(
        routeId: routeId,
        routeName: routeName,
        mode: mode,
        distanceAlongRouteMeters: distanceAlongRouteMeters,
        distanceToDestinationMeters: distanceToDestinationMeters,
        remainingDuration: remainingDuration,
        eta: eta,
        offRoute: offRoute,
        offRouteMeters: offRouteMeters,
        snappedPoint: snappedPoint,
        progress: progress,
        autoMapReason: autoMapReason,
      );
}
