import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import 'router.dart';
import 'theme.dart';
import '../core/updates/apk_updater.dart';
import '../core/updates/update_prompt.dart';

class CyclingApp extends ConsumerStatefulWidget {
  const CyclingApp({super.key});

  @override
  ConsumerState<CyclingApp> createState() => _CyclingAppState();
}

class _CyclingAppState extends ConsumerState<CyclingApp>
    with WidgetsBindingObserver {
  late final GoRouter _router = buildRouter(
    observerFactory: () => _UpdateDismissObserver(_resumeDeferredUpdate),
  );
  late final _updates = ref.read(appUpdateCoordinatorProvider);
  Timer? _updateTimer;
  bool _foreground = true;
  bool _updateResumeScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _updates.hostIsEligible = _canPresentUpdate;
    _router.routeInformationProvider.addListener(_resumeDeferredUpdate);
    // Remove abandoned partials/extra packages. Retain one completed APK:
    // Android may still own its URI even after this process was restarted.
    unawaited(ApkUpdater.discardDownloadedPackages());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateTimer = Timer(const Duration(seconds: 3), () {
        unawaited(_checkForUpdates());
      });
    });
  }

  bool _canPresentUpdate(bool automatic) {
    if (!mounted || !_foreground) return false;
    final session = ref.read(rideSessionProvider);
    if (session.starting || session.ride.isRecording) return false;
    final path = _router.routeInformationProvider.value.uri.path;
    final allowed = automatic
        ? {AppRoutes.home, AppRoutes.settings}
        : {AppRoutes.settingsAbout};
    if (!allowed.contains(path)) return false;
    final context = appNavigatorContext;
    // Recovery sheets and any other root modal take priority. Check this again
    // when the release response arrives, not only before starting the request.
    return context != null &&
        context.mounted &&
        !Navigator.of(context).canPop() &&
        // Root tabs have no expected pushed page. This also detects a sheet
        // on the active shell navigator, including crash recovery.
        (!automatic || !_router.canPop());
  }

  Future<void> _checkForUpdates() async {
    if (!mounted) return;
    final navigatorContext = appNavigatorContext;
    if (navigatorContext != null && navigatorContext.mounted) {
      await checkForAppUpdate(
        navigatorContext,
        coordinator: _updates,
        automatic: true,
      );
    }
  }

  void _resumeDeferredUpdate() {
    if (!mounted || _updateResumeScheduled) return;
    _updateResumeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateResumeScheduled = false;
      if (mounted) {
        unawaited(_updates.resumeDeferred());
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _router.routeInformationProvider.removeListener(_resumeDeferredUpdate);
    _updates.hostIsEligible = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Lifecycle handling for a ride in progress.
  ///
  /// **Nothing here stops a ride.** Locking the screen, taking a phone call,
  /// switching apps for an hour — none of them end the recording. The only
  /// things that do are the rider pressing 结束 and the process being killed
  /// outright, and even then a checkpoint survives.
  ///
  /// That works because the two things a locked-screen ride needs are
  /// configured at the platform level, not here:
  ///
  /// * **Android** runs a foreground service with `foregroundServiceType="location"`
  ///   (see `AndroidManifest.xml` and `LocationService.fixes`), so the process
  ///   is not killed and location keeps arriving.
  /// * **iOS** declares `UIBackgroundModes: location`, so CoreLocation keeps
  ///   delivering fixes with the screen off.
  ///
  /// So this method has two jobs: make the ride *recoverable* at the moments
  /// where the OS might take the process away, and tell the recorder which side
  /// of the foreground it is on — because the platform configuration above can
  /// only be *re-established* while the app is visible. See
  /// [RideRecorder.setForeground].
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _resumeDeferredUpdate();
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Flush the trace and write a checkpoint the moment the app stops
        // being foreground.
        //
        // The five-second checkpoint cadence would cover a crash, but a
        // background transition is the one moment where the OS may suspend
        // the process before the next timer fires — and a suspension is
        // indistinguishable from a crash as far as the ride is concerned.
        // This is also the last moment before the OS may stop delivering
        // timer callbacks at all.
        //
        // `inactive` is included deliberately: on iOS it fires on a phone
        // call or a pull-down of Control Centre, and a checkpoint there costs
        // one small write.
        ref.read(rideSessionProvider.notifier).setForeground(false);
        unawaited(ref.read(rideSessionProvider.notifier).checkpointNow());
      case AppLifecycleState.detached:
        // The engine is being detached from the view — on Android this is the
        // last callback before the process may be torn down. One final
        // checkpoint, best effort: whatever does not make it to disk is at
        // most five seconds of trace.
        ref.read(rideSessionProvider.notifier).setForeground(false);
        unawaited(ref.read(rideSessionProvider.notifier).checkpointNow());
      case AppLifecycleState.resumed:
        // A ride that was interrupted by a phone call should not need the
        // rider to notice anything. The recorder was never stopped, so there
        // is nothing to restart — but a sync attempt is worth making, since
        // the network may have changed while the app was away, and the
        // recorder will have been writing checkpoints the whole time.
        //
        // `setForeground` is what lets the recorder apply the sampling profile
        // it had to defer, and rebuild a location stream that died while the
        // screen was off.
        ref.read(rideSessionProvider.notifier).setForeground(true);
        unawaited(ref.read(syncServiceProvider).syncNow());
        // Retain the installer-owned completed APK regardless of elapsed time.
        // Only abandoned partials and extra legacy packages are swept here.
        unawaited(
          ApkUpdater.discardDownloadedPackages(
            olderThan: ApkUpdater.downloadedPackageGrace,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watching this keeps the settings subscription alive for the process
    // lifetime, so a settings change reaches the recorder and the sync
    // service even when no settings screen is mounted.
    ref.watch(settingsProvider);
    ref.watch(syncReportProvider);
    ref.watch(passwordRecoveryProvider);
    ref.listen(rideSessionProvider, (previous, next) {
      if ((previous?.ride.isRecording == true || previous?.starting == true) &&
          !next.ride.isRecording &&
          !next.starting) {
        _resumeDeferredUpdate();
      }
    });

    // A reset link signs the rider in; it does not change the password. Route
    // to the step that does, so the app can never be in the state where the
    // old password still works and nothing says so.
    ref.listen(passwordRecoveryProvider, (_, pending) {
      if (pending) _router.go(AppRoutes.setPassword);
    });

    return MaterialApp.router(
      title: '纯粹骑行',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(),
      // The app is dark by design. Forcing it means the OLED rules hold even
      // when the device is set to light mode.
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      builder: (context, child) {
        // Numeric text is the entire interface; a user font-size setting that
        // breaks the hero number's layout would be worse than ignoring it.
        // Scaling is clamped rather than disabled so accessibility settings
        // still have a bounded effect on the labels.
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 1.0,
              maxScaleFactor: 1.3,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

/// Dismissing a Navigator-owned sheet does not necessarily change GoRouter's
/// URI. Wake deferred checks after the dismissal frame on every app stack.
class _UpdateDismissObserver extends NavigatorObserver {
  _UpdateDismissObserver(this.onDismissed);
  final VoidCallback onDismissed;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onDismissed();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onDismissed();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) onDismissed();
  }
}
