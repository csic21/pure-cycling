import 'dart:math' as math;

import 'package:cycling_app/core/map/display_track.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/core/utils/geometry_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const origin = GeoPoint(31.23, 121.47);

  GeoPoint offset(GeoPoint from, double northMeters, double eastMeters) {
    final lat = from.lat * math.pi / 180;
    return GeoPoint(
      from.lat + northMeters / 111132.92,
      from.lng + eastMeters / (111319.49 * math.cos(lat)),
    );
  }

  test('jitter inside the step does not add a vertex', () {
    final track = DisplayTrack();
    final raw = <GeoPoint>[origin];
    expect(track.ingest(raw), isTrue);

    for (var i = 0; i < 40; i++) {
      raw.add(offset(origin, 2, 0));
      expect(track.ingest(raw), isFalse);
    }

    expect(track.line, [origin]);
    expect(track.head, raw.last);
    expect(track.lastVertex, origin);
  });

  test('a fix appended to the same list does not rebuild the prefix', () {
    final track = DisplayTrack();
    final raw = <GeoPoint>[origin];
    for (var i = 1; i <= 20; i++) {
      raw.add(offset(origin, i * 20.0, 0));
    }
    track.ingest(raw);
    final kept = track.line.length;

    raw.add(offset(origin, 20 * 20.0 + 2, 0));
    expect(track.ingest(raw), isFalse);
    expect(track.line.length, kept);

    raw.add(offset(origin, 20 * 20.0 + 30, 0));
    expect(track.ingest(raw), isTrue);
    expect(track.line.length, kept + 1);
    expect(track.line.first, origin);
  });

  test('reading the same list again does no work', () {
    final track = DisplayTrack();
    final raw = [origin, offset(origin, 40, 0)];
    track.ingest(raw);
    expect(track.ingest(raw), isFalse);
  });

  test('keeps a corner that is shorter than the step', () {
    final track = DisplayTrack(
      stepMeters: 30,
      cornerMeters: 4,
      cornerDegrees: 28,
    );
    final corner = offset(origin, 30, 0);
    final turned = offset(corner, 0, 6);
    final raw = [origin, corner, turned];

    track.ingest(raw);

    expect(track.line, contains(corner));
    expect(track.line, contains(turned));
  });

  test('a long trace stays within the vertex budget', () {
    final raw = <GeoPoint>[];
    for (var i = 0; i < 8000; i++) {
      raw.add(offset(origin, i * 15.0, math.sin(i / 8) * 40));
    }
    final track = DisplayTrack();
    expect(track.ingest(raw), isTrue);

    expect(track.line.length, lessThan(800));
    expect(track.line.length, greaterThan(20));
    expect(track.line.first, raw.first);
    expect(track.head, raw.last);
  });

  test('a route commits its destination onto the line', () {
    final end = offset(origin, 3, 0);
    final track = DisplayTrack(commitEndpoint: true, stepMeters: 8);
    track.ingest([origin, end]);

    expect(track.line, contains(end));
    expect(track.lastVertex, end);
  });

  test('simplifyForDisplay caps a curving trace and keeps its ends', () {
    // A sine, not a pure zigzag: every spike the same height collapses to the
    // two endpoints the moment the tolerance exceeds that height, so there is
    // no intermediate vertex count for the cap to land on.
    final points = <GeoPoint>[
      for (var i = 0; i < 2000; i++)
        offset(origin, i * 20.0, math.sin(i / 6) * (40 + i / 20)),
    ];

    final simplified = simplifyForDisplay(
      points,
      maxVertices: 80,
      minToleranceMeters: 1,
    );

    expect(simplified.length, lessThanOrEqualTo(80));
    expect(simplified.length, greaterThan(2));
    expect(simplified.first, points.first);
    expect(simplified.last, points.last);
  });

  test(
    'simplifyForDisplay leaves a short straight trace ending where it ended',
    () {
      final points = [for (var i = 0; i < 5; i++) GeoPoint(30 + i * 0.01, 120)];

      final simplified = simplifyForDisplay(
        points,
        maxVertices: 100,
        minToleranceMeters: 4,
      );

      expect(simplified.first, points.first);
      expect(simplified.last, points.last);
      expect(simplified.length, lessThanOrEqualTo(points.length));
    },
  );
}
