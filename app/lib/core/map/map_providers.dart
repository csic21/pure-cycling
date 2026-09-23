import '../../features/routes/domain/route.dart';
import '../utils/geo.dart';

/// Which datum a tile source or routing API speaks.
///
/// Declared by each provider so the UI can convert once, at the boundary,
/// instead of every call site remembering which service is configured.
enum MapDatum {
  /// GPS-native. Everything this app stores uses this.
  wgs84,

  /// The Chinese national datum used by AMap, Baidu and Tencent.
  gcj02,
}

/// Tile source configuration for the map widget.
///
/// Attributes required by the tile provider are set here rather than in the
/// widget, because the terms differ per provider and getting them wrong is a
/// licensing problem, not a rendering one.
class MapTileSource {
  const MapTileSource({
    required this.id,
    required this.name,
    required this.urlTemplate,
    required this.datum,
    this.subdomains = const ['a'],
    this.maxZoom = 19,
    this.minZoom = 3,
    this.attribution,
    this.darkAvailable = false,
  });

  final String id;
  final String name;

  /// `{s}`, `{z}`, `{x}`, `{y}` placeholders, as understood by `flutter_map`.
  final String urlTemplate;

  final MapDatum datum;
  final List<String> subdomains;
  final double maxZoom;
  final double minZoom;
  final String? attribution;

  /// Whether this source has a genuinely dark style. Raster AMap tiles do
  /// not, which is why the OLED theme dims the map container instead.
  final bool darkAvailable;

  /// AMap raster tiles. Publicly served and the only source with usable road
  /// detail inside China at the zoom levels a bike route needs.
  static const MapTileSource amapVector = MapTileSource(
    id: 'amap',
    name: '高德',
    urlTemplate:
        'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1'
        '&scale=1&style=8&x={x}&y={y}&z={z}',
    subdomains: ['1', '2', '3', '4'],
    datum: MapDatum.gcj02,
    maxZoom: 18,
    attribution: '© 高德地图',
  );

  /// OpenStreetMap. WGS-84 and correct outside China, which makes it the
  /// right fallback for the development/demo path and for rides abroad.
  static const MapTileSource osm = MapTileSource(
    id: 'osm',
    name: 'OpenStreetMap',
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    datum: MapDatum.wgs84,
    maxZoom: 19,
    attribution: '© OpenStreetMap contributors',
  );

  /// Carto dark basemap. Not useful in China, but it is the only dark raster
  /// source available without a key, and it is what the OLED preview uses.
  static const MapTileSource cartoDark = MapTileSource(
    id: 'carto_dark',
    name: 'Carto Dark',
    urlTemplate:
        'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    subdomains: ['a', 'b', 'c', 'd'],
    datum: MapDatum.wgs84,
    maxZoom: 19,
    attribution: '© OpenStreetMap contributors © CARTO',
    darkAvailable: true,
  );

  static const List<MapTileSource> all = [amapVector, osm, cartoDark];

  static MapTileSource byId(String id) => all.firstWhere(
        (s) => s.id == id,
        orElse: () => amapVector,
      );
}

/// A place returned by search or reverse geocoding.
class PlaceSuggestion {
  const PlaceSuggestion({
    required this.name,
    required this.point,
    this.address,
    this.distanceMeters,
    this.providerId,
  });

  final String name;
  final GeoPoint point;
  final String? address;
  final double? distanceMeters;
  final String? providerId;

  /// Always WGS-84, even when the provider answered in GCJ-02.
  GeoPoint get wgs84Point => point;

  PlaceResult toResult() => PlaceResult(
        name: name,
        point: point,
        address: address,
        distanceMeters: distanceMeters,
        id: providerId,
      );
}

/// Search and reverse geocoding.
abstract interface class PlaceProvider {
  String get id;
  String get displayName;

  /// False when the provider needs a key that has not been supplied. The UI
  /// disables the search field rather than failing at query time.
  bool get isConfigured;

  Future<List<PlaceSuggestion>> search(
    String query, {
    GeoPoint? near,
    int limit = 10,
  });

  Future<PlaceSuggestion?> reverseGeocode(GeoPoint point);
}

/// Routing preferences (spec §2.3 — mostly V2, but the seam exists now so the
/// UI and the route model do not need reshaping later).
enum RoutePreference {
  recommended('recommended', '推荐路线', supported: true),
  fewerTrafficLights('fewer_lights', '少红绿灯'),
  fewerCars('fewer_cars', '少机动车'),
  bikeLanes('bike_lanes', '骑行道优先'),
  flat('flat', '平路优先'),
  hilly('hilly', '爬坡路线');

  const RoutePreference(this.id, this.label, {this.supported = false});

  final String id;
  final String label;

  /// Whether any shipping provider can actually honour this today.
  ///
  /// The spec is explicit (§10) that bike-route quality is not a solved
  /// problem in China: AMap's cycling planner does not expose lane-preference
  /// parameters. Rather than silently ignoring a user choice, unsupported
  /// preferences are labelled as such in the UI.
  final bool supported;

  static RoutePreference fromId(String? id) =>
      RoutePreference.values.firstWhere(
        (p) => p.id == id,
        orElse: () => RoutePreference.recommended,
      );
}

/// Raised when planning cannot proceed — no key, no network, no route.
class RoutePlanningException implements Exception {
  const RoutePlanningException(this.message, {this.isConfiguration = false});

  final String message;

  /// True when the cause is a missing key rather than a transient failure, so
  /// the UI can point at settings instead of offering a retry.
  final bool isConfiguration;

  @override
  String toString() => message;
}

/// Route planning.
abstract interface class RouteProvider {
  String get id;
  String get displayName;

  /// Whether this provider can serve a request at all.
  ///
  /// True for the offline fallback too — it *can* answer, it just answers with
  /// a straight line. Ask [isDegraded] to find out whether the answer is a
  /// real bike route.
  bool get isConfigured;

  /// Whether the routes this provider produces are a stand-in rather than a
  /// real cycling route.
  ///
  /// Distinct from [isConfigured] on purpose, and the distinction is not
  /// pedantic. The offline provider is configured — it never fails, it never
  /// needs a key — so anything that asks "are we configured?" concludes the
  /// app is planning real routes, and the rider is never told that their route
  /// is a straight line across a river.
  bool get isDegraded;

  /// Which datum this provider expects and returns. The implementation is
  /// responsible for converting to WGS-84 on the way out.
  MapDatum get datum;

  Future<Route> planRoute({
    required GeoPoint origin,
    required GeoPoint destination,
    List<GeoPoint> waypoints = const [],
    RoutePreference preference = RoutePreference.recommended,
  });

  /// Re-plans from the rider's current position to the same destination
  /// (spec §8, 偏航后重新规划).
  Future<Route> rerouteFrom({
    required GeoPoint from,
    required Route original,
  });
}

/// A traffic light and its countdown, if the provider knows one.
class TrafficLightInfo {
  const TrafficLightInfo({
    required this.point,
    this.secondsRemaining,
    this.isRed,
    this.distanceMeters,
  });

  final GeoPoint point;

  /// Null when the light's phase is unknown — which is the honest answer for
  /// most intersections most of the time.
  final int? secondsRemaining;
  final bool? isRed;
  final double? distanceMeters;
}

/// Traffic light countdown (spec §11).
///
/// Deliberately separated from everything else. The capability exists in
/// AMap's two-wheeler SDK but its availability, licensing and cost are
/// unconfirmed, and it is an enhancement rather than a V1 dependency — so the
/// app must run, and navigate, with a provider that never answers.
abstract interface class TrafficLightProvider {
  String get id;
  bool get isAvailable;

  /// Why the provider is unavailable, for the settings screen.
  String? get unavailableReason;

  /// Lights on the route ahead of the rider, nearest first.
  Future<List<TrafficLightInfo>> lightsAhead({
    required GeoPoint position,
    required double headingDegrees,
    double withinMeters = 300,
  });
}

/// A provider that never reports anything, used when the capability is off.
class NullTrafficLightProvider implements TrafficLightProvider {
  const NullTrafficLightProvider([
    this.unavailableReason = '当前地图服务未提供红绿灯数据',
  ]);

  @override
  String get id => 'none';

  @override
  bool get isAvailable => false;

  @override
  final String? unavailableReason;

  @override
  Future<List<TrafficLightInfo>> lightsAhead({
    required GeoPoint position,
    required double headingDegrees,
    double withinMeters = 300,
  }) async =>
      const [];
}

/// The bundle of map capabilities the app runs against.
///
/// Pages depend on this, never on a concrete vendor (spec §33). Swapping AMap
/// for another service is one factory function, not a search across the
/// presentation layer for `AMap.` call sites.
class MapServices {
  const MapServices({
    required this.places,
    required this.routes,
    required this.trafficLights,
    required this.tileSource,
  });

  final PlaceProvider places;
  final RouteProvider routes;
  final TrafficLightProvider trafficLights;

  /// The tile layer matching [routes]' datum. Derived rather than configured
  /// separately, so a route can never be drawn on tiles in another datum.
  final MapTileSource tileSource;

  /// Whether the active routing provider produces real cycling routes.
  bool get canPlanRoutes => !routes.isDegraded;

  /// Whether the active routing provider can answer at all — including the
  /// offline fallback, which always can.
  bool get hasRouteProvider => routes.isConfigured;

  bool get canSearchPlaces => places.isConfigured;
}
