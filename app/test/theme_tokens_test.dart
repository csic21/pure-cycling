import 'dart:math' as math;

import 'package:cycling_app/app/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// Design rule 3, which is the one that actually broke.
///
/// The accent means a single thing — "in progress / primary action" — and the
/// two map lines were both accent lime. Navigation is the only screen that
/// draws a planned route and a recorded track on the same map, so it drew
/// both lines in the colour that exists to single one of them out. Nothing
/// failed and no test noticed; it just looked wrong on the one screen where
/// telling the two apart is the entire point.
void main() {
  test('only the route line carries the accent', () {
    expect(AppColors.routeLine, AppColors.accent);
    expect(AppColors.trackLine, isNot(AppColors.accent));
  });

  test('the track line is a neutral, not a second hue', () {
    // "Not the accent" would also be satisfied by a saturated blue or orange,
    // which would compete for the eye exactly as badly. The record of a ride
    // is not a colour anybody should be looking at; it is a grey, and it
    // recedes.
    final c = AppColors.trackLine;
    final spread = math.max(
      (c.r - c.g).abs(),
      math.max((c.g - c.b).abs(), (c.r - c.b).abs()),
    );
    expect(spread * 255, lessThan(16));
  });
}
