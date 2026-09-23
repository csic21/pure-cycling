import 'dart:async';

import '../../../core/location/location_service.dart';
import '../../../core/map/map_providers.dart';
import '../../navigation/domain/navigation_engine.dart';
import '../../navigation/domain/navigation_state.dart';
import '../../routes/domain/route.dart';
import '../../settings/domain/app_settings.dart';
import '../domain/ride.dart';
import '../domain/ride_engine.dart';
import 'ride_recorder.dart';

/// Everything the ride UI needs in one object.
class RideSessionState {
  const RideSessionState({
    this.ride = const RideState(),
    this.navigation,
    this.route,
    this.starting = false,
    this.permissionProblem,
  });

  final RideState ride;

  /// Null when the ride is a free ride with no route loaded.
  final NavigationSnapshot? navigation;

  /// The route being navigated, if any.
  final Route? route;

  /// A start is in flight — acquiring permission and the first fix.
  final bool starting;

  /// Set when a ride could not start, so the UI can explain why rather than
  /// leaving the button looking inert.
  final String? permissionProblem;

  bool get hasRoute => route != null;
  bool get isNavigating => navigation != null;

  RideSessionState copyWith({
    RideState? ride,
    NavigationSnapshot? navigation,
    Route? route,
    bool? starting,
    String? permissionProblem,
    bool clearNavigation = false,
    bool clearPermissionProblem = false,
  }) {
    return RideSessionState(
      ride: ride ?? this.ride,
      navigation: clearNavigation ? null : (navigation ?? this.navigation),
      route: route ?? this.route,
      starting: starting ?? this.starting,
      permissionProblem: clearPermissionProblem
          ? null
          : (permissionProblem ?? this.permissionProblem),
    );
  }
}

/// Owns the objects that live for the duration of a ride.
///
/// The recorder handles storage and the engine handles statistics; this class
/// is the only place that knows both exist, and its job is to route positions
/// into the navigation engine and fold the two streams back into one state for
/// the UI.
///
/// It deliberately does *not* own the navigation engine's lifetime decisions:
/// it builds one when a route is present and disposes it when the ride ends.
class RideSession {
  RideSession({
    required RideRecorder recorder,
    required RouteProvider Function() routeProvider,
    required AppSettings settings,
  })  : _recorder = recorder,
        _routeProvider = routeProvider,
        _settings = settings;

  final RideRecorder _recorder;

  /// Resolved when navigation starts, not when the session is created.
  ///
  /// A session outlives the map configuration: a rider can pair a heart rate
  /// strap, enter an AMap key, or change the map style partway through a ride.
  /// Caching the provider at construction would leave the reroute path using
  /// whichever provider happened to be active when the app launched — which,
  /// with no key configured yet, is the straight-line fallback.
  final RouteProvider Function() _routeProvider;

  AppSettings _settings;

  NavigationEngine? _navigation;
  StreamSubscription<RideState>? _rideSub;
  StreamSubscription<NavigationSnapshot>? _navSub;

  final _controller = StreamController<RideSessionState>.broadcast();
  Stream<RideSessionState> get states => _controller.stream;

  RideSessionState _state = const RideSessionState();
  RideSessionState get state => _state;

  RideRecorder get recorder => _recorder;
  NavigationEngine? get navigationEngine => _navigation;

  /// Begins recording, optionally navigating [route].
  ///
  /// Returns false when location permission is missing; the caller surfaces
  /// the reason, which is already in [state].
  Future<bool> start({
    required AppSettings settings,
    Route? route,
    RideCheckpoint? resumeFrom,
  }) async {
    _settings = settings;
    _emit(_state.copyWith(starting: true, clearPermissionProblem: true));

    // Subscribe *before* starting the recorder, for the same reason the
    // recorder subscribes before starting the engine: `states` is a broadcast
    // stream with no replay. Attaching afterwards means the `preparing` state
    // is published into an empty room, the UI keeps showing `idle`, and the
    // ride screen renders a dead dashboard with no countdown until fixes
    // start arriving.
    _listen();

    final ok = resumeFrom != null
        ? await _recorder.resumeRide(resumeFrom, settings)
        : await _recorder.startRide(settings);

    if (!ok) {
      _emit(
        _state.copyWith(
          starting: false,
          permissionProblem: _permissionMessage(recorder.lastPermissionStatus),
        ),
      );
      return false;
    }

    final target = route ?? (resumeFrom != null ? _state.route : null);
    if (target != null) _startNavigation(target);

    _emit(
      _state.copyWith(
        starting: false,
        route: route,
        clearNavigation: route == null,
      ),
    );
    return true;
  }

  /// Loads a route into the ride in progress, starting navigation.
  void navigateRoute(Route route) {
    _navigation?.dispose();
    _navigation = null;
    _startNavigation(route);
    _emit(_state.copyWith(route: route));
  }

  void clearRoute() {
    _navigation?.dispose();
    _navigation = null;
    _emit(
      _state.copyWith(
        clearNavigation: true,
        route: null,
      ),
    );
  }

  void pause() => _recorder.pause();

  void resume() => _recorder.resume();

  void applySettings(AppSettings settings) {
    _settings = settings;
    _recorder.applySettings(settings);
    _navigation?.applyConfig(settings.navigation);
  }

  /// Ends the ride and tears down navigation.
  Future<Ride?> stop({String? name}) async {
    final ride = await _recorder.stopRide(name: name);
    await _disposeNavigation();
    await _rideSub?.cancel();
    _rideSub = null;
    _emit(
      _state.copyWith(
        ride: const RideState(),
        clearNavigation: true,
        route: null,
      ),
    );
    return ride;
  }

  /// Abandons the ride without saving.
  Future<void> discard() async {
    await _recorder.discardRide();
    await _disposeNavigation();
    await _rideSub?.cancel();
    _rideSub = null;
    _emit(
      _state.copyWith(
        ride: const RideState(),
        clearNavigation: true,
        route: null,
      ),
    );
  }

  /// Persists a checkpoint immediately — called when the app is backgrounded.
  Future<void> checkpointNow() => _recorder.saveCheckpointNow();

  void requestMap() => _navigation?.requestMap();

  void requestMinimal() => _navigation?.requestMinimal();

  Future<void> reroute() async => _navigation?.rerouteNow();

  Future<void> dispose() async {
    await _disposeNavigation();
    await _rideSub?.cancel();
    await _controller.close();
  }

  // ---- Internals ----

  /// Subscribes to the recorder's state stream.
  ///
  /// Separate from [_startNavigation] because the two have to happen at
  /// different moments: this one before the ride starts, that one once the
  /// ride — and therefore the route — is known to be under way.
  void _listen() {
    _rideSub?.cancel();
    _rideSub = _recorder.states.listen(_onRideState);
  }

  /// Builds and attaches the navigation engine for [route].
  void _startNavigation(Route route) {
    if (route.points.length >= 2) {
      _navigation = NavigationEngine(
        route: route,
        provider: _routeProvider(),
        config: _settings.navigation,
        groundSpeed: () {
          final stats = _state.ride.stats;
          return (
            currentSpeedMps: stats.currentSpeedMps,
            avgSpeedMps: stats.avgSpeedMps,
          );
        },
      )..initialize();

      _navSub?.cancel();
      _navSub = _navigation!.snapshots.listen((snapshot) {
        _emit(_state.copyWith(navigation: snapshot));
      });
    }
  }

  void _onRideState(RideState ride) {
    final point = ride.lastPoint;
    if (point != null) {
      _navigation?.onPosition(point, ride.bearing);
    }
    _emit(_state.copyWith(ride: ride));
  }

  Future<void> _disposeNavigation() async {
    await _navSub?.cancel();
    _navSub = null;
    final nav = _navigation;
    _navigation = null;
    await nav?.dispose();
  }

  void _emit(RideSessionState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  static String _permissionMessage(LocationPermissionStatus? status) {
    return switch (status) {
      LocationPermissionStatus.serviceDisabled =>
        '系统定位服务未开启，请在设置中打开后重试',
      LocationPermissionStatus.denied => '未获得定位权限，无法记录骑行',
      LocationPermissionStatus.deniedForever =>
        '定位权限已被永久拒绝，请在系统设置中手动开启',
      LocationPermissionStatus.notDetermined => '未能确认定位权限',
      _ => '无法开始记录，请检查定位权限',
    };
  }
}
