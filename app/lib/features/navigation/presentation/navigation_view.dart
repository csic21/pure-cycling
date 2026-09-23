import 'package:flutter/material.dart' hide NavigationMode, Route;

import '../../../app/theme.dart';
import '../../../core/map/map_providers.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/maneuver_icon.dart';
import '../../../shared/widgets/route_map.dart';
import '../../ride/domain/ride.dart';
import '../../routes/domain/route.dart';
import '../domain/navigation_state.dart';

/// Minimal navigation (spec §8.1).
///
/// This is the recommended default while riding, and the reasoning is worth
/// stating: a rider looking at a map is not looking at the road. Turn-by-turn
/// text gives the one piece of information that is actually needed — which way,
/// how soon, onto what — at a fraction of the power, and in sunlight where a
/// detailed map is unreadable anyway.
///
/// The layout is: current speed (what the rider checks most), the next turn
/// with its distance, then the two trip figures that matter while navigating —
/// how far is left and when you will arrive.
class MinimalNavigationView extends StatelessWidget {
  const MinimalNavigationView({
    super.key,
    required this.navigation,
    required this.stats,
    required this.formatter,
    this.onTap,
  });

  final NavigationSnapshot navigation;
  final RideStats stats;
  final UnitFormatter formatter;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final instruction = navigation.currentInstruction;
    final distance = navigation.distanceToNextTurnMeters;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          children: [
            // ---- Speed ----
            Expanded(
              flex: 4,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: Text(
                          formatter.speed(stats.currentSpeedMps),
                          style: AppText.hero(10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatter.system.speedSuffix,
                      style: AppText.unit.copyWith(fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),

            const Divider(height: 1),

            // ---- Next turn ----
            Expanded(
              flex: 5,
              child: navigation.offRoute
                  ? _OffRouteNotice(navigation: navigation)
                  : _TurnBanner(
                      instruction: instruction,
                      distanceMeters: distance,
                      following: navigation.nextInstruction,
                    ),
            ),

            const Divider(height: 1),

            // ---- Remaining ----
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  _RemainingCell(
                    label: '剩余',
                    value: formatter.distanceKm(
                      navigation.distanceToDestinationMeters,
                    ),
                    unit: formatter.system.distanceSuffix,
                  ),
                  _RemainingCell(
                    label: '预计到达',
                    value: navigation.eta == null
                        ? '--'
                        : UnitFormatter.clock(navigation.eta!),
                  ),
                  _RemainingCell(
                    label: '剩余时间',
                    value: UnitFormatter.durationMinutes(
                      navigation.remainingDuration,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnBanner extends StatelessWidget {
  const _TurnBanner({
    required this.instruction,
    required this.distanceMeters,
    this.following,
  });

  final RouteInstruction? instruction;
  final double? distanceMeters;
  final RouteInstruction? following;

  @override
  Widget build(BuildContext context) {
    if (instruction == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flag_outlined, size: 40, color: AppColors.textSecondary),
            SizedBox(height: 10),
            Text('即将到达终点', style: AppText.body),
          ],
        ),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ManeuverIcon(maneuver: instruction!.maneuver, size: 56),
        const SizedBox(height: 6),
        if (distanceMeters != null)
          Text(
            _formatDistance(distanceMeters!, context),
            style: AppText.hero(38),
          ),
        const SizedBox(height: 2),
        Text(instruction!.maneuver.label, style: AppText.maneuver),
        if (instruction!.roadName != null &&
            instruction!.roadName!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            instruction!.roadName!,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (following != null && following!.maneuver != Maneuver.straight) ...[
          const SizedBox(height: 10),
          // The turn after this one. Shown small and only when it is a real
          // turn, so a rider at a junction knows what is coming rather than
          // being surprised 50 m later.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('然后 ', style: AppText.caption),
              ManeuverIcon(
                maneuver: following!.maneuver,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(following!.maneuver.label, style: AppText.caption),
            ],
          ),
        ],
      ],
    );
  }

  /// Meters below a kilometre, kilometres above it.
  static String _formatDistance(double meters, BuildContext context) {
    if (meters < 1000) return '${(meters / 10).round() * 10} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
}

class _OffRouteNotice extends StatelessWidget {
  const _OffRouteNotice({required this.navigation});

  final NavigationSnapshot navigation;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.wrong_location_outlined,
            size: 44, color: AppColors.warning),
        const SizedBox(height: 8),
        const Text('已偏离路线', style: AppText.maneuver),
        const SizedBox(height: 4),
        Text(
          navigation.offRouteMeters > 0
              ? '偏离约 ${navigation.offRouteMeters.round()} 米，正在重新规划'
              : '正在重新规划路线',
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _RemainingCell extends StatelessWidget {
  const _RemainingCell({
    required this.label,
    required this.value,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: AppText.value),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(unit!, style: AppText.caption.copyWith(fontSize: 10)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: AppText.caption),
        ],
      ),
    );
  }
}

/// Map navigation (spec §8.2).
///
/// Shown automatically at complex junctions and while off route, and on demand
/// when the rider taps the navigation area. The turn banner stays pinned to
/// the top even here — the map answers "where", but the banner is still what
/// answers "what do I do next".
class MapNavigationView extends StatelessWidget {
  const MapNavigationView({
    super.key,
    required this.navigation,
    required this.route,
    required this.tileSource,
    required this.trackPoints,
    required this.position,
    required this.bearing,
    required this.formatter,
    this.onDismiss,
  });

  final NavigationSnapshot navigation;
  final Route route;
  final MapTileSource tileSource;
  final List<GeoPoint> trackPoints;
  final GeoPoint? position;
  final double? bearing;
  final UnitFormatter formatter;

  /// Returns to minimal navigation. Null while the map is showing because of a
  /// junction — then it dismisses itself.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _MapTurnBanner(navigation: navigation),
        Expanded(
          child: Stack(
            children: [
              RouteMap(
                tileSource: tileSource,
                routePoints: route.points,
                trackPoints: trackPoints,
                position: position,
                bearing: bearing,
              ),
              if (onDismiss != null)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _DismissMapButton(onDismiss: onDismiss!),
                ),
              if (navigation.autoMapReason != MapAutoReason.userRequest &&
                  navigation.autoMapReason != MapAutoReason.none)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _AutoMapBadge(reason: navigation.autoMapReason),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MapTurnBanner extends StatelessWidget {
  const _MapTurnBanner({required this.navigation});

  final NavigationSnapshot navigation;

  @override
  Widget build(BuildContext context) {
    final instruction = navigation.currentInstruction;
    if (instruction == null) return const SizedBox.shrink();

    final distance = navigation.distanceToNextTurnMeters;
    final isComplex = instruction.maneuver.isComplex;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: isComplex ? AppColors.warning : AppColors.accent,
      ),
      child: Row(
        children: [
          Icon(
            _iconFor(instruction.maneuver),
            size: 40,
            color: Colors.black,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (distance != null)
                  Text(
                    distance < 1000
                        ? '${(distance / 10).round() * 10} 米'
                        : '${(distance / 1000).toStringAsFixed(1)} 公里',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                      height: 1.05,
                    ),
                  ),
                Text(
                  instruction.roadName?.isNotEmpty == true
                      ? '${instruction.maneuver.label} · ${instruction.roadName}'
                      : instruction.maneuver.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(Maneuver maneuver) =>
      maneuverIconData(maneuver);
}

/// The badge explaining why the map appeared on its own.
///
/// Without it, a screen that changes itself mid-ride reads as a bug. With it,
/// the behaviour is legible and the rider learns to trust it.
class _AutoMapBadge extends StatelessWidget {
  const _AutoMapBadge({required this.reason});

  final MapAutoReason reason;

  @override
  Widget build(BuildContext context) {
    final label = switch (reason) {
      MapAutoReason.complexJunction => '复杂路口',
      MapAutoReason.roundabout => '环岛',
      MapAutoReason.consecutiveTurns => '连续转向',
      MapAutoReason.approachingTurn => '即将转弯',
      MapAutoReason.offRoute => '已偏离路线',
      MapAutoReason.userRequest => '手动查看',
      MapAutoReason.none => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(label, style: AppText.caption),
      ),
    );
  }
}

class _DismissMapButton extends StatelessWidget {
  const _DismissMapButton({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC000000),
      shape: const CircleBorder(
        side: BorderSide(color: AppColors.hairlineStrong),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onDismiss,
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.map_outlined, size: 24),
        ),
      ),
    );
  }
}
