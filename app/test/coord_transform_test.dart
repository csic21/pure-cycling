import 'package:cycling_app/core/map/coord_transform.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:flutter_test/flutter_test.dart';

/// The datum conversion is the difference between a track that follows the
/// road and one that runs 300 m beside it. It is also the kind of code that
/// looks correct while being quietly wrong, so it is pinned down here.
void main() {
  // Beijing, Shanghai and Shenzhen — the offsets vary substantially across
  // the country, so one sample would not catch a sign error.
  const beijing = GeoPoint(39.9042, 116.4074);
  const shanghai = GeoPoint(31.2304, 121.4737);
  const shenzhen = GeoPoint(22.5431, 114.0579);

  group('offset', () {
    test('shifts a Chinese coordinate by the expected order of magnitude', () {
      for (final point in [beijing, shanghai, shenzhen]) {
        final shifted = CoordTransform.wgs84ToGcj02(point);

        final delta = haversineMeters(
          point.lat,
          point.lng,
          shifted.lat,
          shifted.lng,
        );

        expect(
          delta,
          greaterThan(100),
          reason: 'the GCJ-02 offset is hundreds of metres, not zero',
        );
        expect(delta, lessThan(800));
      }
    });

    test('shifts north-east in China, never in a random direction', () {
      final shifted = CoordTransform.wgs84ToGcj02(beijing);

      expect(shifted.lat, greaterThan(beijing.lat));
      expect(shifted.lng, greaterThan(beijing.lng));
    });

    test('leaves coordinates outside China untouched', () {
      // The polynomial is only defined over Chinese territory. Applying it
      // elsewhere would move a ride in France by an arbitrary amount.
      const paris = GeoPoint(48.8566, 2.3522);
      const tokyo = GeoPoint(35.6762, 139.6503);
      const sydney = GeoPoint(-33.8688, 151.2093);

      for (final point in [paris, tokyo, sydney]) {
        final shifted = CoordTransform.wgs84ToGcj02(point);
        expect(shifted.lat, point.lat);
        expect(shifted.lng, point.lng);
      }
    });

    test('classifies the boundary correctly', () {
      expect(CoordTransform.outOfChina(39.9, 116.4), isFalse);
      expect(CoordTransform.outOfChina(48.8, 2.35), isTrue);
      expect(CoordTransform.outOfChina(0, 0), isTrue);
      // Hong Kong and Macau are inside the published bounding box but use
      // different datums in practice; the box is not a precision instrument.
      expect(CoordTransform.outOfChina(22.32, 114.17), isFalse);
    });
  });

  group('round trip', () {
    test('converting back recovers the original to well under a metre', () {
      for (final point in [beijing, shanghai, shenzhen]) {
        final roundTripped = CoordTransform.gcj02ToWgs84(
          CoordTransform.wgs84ToGcj02(point),
        );

        final error = haversineMeters(
          point.lat,
          point.lng,
          roundTripped.lat,
          roundTripped.lng,
        );

        expect(
          error,
          lessThan(0.05),
          reason: 'the iterative inverse must converge to centimetres',
        );
      }
    });

    test('holds over a long polyline, point by point', () {
      // A 10 km line sampled every 100 m.
      final origin = beijing;
      final points = [
        for (var i = 0; i <= 100; i++)
          GeoPoint(origin.lat + (i * 100.0) / 111132.0, origin.lng + i * 1e-4),
      ];

      final gcj = CoordTransform.wgs84ToGcj02List(points);
      final back = CoordTransform.gcj02ToWgs84List(gcj);

      expect(gcj.length, points.length);
      for (var i = 0; i < points.length; i++) {
        final error = haversineMeters(
          points[i].lat,
          points[i].lng,
          back[i].lat,
          back[i].lng,
        );
        expect(error, lessThan(0.05));
      }
    });

    test('a round trip outside China is the identity', () {
      const paris = GeoPoint(48.8566, 2.3522);
      final back = CoordTransform.gcj02ToWgs84(
        CoordTransform.wgs84ToGcj02(paris),
      );
      expect(back, paris);
    });
  });

  group('list helpers', () {
    test('short-circuit a wholly foreign polyline', () {
      final points = [
        const GeoPoint(48.8566, 2.3522),
        const GeoPoint(48.8600, 2.3600),
      ];

      // The same instance: nothing was allocated, because the first point
      // already proved the whole line is outside China.
      expect(identical(CoordTransform.wgs84ToGcj02List(points), points), isTrue);
    });

    test('handle an empty list without throwing', () {
      expect(CoordTransform.wgs84ToGcj02List(const []), isEmpty);
      expect(CoordTransform.gcj02ToWgs84List(const []), isEmpty);
    });
  });
}
