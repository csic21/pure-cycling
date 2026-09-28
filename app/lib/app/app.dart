import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import 'router.dart';
import 'theme.dart';
import '../core/updates/update_prompt.dart';

class CyclingApp extends ConsumerStatefulWidget {
  const CyclingApp({super.key});

  @override
  ConsumerState<CyclingApp> createState() => _CyclingAppState();
}

class _CyclingAppState extends ConsumerState<CyclingApp>
    with WidgetsBindingObserver {
  late final GoRouter _router = buildRouter();
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateTimer = Timer(const Duration(seconds: 3), () {
        unawaited(_checkForUpdates());
      });
    });
  }

  Future<void> _checkForUpdates() async {
    // Let the ride-recovery sheet take priority over an optional update.
    if (!mounted || ref.read(rideSessionProvider).ride.isRecording) return;
    final navigatorContext = appNavigatorContext;
    if (navigatorContext != null && navigatorContext.mounted) {
      await checkForAppUpdate(navigatorContext, automatic: true);
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
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
  /// This method's only job is to make the ride *recoverable* at the moments
  /// where the OS might take the process away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
        unawaited(ref.read(rideSessionProvider.notifier).checkpointNow());
      case AppLifecycleState.detached:
        // The engine is being detached from the view — on Android this is the
        // last callback before the process may be torn down. One final
        // checkpoint, best effort: whatever does not make it to disk is at
        // most five seconds of trace.
        unawaited(ref.read(rideSessionProvider.notifier).checkpointNow());
      case AppLifecycleState.resumed:
        // A ride that was interrupted by a phone call should not need the
        // rider to notice anything. The recorder was never stopped, so there
        // is nothing to restart — but a sync attempt is worth making, since
        // the network may have changed while the app was away, and the
        // recorder will have been writing checkpoints the whole time.
        unawaited(ref.read(syncServiceProvider).syncNow());
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
