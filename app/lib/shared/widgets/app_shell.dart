import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';

/// The four-destination bottom navigation shell (spec §3).
///
/// Home *is* the ride tab, per the spec — the app opens on a screen whose
/// primary action is 开始骑行, so there is no separate "home" destination to
/// reason about.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const List<({IconData icon, IconData activeIcon, String label})>
      _destinations = [
    (icon: Icons.directions_bike_outlined, activeIcon: Icons.directions_bike, label: '骑行'),
    (icon: Icons.route_outlined, activeIcon: Icons.route, label: '路线'),
    (icon: Icons.list_alt_outlined, activeIcon: Icons.list_alt, label: '记录'),
    (icon: Icons.settings_outlined, activeIcon: Icons.settings, label: '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.hairline)),
        ),
        child: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: _onDestinationSelected,
          destinations: [
            for (final destination in _destinations)
              NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.activeIcon),
                label: destination.label,
              ),
          ],
        ),
      ),
    );
  }

  /// Tapping the current tab pops that branch back to its root.
  ///
  /// Standard behaviour on both platforms, and the only way to get out of a
  /// deep settings page without a back gesture.
  void _onDestinationSelected(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }
}
