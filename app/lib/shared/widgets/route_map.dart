import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app/theme.dart';
import '../../core/map/coord_transform.dart';
import '../../core/map/map_providers.dart';
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
class RouteMap extends StatelessWidget {
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
  });

  final MapTileSource tileSource;

  /// Explicit centre. Ignored when [bounds] is given.
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

  @override
  Widget build(BuildContext context) {
    final toDisplay = _projector(tileSource.datum);

    final points = <LatLng>[
      ...routePoints.map(toDisplay),
      ...trackPoints.map(toDisplay),
      ...fitPoints.map(toDisplay),
    ];

    final camera = _cameraFor(points, toDisplay);

    return ColoredBox(
      // A pure black map container. While tiles are loading — or entirely
      // offline — the surface stays OLED-black rather than flashing grey.
      color: AppColors.background,
      child: GestureDetector(
        onTap: onTap,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: camera.center,
            initialZoom: camera.zoom,
            onTap: onMapTap == null
                ? null
                : (_, point) {
                    final selected = GeoPoint(point.latitude, point.longitude);
                    onMapTap!(
                      tileSource.datum == MapDatum.gcj02
                          ? CoordTransform.gcj02ToWgs84(selected)
                          : selected,
                    );
                  },
            minZoom: tileSource.minZoom,
            maxZoom: tileSource.maxZoom,
            // Rotation is off: a bike computer mounted on handlebars has no
            // use for a rotated map, and an accidental two-finger twist
            // mid-ride is disorienting and hard to undo with gloves on.
            interactionOptions: InteractionOptions(
              flags: interactive
                  ? InteractiveFlag.all & ~InteractiveFlag.rotate
                  : InteractiveFlag.none,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: tileSource.urlTemplate,
              subdomains: tileSource.subdomains,
              maxZoom: tileSource.maxZoom,
              minZoom: tileSource.minZoom,
              // The package name is required by the tile providers' policies.
              userAgentPackageName: 'app.purecycling.cycling_app',
              // Retroactively tinting the raster tiles is the only way to
              // darken AMap's light-only raster basemap, which matters on an
              // OLED screen at night. It is done with a colour matrix rather
              // than an overlay so the road detail stays legible.
              tileBuilder: tileSource.darkAvailable ? null : _darkenTileBuilder,
            ),
            if (trackPoints.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: trackPoints.map(toDisplay).toList(growable: false),
                    strokeWidth: 5,
                    color: AppColors.trackLine,
                    borderStrokeWidth: 1.5,
                    borderColor: Colors.black,
                  ),
                ],
              ),
            if (routePoints.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: routePoints.map(toDisplay).toList(growable: false),
                    strokeWidth: 7,
                    color: AppColors.routeLine,
                    borderStrokeWidth: 2,
                    borderColor: Colors.black,
                  ),
                ],
              ),
            if (position != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: toDisplay(position!),
                    width: 34,
                    height: 34,
                    child: _PositionDot(bearing: bearing),
                  ),
                ],
              ),
            if (waypoints.isNotEmpty)
              MarkerLayer(
                markers: [
                  for (var i = 0; i < waypoints.length; i++)
                    Marker(
                      point: toDisplay(waypoints[i]),
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
                ],
              ),
            if (destination != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: toDisplay(destination!),
                    width: 42,
                    height: 42,
                    child: const Icon(
                      Icons.place,
                      size: 38,
                      color: AppColors.accent,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
                ],
              ),
            if (showAttribution && tileSource.attribution != null)
              _Attribution(text: tileSource.attribution!),
          ],
        ),
      ),
    );
  }

  /// Chooses the camera from the geometry.
  ///
  /// Fitting the bounds of everything relevant — route, track and the rider —
  /// is what a rider wants when the map opens. Zooming to the current position
  /// would hide the shape of the ride they are looking at.
  ({LatLng center, double zoom}) _cameraFor(
    List<LatLng> points,
    LatLng Function(GeoPoint) toDisplay,
  ) {
    final box =
        bounds ?? (points.isEmpty ? null : _boundsOfDisplayPoints(points));

    if (box == null) {
      final c = center ?? const GeoPoint(39.90923, 116.397428); // Tiananmen.
      return (center: toDisplay(c), zoom: zoom);
    }

    return (
      center: LatLng(box.center.lat, box.center.lng),
      zoom: _zoomForSpan(box),
    );
  }

  /// Converts a bounding box into a zoom level.
  ///
  /// The 0.55 factor leaves roughly a 50% margin around the geometry, so the
  /// line does not run to the exact edge of the screen.
  static double _zoomForSpan(GeoBounds box) {
    final latSpan = (box.north - box.south).abs();
    final lngSpan = (box.east - box.west).abs();

    final span = latSpan > lngSpan ? latSpan : lngSpan;
    if (span <= 0) return 16;

    // 360° across 256 px is zoom 0; each level doubles the resolution. The
    // 1.8 factor is the margin — without it the geometry touches the edges.
    final zoom = math.log(360 / (span * 1.8)) / math.ln2;
    return zoom.clamp(3.0, 17.0);
  }

  static GeoBounds _boundsOfDisplayPoints(List<LatLng> points) {
    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final p in points.skip(1)) {
      if (p.latitude < south) south = p.latitude;
      if (p.latitude > north) north = p.latitude;
      if (p.longitude < west) west = p.longitude;
      if (p.longitude > east) east = p.longitude;
    }
    return GeoBounds(south: south, west: west, north: north, east: east);
  }

  static LatLng _toLatLng(GeoPoint p) => LatLng(p.lat, p.lng);

  /// Returns the projector from stored WGS-84 to the tile layer's datum.
  static LatLng Function(GeoPoint) _projector(MapDatum datum) {
    switch (datum) {
      case MapDatum.wgs84:
        return _toLatLng;
      case MapDatum.gcj02:
        return (p) {
          final shifted = CoordTransform.wgs84ToGcj02(p);
          return LatLng(shifted.lat, shifted.lng);
        };
    }
  }

  /// Dims and desaturates raster tiles for night use.
  static Widget _darkenTileBuilder(
    BuildContext context,
    Widget tile,
    TileImage _,
  ) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        // Luminance-preserving desaturation and a strong value cut. The
        // alternative — a translucent black overlay — greys the whole map
        // uniformly and loses the road hierarchy that makes it readable.
        0.28, 0.36, 0.10, 0, -22,
        0.28, 0.36, 0.10, 0, -22,
        0.28, 0.36, 0.10, 0, -22,
        0, 0, 0, 1, 0,
      ]),
      child: tile,
    );
  }
}

/// The rider's position marker — a filled dot with a heading chevron.
class _PositionDot extends StatelessWidget {
  const _PositionDot({this.bearing});

  final double? bearing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accentMuted,
          ),
        ),
        if (bearing != null)
          Transform.rotate(
            angle: bearing! * 3.1415926535 / 180.0,
            child: const Icon(
              Icons.navigation,
              size: 20,
              color: AppColors.accent,
            ),
          )
        else
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent,
              border: Border.all(color: Colors.black, width: 2),
            ),
          ),
      ],
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
