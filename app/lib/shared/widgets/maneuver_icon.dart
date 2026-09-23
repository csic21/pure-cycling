import 'package:flutter/material.dart';

import '../../features/routes/domain/route.dart';

/// Maps a [Maneuver] to a glyph.
///
/// Lives in the presentation layer rather than on the enum so the domain
/// model stays free of Flutter. Material's turn icons are used where they
/// exist; the rest fall back to the closest available shape, which is
/// preferable to a blank where an arrow should be.
IconData maneuverIconData(Maneuver maneuver) => switch (maneuver) {
      Maneuver.straight || Maneuver.depart => Icons.straight,
      Maneuver.slightLeft => Icons.turn_slight_left,
      Maneuver.left => Icons.turn_left,
      Maneuver.sharpLeft => Icons.turn_sharp_left,
      Maneuver.slightRight => Icons.turn_slight_right,
      Maneuver.right => Icons.turn_right,
      Maneuver.sharpRight => Icons.turn_sharp_right,
      Maneuver.uturn => Icons.u_turn_left,
      Maneuver.roundabout => Icons.roundabout_left,
      Maneuver.merge => Icons.merge,
      Maneuver.fork => Icons.fork_left,
      Maneuver.ramp => Icons.ramp_right,
      Maneuver.ferry => Icons.directions_boat,
      Maneuver.waypoint => Icons.flag_outlined,
      Maneuver.arrive => Icons.place,
      Maneuver.unknown => Icons.straight,
    };

/// A maneuver arrow, sized for the navigation banner.
class ManeuverIcon extends StatelessWidget {
  const ManeuverIcon({
    super.key,
    required this.maneuver,
    this.size = 44,
    this.color,
  });

  final Maneuver maneuver;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      maneuverIconData(maneuver),
      size: size,
      color: color,
      // The arrow is the one thing on the navigation banner that has to be
      // readable in a fraction of a second, so it takes the full contrast of
      // the primary text colour.
      semanticLabel: maneuver.label,
    );
  }
}
