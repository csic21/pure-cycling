import 'package:cycling_app/core/map/route_remainder.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const origin = GeoPoint(31.2, 121.5);

  GeoPoint north(double meters) =>
      GeoPoint(origin.lat + meters / 111132.92, origin.lng);

  List<GeoPoint> northLine(double step, int count) => [
    for (var i = 0; i < count; i++) north(step * i),
  ];

  test(
    'the accent line starts at the next vertex and joins across the gap',
    () {
      final line = northLine(100, 6);
      final snap = north(150);

      final cut = cutRoute(line: line, snap: snap, hintSegment: 1);

      expect(cut.segment, 1);
      expect(cut.fromIndex, 2);
      expect(cut.joinFrom, snap);
      expect(cut.joinTo, line[2]);
    },
  );

  test('moving along the same segment does not advance the long line', () {
    final line = northLine(100, 6);

    final first = cutRoute(line: line, snap: north(150), hintSegment: 1);
    final later = cutRoute(line: line, snap: north(180), hintSegment: 1);

    expect(later.fromIndex, first.fromIndex);
    expect(later.segment, first.segment);
  });

  test('a snap already on a vertex does not grow a connector', () {
    final line = northLine(100, 6);
    final snap = north(198);

    final cut = cutRoute(line: line, snap: snap, hintSegment: 1);

    expect(cut.fromIndex, 2);
    expect(cut.joinFrom, isNull);
    expect(cut.joinTo, isNull);
  });

  test('off route keeps the road and does not draw a spur to the rider', () {
    final line = northLine(100, 6);
    final beside = GeoPoint(north(150).lat, north(150).lng + 0.001);

    final cut = cutRoute(
      line: line,
      snap: beside,
      hintSegment: 1,
      offRoute: true,
    );

    expect(cut.segment, 1);
    expect(cut.fromIndex, 1);
    expect(cut.joinFrom, isNull);
  });

  test('a road that loops back stays on the hinted pass', () {
    final loop = [north(0), north(200), north(400), north(200), north(0)];
    final snap = north(100);

    final outbound = cutRoute(line: loop, snap: snap, hintSegment: 0);
    final returning = cutRoute(line: loop, snap: snap, hintSegment: 3);

    expect(outbound.segment, 0);
    expect(returning.segment, 3);
  });

  test('a hint window that missed the rider falls back to the whole line', () {
    final line = northLine(100, 10);

    final cut = cutRoute(
      line: line,
      snap: north(550),
      hintSegment: 0,
      windowBehind: 0,
      windowAhead: 1,
    );

    expect(cut.segment, 5);
    expect(cut.fromIndex, 6);
  });

  test('progress on the full route scales onto the simplified line', () {
    final cumulative = [0.0, 100.0, 200.0, 300.0, 400.0, 500.0];

    final hint = hintSegmentForProgress(
      cumulative: cumulative,
      progressMeters: 500,
      fullLengthMeters: 1000,
    );

    expect(hint, 2);
  });

  test('the off-route lookahead reaches the requested distance', () {
    final line = northLine(100, 8);
    final cumulative = cumulativeMeters(line);

    final ahead = verticesAhead(line, cumulative, 1, 250);

    expect(ahead.first, line[1]);
    expect(ahead.last, line[4]);
  });
}
