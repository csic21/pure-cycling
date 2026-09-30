import 'dart:async';

import 'package:flutter/material.dart' hide NavigationMode, Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/map/map_providers.dart';
import '../../../core/system/ride_fullscreen.dart';
import '../../../core/utils/units.dart';
import '../../../shared/layout/handlebar.dart';
import '../../../shared/widgets/pixel_shift.dart';
import '../../../shared/widgets/standstill_dimmer.dart';
import '../../dashboard/domain/dashboard_config.dart';
import '../../dashboard/presentation/dashboard_view.dart';
import '../../navigation/domain/navigation_state.dart';
import '../../navigation/presentation/navigation_view.dart';
import '../../routes/domain/route.dart';
import '../../settings/domain/app_settings.dart';
import '../data/ride_session.dart';
import '../domain/ride_engine.dart';
import 'widgets/ride_controls.dart';
import 'widgets/ride_status_bar.dart';
import 'widgets/start_countdown_overlay.dart';

/// The ride screen (spec §5).
///
/// Composition rules that everything here follows:
///
/// * One enormous number per page, read at arm's length in sunlight.
/// * Buttons sized for a gloved thumb on a phone strapped to handlebars.
/// * Nothing that can navigate away from a recording by accident.
/// * No widget computes a statistic — everything comes from [RideState].
class RideScreen extends ConsumerStatefulWidget {
  const RideScreen({super.key});

  @override
  ConsumerState<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends ConsumerState<RideScreen> {
  final PageController _pageController = PageController();
  int _page = 0;
  bool _startingRide = false;
  bool _leavingAfterStop = false;

  @override
  void initState() {
    super.initState();
    unawaited(RideFullscreen.enter());
    // Started after the first frame so the recorder is not touched during a
    // build, and so a permission dialog appears over a rendered screen rather
    // than a blank one.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startIfNeeded());
  }

  @override
  void dispose() {
    unawaited(RideFullscreen.exit());
    unawaited(WakelockPlus.disable());
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _startIfNeeded() async {
    final session = ref.read(rideSessionProvider);
    if (session.ride.isRecording || _startingRide) return;

    _startingRide = true;
    final ok = await ref.read(rideSessionProvider.notifier).start();
    _startingRide = false;

    if (!mounted) return;
    if (!ok) {
      final problem = ref.read(rideSessionProvider).permissionProblem;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem ?? '无法开始记录')));
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(rideSessionProvider);
    final settings = ref.watch(currentSettingsProvider);
    final formatter = ref.watch(unitFormatterProvider);
    final dashboard = ref.watch(dashboardConfigProvider);
    final services = ref.watch(mapServicesProvider);
    final battery = ref.watch(batteryPercentProvider).valueOrNull;

    final ride = session.ride;
    final navigation = session.navigation;
    final isNavigating = navigation != null && session.route != null;

    // Keeps the screen awake for exactly as long as a ride is being recorded.
    // Done in a post-frame callback so a build never triggers a platform call.
    _syncWakelock(ride, settings);

    final pages = dashboard.pages;
    final pageCount = pages.length + (isNavigating ? 1 : 0);
    final screen = MediaQuery.sizeOf(context);
    final landscape = isHandlebarLandscape(screen.width, screen.height);

    final statusBar = RideStatusBar(
      ride: ride,
      navigating: isNavigating,
      routeName: session.route?.name,
      batteryPercent: battery,
      onClose: () => _confirmLeave(ref, ride),
      onToggleMinimal: navigation == null
          ? null
          : () {
              if (navigation.mode == NavigationMode.map) {
                ref.read(rideSessionProvider.notifier).requestMinimal();
              } else {
                ref.read(rideSessionProvider.notifier).requestMap();
              }
            },
      isMapMode: navigation?.mode == NavigationMode.map,
    );
    final pager = Expanded(
      child: StandstillDimmer(
        enabled: settings.oledMode && settings.dimOnStandstill,
        speedMps: ride.stats.currentSpeedMps,
        child: _RidePager(
          controller: _pageController,
          page: _page,
          pageCount: pageCount,
          onPageChanged: (index) => setState(() => _page = index),
          pages: pages,
          ride: ride,
          navigation: navigation,
          session: session,
          services: services,
          formatter: formatter,
          settings: settings,
        ),
      ),
    );
    final dots = pageCount > 1
        ? _PageDots(
            count: pageCount,
            current: _page,
            axis: landscape ? Axis.vertical : Axis.horizontal,
          )
        : const SizedBox(height: 8);
    final controls = RideControls(
      ride: ride,
      axis: landscape ? Axis.vertical : Axis.horizontal,
      onPause: () => ref.read(rideSessionProvider.notifier).pause(),
      onResume: () => ref.read(rideSessionProvider.notifier).resume(),
      onStop: () => _confirmStop(ref),
      onReroute: isNavigating
          ? () => ref.read(rideSessionProvider.notifier).reroute()
          : null,
    );

    return PopScope(
      // The system back gesture was the one exit from this screen that nobody
      // guarded, and it is the easiest one to trigger by accident with a phone
      // on handlebars. `canPop: false` routes it through the same sheet the
      // close button uses, so no gesture can leave a ride running invisibly.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_confirmLeave(ref, ride));
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          minimum: const EdgeInsets.all(2),
          child: PixelShiftScope(
            enabled: settings.oledMode && settings.pixelShift,
            child: landscape
                ? Column(
                    children: [
                      statusBar,
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            pager,
                            DecoratedBox(
                              decoration: const BoxDecoration(
                                border: Border(
                                  left: BorderSide(color: AppColors.hairline),
                                ),
                              ),
                              child: SizedBox(
                                width: 92,
                                child: Column(
                                  children: [
                                    dots,
                                    Expanded(child: controls),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      statusBar,
                      // Only the data surface dims at a standstill. The
                      // status strip and the controls stay at full contrast,
                      // and the whole column still pixel-shifts together.
                      pager,
                      dots,
                      controls,
                    ],
                  ),
          ),
        ),
        // The countdown covers the whole screen while the first fix is being
        // acquired, so the rider gets a deliberate "3, 2, 1" rather than an app
        // that starts counting the instant the button is pressed.
        bottomSheet: null,
        floatingActionButton: null,
      ),
    );
  }

  /// Whether the wakelock is currently held, so it is only touched on change.
  ///
  /// Without this, the platform call would fire on every rebuild — and this
  /// screen rebuilds once or twice a second for the whole ride. Several
  /// thousand redundant channel calls over four hours is exactly the kind of
  /// thing that costs battery without showing up in a profile.
  bool? _wakelockHeld;

  void _syncWakelock(RideState ride, AppSettings settings) {
    final shouldHold = ride.isRecording && settings.keepScreenOn;
    if (_wakelockHeld == shouldHold) return;
    _wakelockHeld = shouldHold;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `dispose` clears the flag, so a screen torn down between the build and
      // this callback does not re-enable a wakelock nobody will release.
      if (shouldHold) {
        unawaited(WakelockPlus.enable());
      } else {
        unawaited(WakelockPlus.disable());
      }
    });
  }

  Future<void> _confirmLeave(WidgetRef ref, RideState ride) async {
    if (!ride.isRecording) {
      context.pop();
      return;
    }

    final action = await showModalBottomSheet<_LeaveAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('继续骑行'),
              onTap: () => Navigator.pop(context, _LeaveAction.stay),
            ),
            ListTile(
              leading: const Icon(Icons.save_outlined),
              title: const Text('结束并保存'),
              subtitle: const Text('已记录的数据会保留'),
              onTap: () => Navigator.pop(context, _LeaveAction.save),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.danger,
              ),
              title: const Text(
                '放弃这次骑行',
                style: TextStyle(color: AppColors.danger),
              ),
              subtitle: const Text('不会保存任何数据'),
              onTap: () => Navigator.pop(context, _LeaveAction.discard),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;

    switch (action) {
      case _LeaveAction.stay:
        return;
      case _LeaveAction.save:
        final saved = await ref.read(rideSessionProvider.notifier).stop();
        if (mounted) {
          context.go(
            saved == null
                ? AppRoutes.history
                : AppRoutes.rideDetailFor(saved.id),
          );
        }
      case _LeaveAction.discard:
        await ref.read(rideSessionProvider.notifier).discard();
        if (mounted) context.go(AppRoutes.home);
    }
  }

  Future<void> _confirmStop(WidgetRef ref) async {
    final ride = ref.read(rideSessionProvider).ride;

    // A ride under a minute with almost no distance is almost always a
    // mis-tap. Asking costs nothing; silently saving a 20 m "ride" into the
    // history is a small, recurring annoyance.
    final isAccidental =
        ride.stats.elapsed.inSeconds < 60 && ride.stats.distanceMeters < 200;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束骑行？'),
        content: Text(
          isAccidental
              ? '这次骑行刚刚开始，还要结束吗？'
              : '本次骑行 ${_summaryLine(ride, ref)}。结束后可以在「记录」中查看和导出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续骑行'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(isAccidental ? '结束' : '结束并保存'),
          ),
        ],
      ),
    );

    if (confirmed != true || _leavingAfterStop) return;
    _leavingAfterStop = true;

    final saved = await ref.read(rideSessionProvider.notifier).stop();
    if (!mounted) return;

    if (saved == null) {
      context.go(AppRoutes.home);
      return;
    }

    context.go(AppRoutes.rideDetailFor(saved.id));
  }

  static String _summaryLine(RideState ride, WidgetRef ref) {
    final formatter = ref.read(unitFormatterProvider);
    return '${formatter.distanceKm(ride.stats.distanceMeters)} 公里、'
        '${UnitFormatter.duration(ride.stats.moving)}';
  }
}

enum _LeaveAction { stay, save, discard }

/// The swipeable surface: the navigation page when navigating, then the
/// configured dashboard pages.
class _RidePager extends ConsumerWidget {
  const _RidePager({
    required this.controller,
    required this.page,
    required this.pageCount,
    required this.onPageChanged,
    required this.pages,
    required this.ride,
    required this.navigation,
    required this.session,
    required this.services,
    required this.formatter,
    required this.settings,
  });

  final PageController controller;
  final int page;
  final int pageCount;
  final ValueChanged<int> onPageChanged;
  final List<DashboardPage> pages;
  final RideState ride;
  final NavigationSnapshot? navigation;
  final RideSessionState session;
  final MapServices services;
  final UnitFormatter formatter;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isNavigating = navigation != null && session.route != null;
    final navigationOffset = isNavigating ? 1 : 0;
    final route = session.route;
    final dimmed = StandstillDimmer.of(context);

    return Stack(
      children: [
        PageView.builder(
          controller: controller,
          itemCount: pageCount,
          onPageChanged: onPageChanged,
          itemBuilder: (context, index) {
            if (isNavigating && index == 0 && route != null) {
              final nav = navigation;
              if (nav!.mode == NavigationMode.map) {
                return _LiveMapNavigation(
                  navigation: nav,
                  route: route,
                  services: services,
                  ride: ride,
                  formatter: formatter,
                  onDismiss: nav.autoMapReason == MapAutoReason.userRequest
                      ? () => ref
                            .read(rideSessionProvider.notifier)
                            .requestMinimal()
                      : null,
                );
              }
              return MinimalNavigationView(
                navigation: nav,
                stats: ride.stats,
                formatter: formatter,
                onTap: () =>
                    ref.read(rideSessionProvider.notifier).requestMap(),
              );
            }

            final dashboardPage = pages[index - navigationOffset];
            return DashboardView(
              page: dashboardPage,
              data: ref.watch(dashboardDataProvider),
              formatter: formatter,
              dimmed: dimmed,
              minimal: settings.minimalOled && dimmed,
            );
          },
        ),

        // The countdown covers everything while the first fix is acquired. It
        // is an overlay rather than a separate route so the dashboard is
        // already laid out behind it when the ride starts.
        if (ride.isPreparing)
          StartCountdownOverlay(
            ride: ride,
            settings: settings,
            onFinished: () =>
                ref.read(rideSessionProvider.notifier).beginRecording(),
          ),
      ],
    );
  }
}

/// The map view fed from the recorder's in-memory trace.
///
/// The trace is read in place through a revision counter, not copied. [RouteMap]
/// projects the display polyline once and rebuilds that layer only when a new
/// vertex is committed. A fix that does not earn a vertex moves the rider and
/// the short segment behind the dot. The camera keeps the rider centered, and
/// the accent line is only the route still ahead.
class _LiveMapNavigation extends ConsumerWidget {
  const _LiveMapNavigation({
    required this.navigation,
    required this.route,
    required this.services,
    required this.ride,
    required this.formatter,
    this.onDismiss,
  });

  final NavigationSnapshot navigation;
  final Route route;
  final MapServices services;
  final RideState ride;
  final UnitFormatter formatter;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recorder = ref.watch(rideRecorderProvider);

    return ValueListenableBuilder<int>(
      valueListenable: recorder.traceRevision,
      builder: (context, _, _) {
        return MapNavigationView(
          navigation: navigation,
          route: route,
          tileSource: services.tileSource,
          trackPoints: recorder.liveTrace,
          position: ride.lastPoint,
          bearing: ride.bearing,
          formatter: formatter,
          onDismiss: onDismiss,
        );
      },
    );
  }
}

/// Page indicator dots.
///
/// Kept at the bottom edge, small, and in the tertiary colour: they are
/// orientation, not information.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.current,
    this.axis = Axis.horizontal,
  });

  final int count;
  final int current;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final marks = [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: EdgeInsets.symmetric(
            horizontal: axis == Axis.horizontal ? 3 : 0,
            vertical: axis == Axis.vertical ? 3 : 0,
          ),
          width: axis == Axis.horizontal && i == current ? 16 : 6,
          height: axis == Axis.vertical && i == current ? 16 : 6,
          decoration: BoxDecoration(
            color: i == current ? AppColors.accent : AppColors.textTertiary,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: axis == Axis.vertical
          ? Column(mainAxisSize: MainAxisSize.min, children: marks)
          : Row(mainAxisAlignment: MainAxisAlignment.center, children: marks),
    );
  }
}
