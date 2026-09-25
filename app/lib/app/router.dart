import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/set_password_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/history/presentation/ride_detail_screen.dart';
import '../features/ride/presentation/home_screen.dart';
import '../features/ride/presentation/ride_screen.dart';
import '../features/routes/presentation/gpx_import_screen.dart';
import '../features/routes/presentation/route_detail_screen.dart';
import '../features/routes/presentation/route_plan_screen.dart';
import '../features/routes/presentation/routes_screen.dart';
import '../features/sensors/presentation/sensors_screen.dart';
import '../features/settings/presentation/dashboard_editor_screen.dart';
import '../features/settings/presentation/diagnostics_screen.dart';
import '../features/settings/presentation/map_settings_screen.dart';
import '../features/settings/presentation/navigation_settings_screen.dart';
import '../features/settings/presentation/oled_settings_screen.dart';
import '../features/settings/presentation/ride_settings_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/settings/presentation/sync_screen.dart';
import '../features/settings/presentation/units_settings_screen.dart';
import '../shared/widgets/app_shell.dart';

/// Application routes.
///
/// The four bottom-navigation destinations live in a [StatefulShellRoute] so
/// each keeps its own scroll position and navigation stack — leaving the
/// history list to check a route and coming back should not lose your place.
///
/// The ride screen is deliberately *outside* the shell: it is a full-screen
/// recording surface with no tab bar, because a mis-tap on a bottom bar at
/// 30 km/h should not be able to navigate away from a ride in progress.
abstract final class AppRoutes {
  static const String home = '/';
  static const String ride = '/ride';

  static const String routes = '/routes';
  static const String routePlan = '/routes/plan';
  static const String routeImport = '/routes/import';
  static const String routeDetail = '/routes/:id';

  static const String history = '/history';
  static const String rideDetail = '/history/:id';

  static const String settings = '/settings';
  static const String settingsRide = '/settings/ride';
  static const String settingsDashboard = '/settings/dashboard';
  static const String settingsOled = '/settings/oled';
  static const String settingsNavigation = '/settings/navigation';
  static const String settingsUnits = '/settings/units';
  static const String settingsMap = '/settings/map';
  static const String settingsSensors = '/settings/sensors';
  static const String settingsSync = '/settings/sync';
  static const String settingsDiagnostics = '/settings/diagnostics';
  static const String login = '/login';
  static const String setPassword = '/password';

  static String routeDetailFor(String id) => '/routes/$id';
  static String rideDetailFor(String id) => '/history/$id';
}

final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

GoRouter buildRouter() {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: AppRoutes.home,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.home,
                name: 'home',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.routes,
                name: 'routes',
                builder: (context, state) => const RoutesScreen(),
                routes: [
                  GoRoute(
                    path: 'plan',
                    name: 'routePlan',
                    builder: (context, state) => const RoutePlanScreen(),
                  ),
                  GoRoute(
                    path: 'import',
                    name: 'routeImport',
                    builder: (context, state) => const GpxImportScreen(),
                  ),
                  // Declared last so `plan` and `import` are matched before
                  // the id capture, which would otherwise swallow them.
                  GoRoute(
                    path: ':id',
                    name: 'routeDetail',
                    builder: (context, state) => RouteDetailScreen(
                      routeId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.history,
                name: 'history',
                builder: (context, state) => const HistoryScreen(),
                routes: [
                  GoRoute(
                    path: ':id',
                    name: 'rideDetail',
                    builder: (context, state) => RideDetailScreen(
                      rideId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                name: 'settings',
                builder: (context, state) => const SettingsScreen(),
                routes: [
                  GoRoute(
                    path: 'ride',
                    builder: (context, state) => const RideSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'dashboard',
                    builder: (context, state) => const DashboardEditorScreen(),
                  ),
                  GoRoute(
                    path: 'oled',
                    builder: (context, state) => const OledSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'navigation',
                    builder: (context, state) =>
                        const NavigationSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'units',
                    builder: (context, state) => const UnitsSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'map',
                    builder: (context, state) => const MapSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'sensors',
                    builder: (context, state) => const SensorsScreen(),
                  ),
                  GoRoute(
                    path: 'sync',
                    builder: (context, state) => const SyncScreen(),
                  ),
                  GoRoute(
                    path: 'diagnostics',
                    builder: (context, state) => const DiagnosticsScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),

      // Full-screen ride, outside the shell.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: AppRoutes.ride,
        name: 'ride',
        builder: (context, state) => const RideScreen(),
      ),

      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: AppRoutes.login,
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),

      // Opened by a password-reset link, not by the rider navigating. Outside
      // the shell so the exit is always the explicit one on the screen.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: AppRoutes.setPassword,
        name: 'setPassword',
        builder: (context, state) => const SetPasswordScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('页面不存在')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                state.error?.toString() ?? '未知错误',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go(AppRoutes.home),
                child: const Text('返回首页'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
