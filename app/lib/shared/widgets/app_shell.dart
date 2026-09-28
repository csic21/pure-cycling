import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
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

  /// The ride tab: the app's front door, and the branch back returns to.
  static const int _rideBranch = 0;

  static const List<({IconData icon, IconData activeIcon, String label})>
      _destinations = [
    (icon: Icons.directions_bike_outlined, activeIcon: Icons.directions_bike, label: '骑行'),
    (icon: Icons.route_outlined, activeIcon: Icons.route, label: '路线'),
    (icon: Icons.list_alt_outlined, activeIcon: Icons.list_alt, label: '记录'),
    (icon: Icons.settings_outlined, activeIcon: Icons.settings, label: '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The shell page is the bottom of the root navigator: there is never a
      // route underneath it to pop, so back arriving here is a decision rather
      // than a navigation. This is where that decision is made — see [_onBack].
      //
      // Without it, the decision is made by whoever else has a `PopScope` on
      // the shell route, and go_router puts one there for every branch
      // (`canPop: match.matches.length == 1`). All four branches stay mounted
      // in the `IndexedStack`, so a branch left on a sub-page keeps reporting
      // `canPop: false` on the shell route for the rest of the session. The
      // root navigator then answers "handled" to a back it did not handle, the
      // platform never gets to quit, and the app cannot be left from the home
      // tab until that branch is returned to its root. `canPop: false` here
      // outranks it, which makes the answer the same in every state.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBack();
      },
      child: Scaffold(
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
      ),
    );
  }

  /// Back at the shell: return to the ride tab, or leave the app.
  ///
  /// A sub-page inside the current branch never reaches here — the branch's own
  /// navigator pops it first, and only then is the shell consulted.
  void _onBack() {
    if (navigationShell.currentIndex != _rideBranch) {
      // The tab convention: back from 路线 / 记录 / 设置 means the ride tab,
      // not "quit". It is also what lets back alone walk the whole app.
      //
      // `initialLocation` is left alone so a branch is restored as it was left,
      // exactly as a tab tap would restore it.
      navigationShell.goBranch(_rideBranch);
      return;
    }

    // The ride tab at its root: back leaves the app, with no confirmation and
    // no second press. Nothing here can be lost — a recording ride cannot be
    // left behind on this screen, because leaving the ride screen stops it
    // (`RideScreen._confirmLeave`).
    //
    // Only Android has a gesture to answer: on iOS this callback is unreachable
    // from the root, and `SystemNavigator.pop` there would dismiss the view
    // controller rather than the app.
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(SystemNavigator.pop());
    }
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
