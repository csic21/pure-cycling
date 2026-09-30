import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../app/theme.dart';
import '../../core/map/coord_transform.dart';
import '../../core/map/display_track.dart';
import '../../core/map/map_providers.dart';
import '../../core/map/route_remainder.dart';
import '../../core/utils/geo.dart';

/// The map, with datum handling.
///
/// Everything the app stores is WGS-84. AMap's tiles are GCJ-02. The
/// conversion between them happens here, once, at the boundary between the
/// data and the tile layer — declared by the [MapTileSource]'s datum rather
/// than assumed.
///
/// Every coordinate that goes into this widget is WGS-84, and this widget is
/// the only place in the presentation layer that knows the tiles might not be.
///
/// A ride rebuilds the widget around this map about once a second. Rebuilding
/// the polyline layers would throw away flutter_map's projected-vertex cache
/// and reproject the whole line. The canvas below is created once; a fix
/// moves the rider and the short segment behind the dot, and the long
/// polylines update only when [DisplayTrack] commits a new vertex.
///
/// While navigating, pass [routeSnap]. The accent line is then only the route
/// still ahead, and it is replaced only when the rider passes a vertex. The
/// gap from the rider to that vertex is a two-point connector.
class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    required this.tileSource,
    this.center,
    this.zoom = 15,
    this.routePoints = const [],
    this.trackPoints = const [],
    this.fitPoints = const [],
    this.position,
    this.waypoints = const [],
    this.destination,
    this.bearing,
    this.bounds,
    this.interactive = true,
    this.showAttribution = true,
    this.onTap,
    this.onMapTap,
    this.padding = const EdgeInsets.all(24),
    this.followRider = false,
    this.routeSnap,
    this.routeProgressMeters,
    this.offRoute = false,
    this.offRouteMeters = 0,
  });

  final MapTileSource tileSource;

  /// Explicit centre. Ignored when [bounds] or any geometry is given.
  final GeoPoint? center;
  final double zoom;

  /// The planned route line.
  final List<GeoPoint> routePoints;

  /// The recorded track line.
  final List<GeoPoint> trackPoints;

  /// Additional points used for the initial camera without drawing a route.
  final List<GeoPoint> fitPoints;

  /// The rider's current position.
  final GeoPoint? position;
  final List<GeoPoint> waypoints;
  final GeoPoint? destination;
  final double? bearing;

  /// Fit the view to these points instead of using [center] and [zoom].
  final GeoBounds? bounds;

  final bool interactive;
  final bool showAttribution;
  final VoidCallback? onTap;

  /// Coordinates selected on the map, converted back to stored WGS-84.
  final ValueChanged<GeoPoint>? onMapTap;
  final EdgeInsets padding;

  /// North-up. Keeps the rider in the middle at street zoom. A pan or pinch
  /// suspends this until the rider taps the control on the map. Planner and
  /// detail maps leave it off and fit the whole line once.
  final bool followRider;

  /// Point on the planned route nearest the rider. When set, the accent line
  /// is the route ahead of this point rather than the whole of [routePoints].
  final GeoPoint? routeSnap;

  /// Distance already ridden, measured on the full route. Locates [routeSnap]
  /// on the simplified line when the road loops.
  final double? routeProgressMeters;

  /// The rider has left the line. The road ahead stays drawn; no connector
  /// is stroked from the rider back to it.
  final bool offRoute;

  /// Cross-track distance, in meters. While following, a rider far enough
  /// that street zoom hides the route is framed together with the next
  /// stretch of it.
  final double offRouteMeters;

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  late final _MapModel _model;
  late final Widget _canvas;

  @override
  void initState() {
    super.initState();
    _model = _MapModel()..apply(widget);
    // The same widget instance on every parent rebuild. Flutter skips the
    // element update, so the polyline layers are not reconfigured when the
    // only thing that changed is the widget that *contains* the map.
    _canvas = _MapCanvas(model: _model);
  }

  @override
  void didUpdateWidget(RouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _model.apply(widget);
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _canvas;
}

/// Holds the projected geometry and fires only the slice that changed.
class _MapModel {
  _MapModel()
    : tiles = ValueNotifier(const _TileView(MapTileSource.osm, true)),
      chrome = ValueNotifier(
        const _Chrome(interactive: true, minZoom: 3, maxZoom: 19),
      );

  final DisplayTrack _track = DisplayTrack();
  final DisplayTrack _route = DisplayTrack(commitEndpoint: true);

  final ValueNotifier<List<LatLng>> trackLine = ValueNotifier(const []);
  final ValueNotifier<List<LatLng>> headLine = ValueNotifier(const []);
  final ValueNotifier<List<LatLng>> routeLine = ValueNotifier(const []);
  final ValueNotifier<List<LatLng>> routeJoin = ValueNotifier(const []);
  final ValueNotifier<_Rider> rider = ValueNotifier(const _Rider(null, null));
  final ValueNotifier<_Places> places = ValueNotifier(const _Places());
  final ValueNotifier<_TileView> tiles;
  final ValueNotifier<_Chrome> chrome;
  final ValueNotifier<int> refit = ValueNotifier(0);
  final ValueNotifier<_CameraCue> camera = ValueNotifier(const _CameraCue());

  MapDatum _datum = MapDatum.wgs84;
  bool locked = false;
  bool _followCamera = false;
  LatLng initialCenter = const LatLng(39.90923, 116.397428);
  double initialZoom = 15;

  List<GeoPoint> _routeVerts = const [];
  List<double> _routeCumulative = const [];
  int _cutFrom = -1;
  int _searchSegment = 0;
  List<GeoPoint>? _rawRoute;
  int _rawCount = -1;
  double _fullRouteMeters = 0;
  int _routeEpoch = 0;
  int _nearbyEpoch = 0;

  /// Latched so a fix that jitters around [farOffMeters] does not zoom the
  /// camera in and out. Clears once the rider is clearly back in range.
  bool _farOff = false;

  /// Projected route vertices for the next [rejoinLookaheadMeters], used
  /// when the follow camera has to show the rider and the road together.
  List<LatLng> nearbyAhead = const [];

  /// True once the rider, not the overview fit, owns the camera.
  bool get followHasCenter => _followCamera;

  ValueChanged<GeoPoint>? onMapTap;
  VoidCallback? onSurfaceTap;

  void apply(RouteMap widget) {
    onMapTap = widget.onMapTap;
    onSurfaceTap = widget.onTap;
    _updateChrome(widget);
    _updateTiles(widget);

    final datumChanged = _datum != widget.tileSource.datum;
    _datum = widget.tileSource.datum;

    if (_track.ingest(widget.trackPoints) || datumChanged) {
      _setLine(trackLine, _projectAll(_track.line));
    }
    _setHead();
    _publishRoute(widget, datumChanged);
    _setRider(widget);
    _setPlaces(widget);
    _publishCamera(widget);
    _fit(widget);
  }

  void dispose() {
    trackLine.dispose();
    headLine.dispose();
    routeLine.dispose();
    routeJoin.dispose();
    rider.dispose();
    places.dispose();
    tiles.dispose();
    chrome.dispose();
    refit.dispose();
    camera.dispose();
  }

  /// Past this, street zoom no longer shows the route the rider has to
  /// get back to.
  static const farOffMeters = 150.0;

  /// How much of the remaining route is framed together with a rider who
  /// is far off it. The rest of a long route stays off screen.
  static const rejoinLookaheadMeters = 800.0;

  void _publishRoute(RouteMap widget, bool datumChanged) {
    _noteRoute(widget.routePoints);
    final lineChanged = _route.ingest(widget.routePoints) || datumChanged;
    if (lineChanged) {
      _routeVerts = _route.line;
      _routeCumulative = cumulativeMeters(_routeVerts);
      _cutFrom = -1;
    }

    final snap = widget.routeSnap;
    if (snap == null || _routeVerts.length < 2) {
      if (_cutFrom != 0 || lineChanged) {
        _cutFrom = 0;
        _setLine(routeLine, _projectAll(_routeVerts));
        _setNearby(const []);
      }
      _setLine(routeJoin, const []);
      return;
    }

    final hint = widget.routeProgressMeters == null
        ? _searchSegment
        : hintSegmentForProgress(
            cumulative: _routeCumulative,
            progressMeters: widget.routeProgressMeters!,
            fullLengthMeters: _fullRouteMeters,
          );
    final cut = cutRoute(
      line: _routeVerts,
      snap: snap,
      hintSegment: hint,
      offRoute: widget.offRoute,
    );
    _searchSegment = cut.segment;
    if (cut.fromIndex != _cutFrom) {
      _cutFrom = cut.fromIndex;
      final ahead = cut.fromIndex >= _routeVerts.length
          ? const <GeoPoint>[]
          : _routeVerts.sublist(cut.fromIndex);
      _setLine(routeLine, _projectAll(ahead));
      _setNearby(
        _projectAll(
          verticesAhead(
            _routeVerts,
            _routeCumulative,
            cut.fromIndex.clamp(0, _routeVerts.length - 1),
            rejoinLookaheadMeters,
          ),
        ),
      );
    }
    if (cut.joinFrom != null && cut.joinTo != null) {
      _setLine(routeJoin, [_project(cut.joinFrom!), _project(cut.joinTo!)]);
    } else {
      _setLine(routeJoin, const []);
    }
  }

  void _noteRoute(List<GeoPoint> raw) {
    if (identical(raw, _rawRoute) && raw.length == _rawCount) return;
    _rawRoute = raw;
    _rawCount = raw.length;
    _fullRouteMeters = polylineLengthMeters(raw);
    _routeEpoch++;
  }

  void _setNearby(List<LatLng> points) {
    nearbyAhead = points;
    _nearbyEpoch++;
  }

  void _publishCamera(RouteMap widget) {
    final away = widget.offRoute && widget.offRouteMeters > farOffMeters;
    final back = !widget.offRoute || widget.offRouteMeters < farOffMeters * 0.7;
    if (widget.followRider && !_farOff && away) _farOff = true;
    if (_farOff && back) _farOff = false;

    final next = _CameraCue(
      follow: widget.followRider,
      far: widget.followRider && _farOff,
      rider: widget.position == null ? null : _project(widget.position!),
      nearbyEpoch: _nearbyEpoch,
      routeEpoch: _routeEpoch,
    );
    if (camera.value.same(next)) return;
    camera.value = next;
  }

  void _updateChrome(RouteMap widget) {
    final next = _Chrome(
      interactive: widget.interactive,
      minZoom: widget.tileSource.minZoom,
      maxZoom: widget.tileSource.maxZoom,
      surfaceTap: widget.onTap != null,
    );
    if (chrome.value.same(next)) return;
    chrome.value = next;
  }

  void _updateTiles(RouteMap widget) {
    final next = _TileView(widget.tileSource, widget.showAttribution);
    if (tiles.value.same(next)) return;
    tiles.value = next;
  }

  void _setHead() {
    final from = _track.lastVertex;
    final to = _track.head;
    if (from == null || to == null || from == to) {
      _setLine(headLine, const []);
      return;
    }
    _setLine(headLine, [_project(from), _project(to)]);
  }

  void _setRider(RouteMap widget) {
    final position = widget.position;
    final next = _Rider(
      position == null ? null : _project(position),
      widget.bearing,
    );
    if (rider.value.same(next)) return;
    rider.value = next;
  }

  void _setPlaces(RouteMap widget) {
    final next = _Places(
      waypoints: _projectAll(widget.waypoints),
      destination: widget.destination == null
          ? null
          : _project(widget.destination!),
    );
    if (places.value.same(next)) return;
    places.value = next;
  }

  /// The first geometry wins the camera. After that a position tick must not
  /// move a map the rider has panned, and must not scan the whole trace to
  /// recompute a box that will be ignored.
  void _fit(RouteMap widget) {
    if (widget.followRider && widget.position != null) {
      if (!_followCamera) {
        _followCamera = true;
        initialCenter = _project(widget.position!);
        initialZoom = streetZoom(
          widget.tileSource.minZoom,
          widget.tileSource.maxZoom,
        );
        locked = true;
        refit.value++;
      }
      return;
    }
    if (locked) return;
    final box = widget.bounds ?? _boundsOf(widget);
    if (widget.bounds != null) {
      initialCenter = LatLng(box!.center.lat, box.center.lng);
      initialZoom = _zoomForSpan(box);
    } else if (box == null) {
      final center = widget.center ?? const GeoPoint(39.90923, 116.397428);
      initialCenter = _project(center);
      initialZoom = widget.zoom;
      return;
    } else {
      initialCenter = _project(box.center);
      initialZoom = _zoomForSpan(box);
    }
    locked = true;
    refit.value++;
  }

  GeoBounds? _boundsOf(RouteMap widget) {
    var south = 0.0;
    var north = 0.0;
    var west = 0.0;
    var east = 0.0;
    var any = false;

    void add(GeoPoint point) {
      if (!any) {
        south = north = point.lat;
        west = east = point.lng;
        any = true;
        return;
      }
      if (point.lat < south) south = point.lat;
      if (point.lat > north) north = point.lat;
      if (point.lng < west) west = point.lng;
      if (point.lng > east) east = point.lng;
    }

    for (final point in widget.routePoints) {
      add(point);
    }
    for (final point in widget.trackPoints) {
      add(point);
    }
    for (final point in widget.fitPoints) {
      add(point);
    }
    if (!any) return null;
    return GeoBounds(south: south, west: west, north: north, east: east);
  }

  LatLng _project(GeoPoint point) {
    if (_datum != MapDatum.gcj02) return LatLng(point.lat, point.lng);
    final shifted = CoordTransform.wgs84ToGcj02(point);
    return LatLng(shifted.lat, shifted.lng);
  }

  List<LatLng> _projectAll(List<GeoPoint> points) {
    if (points.isEmpty) return const [];
    return [for (final point in points) _project(point)];
  }

  void _setLine(ValueNotifier<List<LatLng>> slot, List<LatLng> next) {
    final current = slot.value;
    if (current.length == next.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (current[i].latitude != next[i].latitude ||
            current[i].longitude != next[i].longitude) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    slot.value = next;
  }

  /// Street zoom for the riding map.
  ///
  /// About 400 m ahead of a centered rider on the short side of the riding
  /// map. In landscape that side is the map's height: the turn banner and
  /// the controls sit beside it, not above and below.
  static const streetZoomLevel = 15.5;

  static double streetZoom(double min, double max) {
    if (streetZoomLevel < min) return min;
    if (streetZoomLevel > max) return max;
    return streetZoomLevel;
  }

  /// Converts a bounding box into a zoom level.
  ///
  /// The 1.8 factor leaves roughly a 50% margin around the geometry, so the
  /// line does not run to the exact edge of the screen. A degenerate box
  /// (one point) is a street-level view.
  static double _zoomForSpan(GeoBounds box) {
    final latSpan = (box.north - box.south).abs();
    final lngSpan = (box.east - box.west).abs();
    final span = latSpan > lngSpan ? latSpan : lngSpan;
    if (span <= 0) return 16;

    final zoom = math.log(360 / (span * 1.8)) / math.ln2;
    return zoom.clamp(3.0, 17.0);
  }
}

class _CameraCue {
  const _CameraCue({
    this.follow = false,
    this.far = false,
    this.rider,
    this.nearbyEpoch = 0,
    this.routeEpoch = 0,
  });

  final bool follow;
  final bool far;
  final LatLng? rider;
  final int nearbyEpoch;
  final int routeEpoch;

  bool same(_CameraCue other) =>
      follow == other.follow &&
      far == other.far &&
      nearbyEpoch == other.nearbyEpoch &&
      routeEpoch == other.routeEpoch &&
      _sameLatLng(rider, other.rider);
}

class _Chrome {
  const _Chrome({
    required this.interactive,
    required this.minZoom,
    required this.maxZoom,
    this.surfaceTap = false,
  });

  final bool interactive;
  final double minZoom;
  final double maxZoom;
  final bool surfaceTap;

  bool same(_Chrome other) =>
      interactive == other.interactive &&
      minZoom == other.minZoom &&
      maxZoom == other.maxZoom &&
      surfaceTap == other.surfaceTap;
}

class _TileView {
  const _TileView(this.source, this.showAttribution);

  final MapTileSource source;
  final bool showAttribution;

  bool same(_TileView other) =>
      showAttribution == other.showAttribution &&
      source.id == other.source.id &&
      source.urlTemplate == other.source.urlTemplate &&
      source.datum == other.source.datum &&
      source.minZoom == other.source.minZoom &&
      source.maxZoom == other.source.maxZoom &&
      source.dimTiles == other.source.dimTiles &&
      source.attribution == other.source.attribution &&
      _sameStrings(source.subdomains, other.source.subdomains);
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Rider {
  const _Rider(this.point, this.bearing);

  final LatLng? point;
  final double? bearing;

  bool same(_Rider other) {
    if (bearing != other.bearing) return false;
    return _sameLatLng(point, other.point);
  }
}

class _Places {
  const _Places({this.waypoints = const [], this.destination});

  final List<LatLng> waypoints;
  final LatLng? destination;

  bool same(_Places other) {
    if (!_sameLatLng(destination, other.destination)) return false;
    if (waypoints.length != other.waypoints.length) return false;
    for (var i = 0; i < waypoints.length; i++) {
      if (!_sameLatLng(waypoints[i], other.waypoints[i])) return false;
    }
    return true;
  }
}

bool _sameLatLng(LatLng? a, LatLng? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.latitude == b.latitude && a.longitude == b.longitude;
}

class _MapCanvas extends StatefulWidget {
  const _MapCanvas({required this.model});

  final _MapModel model;

  @override
  State<_MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<_MapCanvas> {
  final MapController _controller = MapController();
  late final List<Widget> _layers;
  late final StreamSubscription<MapEvent> _events;
  bool _ready = false;
  bool _pendingMove = false;
  bool _suspended = false;
  bool _followQueued = false;
  bool _resumeOnNext = false;
  bool _holdingStreet = false;
  int _seenRoute = 0;
  LatLng? _lastCenter;
  double _lastZoom = 0;

  /// A stopped fix wanders a few meters. Following that reads as the map
  /// swimming under the rider.
  static const _streetDeadzoneMeters = 8.0;
  static const _fitDeadzoneMeters = 12.0;

  @override
  void initState() {
    super.initState();
    final model = widget.model;
    _layers = [
      _TileHost(tiles: model.tiles),
      _LineHost(
        points: model.trackLine,
        color: AppColors.trackLine,
        strokeWidth: 5,
        borderWidth: 1.5,
      ),
      _LineHost(
        points: model.headLine,
        color: AppColors.trackLine,
        strokeWidth: 5,
        borderWidth: 1.5,
      ),
      _LineHost(
        points: model.routeLine,
        color: AppColors.routeLine,
        strokeWidth: 7,
        borderWidth: 2,
      ),
      _LineHost(
        points: model.routeJoin,
        color: AppColors.routeLine,
        strokeWidth: 7,
        borderWidth: 2,
      ),
      _RiderHost(rider: model.rider),
      _PlaceHost(places: model.places),
      _AttributionHost(tiles: model.tiles),
    ];
    model.chrome.addListener(_onChrome);
    model.refit.addListener(_onRefit);
    _seenRoute = model.camera.value.routeEpoch;
    model.camera.addListener(_onCamera);
    _events = _controller.mapEventStream.listen(_onMapEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ready = true;
      if (_pendingMove) {
        _pendingMove = false;
        _move();
      }
      _tickFollow();
    });
  }

  @override
  void dispose() {
    _events.cancel();
    widget.model.chrome.removeListener(_onChrome);
    widget.model.refit.removeListener(_onRefit);
    widget.model.camera.removeListener(_onCamera);
    _controller.dispose();
    super.dispose();
  }

  void _onMapEvent(MapEvent event) {
    if (!_userMovedCamera(event.source)) return;
    if (!widget.model.camera.value.follow || _suspended) return;
    _suspended = true;
    _lastCenter = null;
    _holdingStreet = false;
    if (mounted) setState(() {});
  }

  /// Programmatic moves use [MapEventSource.mapController] and must not
  /// suspend follow. Taps do not move the camera either.
  bool _userMovedCamera(MapEventSource source) {
    return switch (source) {
      MapEventSource.dragStart ||
      MapEventSource.onDrag ||
      MapEventSource.dragEnd ||
      MapEventSource.multiFingerGestureStart ||
      MapEventSource.onMultiFinger ||
      MapEventSource.multiFingerEnd ||
      MapEventSource.flingAnimationController ||
      MapEventSource.doubleTap ||
      MapEventSource.doubleTapHold ||
      MapEventSource.doubleTapZoomAnimationController ||
      MapEventSource.scrollWheel ||
      MapEventSource.keyboard ||
      MapEventSource.cursorKeyboardRotation => true,
      _ => false,
    };
  }

  void _onCamera() {
    final cue = widget.model.camera.value;
    if (cue.routeEpoch != _seenRoute) {
      _seenRoute = cue.routeEpoch;
      if (cue.follow && _suspended) _resumeOnNext = true;
    }
    if (!cue.follow && _suspended) {
      _suspended = false;
      _resumeOnNext = false;
      if (mounted) setState(() {});
    }
    _scheduleFollow();
  }

  void _scheduleFollow() {
    if (_followQueued) return;
    _followQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followQueued = false;
      if (!mounted) return;
      if (_resumeOnNext) {
        _resumeOnNext = false;
        if (_suspended) {
          _suspended = false;
          _lastCenter = null;
          _holdingStreet = false;
          setState(() {});
        }
      }
      _tickFollow();
    });
  }

  void _resumeFollow() {
    _suspended = false;
    _lastCenter = null;
    _holdingStreet = false;
    setState(() {});
    _tickFollow();
  }

  void _tickFollow() {
    if (!_ready || _suspended) return;
    final cue = widget.model.camera.value;
    final rider = cue.rider;
    if (!cue.follow || rider == null) return;

    if (cue.far) {
      _holdingStreet = false;
      _fitRiderAndRoute(rider);
      return;
    }
    if (!_holdingStreet) {
      _lastCenter = null;
      _holdingStreet = true;
    }
    final zoom = _streetZoom();
    if (_lastCenter != null &&
        _meters(_lastCenter!, rider) < _streetDeadzoneMeters &&
        (_lastZoom - zoom).abs() < 0.01) {
      return;
    }
    _controller.move(rider, zoom);
    _lastCenter = rider;
    _lastZoom = zoom;
  }

  double _streetZoom() {
    final chrome = widget.model.chrome.value;
    return _MapModel.streetZoom(chrome.minZoom, chrome.maxZoom);
  }

  void _fitRiderAndRoute(LatLng rider) {
    final points = <LatLng>[rider, ...widget.model.nearbyAhead];
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points) {
      if (point.latitude < south) south = point.latitude;
      if (point.latitude > north) north = point.latitude;
      if (point.longitude < west) west = point.longitude;
      if (point.longitude > east) east = point.longitude;
    }
    final center = LatLng((south + north) / 2, (west + east) / 2);
    final spanLat = (north - south).abs();
    final spanLng = (east - west).abs();
    final span = spanLat > spanLng ? spanLat : spanLng;
    final chrome = widget.model.chrome.value;
    final street = _streetZoom();
    var zoom = span <= 0 ? street : math.log(360 / (span * 1.8)) / math.ln2;
    if (zoom > street) zoom = street;
    if (zoom < chrome.minZoom) zoom = chrome.minZoom;
    if (zoom > chrome.maxZoom) zoom = chrome.maxZoom;
    if (_lastCenter != null &&
        _meters(_lastCenter!, center) < _fitDeadzoneMeters &&
        (_lastZoom - zoom).abs() < 0.15) {
      return;
    }
    _controller.move(center, zoom);
    _lastCenter = center;
    _lastZoom = zoom;
  }

  double _meters(LatLng a, LatLng b) =>
      haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude);

  void _onChrome() {
    if (mounted) setState(() {});
  }

  void _onRefit() {
    if (!_ready) {
      _pendingMove = true;
      return;
    }
    _move();
  }

  void _move() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.model.locked) return;
      // Once the rider owns the camera, follow moves it. Until then this
      // is the one-shot fit (the whole route, or the rider when the first
      // fix arrives before the map has been laid out).
      if (widget.model.followHasCenter) return;
      _controller.move(widget.model.initialCenter, widget.model.initialZoom);
    });
  }

  void _handleMapTap(TapPosition _, LatLng point) {
    final handler = widget.model.onMapTap;
    if (handler == null) return;
    final selected = GeoPoint(point.latitude, point.longitude);
    handler(
      widget.model.tiles.value.source.datum == MapDatum.gcj02
          ? CoordTransform.gcj02ToWgs84(selected)
          : selected,
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final chrome = model.chrome.value;
    final map = FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: model.initialCenter,
        initialZoom: model.initialZoom,
        backgroundColor: AppColors.background,
        minZoom: chrome.minZoom,
        maxZoom: chrome.maxZoom,
        onTap: _handleMapTap,
        interactionOptions: InteractionOptions(
          flags: chrome.interactive
              ? InteractiveFlag.all & ~InteractiveFlag.rotate
              : InteractiveFlag.none,
        ),
      ),
      children: _layers,
    );

    final showRecenter = model.camera.value.follow && _suspended;
    return ColoredBox(
      color: AppColors.background,
      child: Stack(
        children: [
          chrome.surfaceTap
              ? GestureDetector(
                  onTap: () => model.onSurfaceTap?.call(),
                  child: map,
                )
              : map,
          if (showRecenter)
            Positioned(
              left: 0,
              right: 0,
              bottom: 36,
              child: Center(child: _RecenterButton(onPressed: _resumeFollow)),
            ),
        ],
      ),
    );
  }
}

class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '回到当前位置',
      child: Material(
        color: AppColors.scrim,
        shape: const CircleBorder(
          side: BorderSide(color: AppColors.hairlineStrong),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.my_location, size: 22, semanticLabel: '回到当前位置'),
          ),
        ),
      ),
    );
  }
}

class _LineHost extends StatelessWidget {
  const _LineHost({
    required this.points,
    required this.color,
    required this.strokeWidth,
    required this.borderWidth,
  });

  final ValueNotifier<List<LatLng>> points;
  final Color color;
  final double strokeWidth;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<LatLng>>(
      valueListenable: points,
      builder: (context, line, _) {
        if (line.length < 2) return const SizedBox.shrink();
        return PolylineLayer(
          polylines: [
            Polyline(
              points: line,
              strokeWidth: strokeWidth,
              color: color,
              borderStrokeWidth: borderWidth,
              borderColor: Colors.black,
            ),
          ],
        );
      },
    );
  }
}

class _TileHost extends StatelessWidget {
  const _TileHost({required this.tiles});

  final ValueNotifier<_TileView> tiles;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_TileView>(
      valueListenable: tiles,
      builder: (context, view, _) {
        final tile = view.source;
        return TileLayer(
          urlTemplate: tile.urlTemplate,
          subdomains: tile.subdomains,
          maxZoom: tile.maxZoom,
          minZoom: tile.minZoom,
          userAgentPackageName: 'app.purecycling.cycling_app',
          tileBuilder: tile.dimTiles ? _dimTileBuilder : null,
        );
      },
    );
  }
}

class _RiderHost extends StatelessWidget {
  const _RiderHost({required this.rider});

  final ValueNotifier<_Rider> rider;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_Rider>(
      valueListenable: rider,
      builder: (context, mark, _) {
        final point = mark.point;
        if (point == null) return const SizedBox.shrink();
        return MarkerLayer(
          markers: [
            Marker(
              point: point,
              width: 44,
              height: 44,
              child: _PositionDot(bearing: mark.bearing),
            ),
          ],
        );
      },
    );
  }
}

class _PlaceHost extends StatelessWidget {
  const _PlaceHost({required this.places});

  final ValueNotifier<_Places> places;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_Places>(
      valueListenable: places,
      builder: (context, place, _) {
        if (place.waypoints.isEmpty && place.destination == null) {
          return const SizedBox.shrink();
        }
        return MarkerLayer(
          markers: [
            for (var i = 0; i < place.waypoints.length; i++)
              Marker(
                point: place.waypoints[i],
                width: 30,
                height: 30,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.accent, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      '${i + 1}',
                      style: AppText.label.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            if (place.destination != null)
              Marker(
                point: place.destination!,
                width: 22,
                height: 22,
                child: const _DestinationMark(),
              ),
          ],
        );
      },
    );
  }
}

class _AttributionHost extends StatelessWidget {
  const _AttributionHost({required this.tiles});

  final ValueNotifier<_TileView> tiles;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_TileView>(
      valueListenable: tiles,
      builder: (context, view, _) {
        final text = view.source.attribution;
        if (!view.showAttribution || text == null) {
          return const SizedBox.shrink();
        }
        return _Attribution(text: text);
      },
    );
  }
}

/// Dims light-only raster tiles for night use, without greying them out.
///
/// AMap's basemap has no dark style and, on an OLED phone at night, is a
/// torch. The shape of that basemap decides how it has to be re-toned, and
/// it is not the obvious way:
///
/// * It is light *everywhere*. The background is cream, the roads are white
///   on top of it, and the two differ by about five steps of brightness.
///   Anything that scales the image uniformly — a black overlay, a
///   straight multiply — scales that five-step gap along with everything
///   else, so the map survives as a flat grey field with a faint road grid
///   in it. The information was only ever in the colour.
/// * An equal-weight matrix, the other obvious filter, is plain
///   desaturation and throws the colour away outright.
///
/// So the transform splits each pixel into what carries its brightness and
/// what carries its colour, and treats the two differently: brightness is
/// cut to 20%, colour is kept at 80%. Water stays blue, parks stay green,
/// the warm arterials stay distinct from the white minor roads — at a fifth
/// of the light.
///
/// The small blue offset cancels AMap's cream base, which would otherwise
/// leave the whole map with a sepia cast next to the pure-black chrome.
///
/// The matrix is that transform with the luminance weights (0.2126, 0.7152,
/// 0.0722) multiplied out, so it can stay a matrix — one GPU pass per tile.
Widget _dimTileBuilder(BuildContext context, Widget tile, TileImage _) {
  return ColorFiltered(
    colorFilter: const ColorFilter.matrix(<double>[
      0.6724, -0.4291, -0.0433, 0, 0, //
      -0.1276, 0.3709, -0.0433, 0, 1, //
      -0.1276, -0.4291, 0.7567, 0, 6, //
      0, 0, 0, 1, 0,
    ]),
    child: tile,
  );
}

/// The rider. A wedge when the heading is known, a disc when it is not.
///
/// Both are flat accent with a black edge, the same treatment as the route
/// line, so the mark stays readable on a light basemap and on the dimmed one.
class _PositionDot extends StatelessWidget {
  const _PositionDot({this.bearing});

  final double? bearing;

  @override
  Widget build(BuildContext context) {
    final heading = bearing;
    if (heading == null) {
      return Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent,
            border: Border.all(color: Colors.black, width: 2),
          ),
        ),
      );
    }
    return Center(
      child: Transform.rotate(
        angle: heading * math.pi / 180.0,
        child: const CustomPaint(size: Size(26, 26), painter: _WedgePainter()),
      ),
    );
  }
}

class _WedgePainter extends CustomPainter {
  const _WedgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 2)
      ..lineTo(size.width - 4, size.height - 3)
      ..lineTo(size.width / 2, size.height - 9)
      ..lineTo(4, size.height - 3)
      ..close();
    canvas.drawPath(path, Paint()..color = AppColors.accent);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _WedgePainter oldDelegate) => false;
}

/// A short diamond at the end of the route. The line already ends here;
/// the mark is only so the end reads as a place.
class _DestinationMark extends StatelessWidget {
  const _DestinationMark();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Transform.rotate(
        angle: math.pi / 4,
        child: Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: AppColors.accent,
            border: Border.all(color: Colors.black, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// Tile-provider attribution, required by their terms of use.
class _Attribution extends StatelessWidget {
  const _Attribution({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: AppColors.scrimSoft),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A map with no interaction, for list thumbnails and detail headers.
class StaticRouteMap extends StatelessWidget {
  const StaticRouteMap({
    super.key,
    required this.tileSource,
    required this.points,
    this.height = 200,
    this.strokeWidth = 4,
  });

  final MapTileSource tileSource;
  final List<GeoPoint> points;
  final double height;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('暂无轨迹', style: AppText.caption)),
      );
    }

    return SizedBox(
      height: height,
      child: RouteMap(
        tileSource: tileSource,
        trackPoints: points,
        interactive: false,
      ),
    );
  }
}
