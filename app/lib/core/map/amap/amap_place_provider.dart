import '../../utils/geo.dart';
import '../coord_transform.dart';
import '../map_providers.dart';
import 'amap_client.dart';

/// POI search and reverse geocoding via AMap's `/v3/place/text` and
/// `/v3/geocode/regeo`.
class AmapPlaceProvider implements PlaceProvider {
  AmapPlaceProvider({required this.client});

  final AmapClient client;

  @override
  String get id => 'amap';

  @override
  String get displayName => '高德';

  @override
  bool get isConfigured => client.isConfigured;

  @override
  Future<List<PlaceSuggestion>> search(
    String query, {
    GeoPoint? near,
    int limit = 10,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final body = await client.get('/v3/place/text', {
      'keywords': trimmed,
      'offset': limit.clamp(1, 25).toString(),
      'page': '1',
      'extensions': 'base',
      // Without a city, AMap biases results nationally and a rider searching
      // for 「人民广场」 gets one three provinces away.
      if (near != null) 'location': _format(CoordTransform.wgs84ToGcj02(near)),
      if (near != null) 'sortrule': 'distance',
    });

    return _parsePois(body, near);
  }

  @override
  Future<PlaceSuggestion?> reverseGeocode(GeoPoint point) async {
    final body = await client.get('/v3/geocode/regeo', {
      'location': _format(CoordTransform.wgs84ToGcj02(point)),
      'extensions': 'base',
      'radius': '200',
    });

    final regeocode = body['regeocode'];
    if (regeocode is! Map<String, dynamic>) return null;

    final component = regeocode['addressComponent'];
    final formatted = regeocode['formatted_address']?.toString();
    if (formatted == null || formatted.isEmpty) return null;

    // `formatted_address` is the whole address; a shorter, more useful label
    // comes from the street or neighbourhood when AMap supplies one.
    final label = _shortLabel(component) ?? formatted;

    return PlaceSuggestion(
      name: label,
      address: formatted,
      point: point,
    );
  }

  List<PlaceSuggestion> _parsePois(Map<String, dynamic> body, GeoPoint? near) {
    final pois = body['pois'];
    if (pois is! List) return const [];

    final out = <PlaceSuggestion>[];
    for (final raw in pois) {
      if (raw is! Map<String, dynamic>) continue;

      final location = raw['location']?.toString();
      if (location == null) continue;
      final parsed = _parseLocation(location);
      if (parsed == null) continue;

      // POI coordinates arrive in GCJ-02 like everything else from AMap.
      final wgs = CoordTransform.gcj02ToWgs84(parsed);

      final name = raw['name']?.toString() ?? '';
      if (name.isEmpty) continue;

      final address = _addressOf(raw);

      out.add(
        PlaceSuggestion(
          name: name,
          address: address,
          point: wgs,
          providerId: raw['id']?.toString(),
          distanceMeters: near == null
              ? null
              : haversineMeters(near.lat, near.lng, wgs.lat, wgs.lng),
        ),
      );
    }

    return out;
  }

  /// AMap's `address` field is sometimes a bare string and sometimes an object
  /// with an array of parts, depending on the endpoint and the POI type.
  static String? _addressOf(Map<String, dynamic> poi) {
    final address = poi['address'];
    if (address is String && address.isNotEmpty) return address;

    final parts = <String>[];
    void add(Object? v) {
      if (v == null) return;
      final s = v.toString().trim();
      if (s.isNotEmpty && s != '[]') parts.add(s);
    }

    add(poi['pname']);
    add(poi['cityname']);
    add(poi['adname']);
    if (parts.isEmpty && address is List) {
      for (final a in address) {
        add(a);
      }
    }
    return parts.isEmpty ? null : parts.join('');
  }

  static String? _shortLabel(Object? component) {
    if (component is! Map<String, dynamic>) return null;
    for (final key in ['streetNumber', 'township', 'neighborhood', 'building']) {
      final value = component[key];
      if (value is Map<String, dynamic>) {
        final street = value['street']?.toString();
        if (street != null && street.isNotEmpty) return street;
        final name = value['name']?.toString();
        if (name != null && name.isNotEmpty) return name;
      }
    }
    return null;
  }

  /// `"lng,lat"`.
  static GeoPoint? _parseLocation(String raw) {
    final comma = raw.indexOf(',');
    if (comma <= 0) return null;
    final lng = double.tryParse(raw.substring(0, comma));
    final lat = double.tryParse(raw.substring(comma + 1));
    if (lng == null || lat == null) return null;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return GeoPoint(lat, lng);
  }

  static String _format(GeoPoint p) =>
      '${p.lng.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}';
}
