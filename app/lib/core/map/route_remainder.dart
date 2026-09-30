import '../utils/geo.dart';

/// Where the accent route line starts, on an already-simplified polyline.
///
/// Navigation measures progress on the full-resolution route. The map draws
/// a thinned copy, and those two lengths differ, so the cut is the simplified
/// vertex just ahead of [snap], searched near a hint segment. The hint is the
/// vertex that the full-route distance corresponds to. Searching the whole
/// line would jump to a later lap where the road crosses itself.
class RouteCut {
  const RouteCut({
    required this.segment,
    required this.fromIndex,
    this.joinFrom,
    this.joinTo,
  });

  /// Segment of the simplified line that [snap] fell on.
  final int segment;

  /// First vertex of the line still ahead. The long polyline is
  /// `line.sublist(fromIndex)` and only changes when this index does.
  final int fromIndex;

  /// The open gap from the rider to [fromIndex]. Both null when that gap
  /// should not be drawn: the rider is off the route, or already on the vertex.
  final GeoPoint? joinFrom;
  final GeoPoint? joinTo;
}

/// Cuts [line] so the accent polyline is the route still ahead of [snap].
///
/// [hintSegment] limits the search. When the best match in that window is
/// farther than [windowAcceptMeters], the whole line is scanned — the rider
/// left the neighbourhood the hint described.
RouteCut cutRoute({
  required List<GeoPoint> line,
  required GeoPoint snap,
  int hintSegment = 0,
  bool offRoute = false,
  int windowBehind = 48,
  int windowAhead = 48,
  double windowAcceptMeters = 120,
  double joinMinMeters = 4,
}) {
  if (line.length < 2) {
    return RouteCut(segment: 0, fromIndex: line.length);
  }

  final lastSeg = line.length - 2;
  final hint = hintSegment.clamp(0, lastSeg);
  final windowStart = (hint - windowBehind).clamp(0, lastSeg);
  final windowEnd = (hint + windowAhead).clamp(0, lastSeg);

  var segment = _bestSegment(line, snap, windowStart, windowEnd, hint);
  final windowOffset = distanceToSegmentMeters(
    snap.lat,
    snap.lng,
    line[segment].lat,
    line[segment].lng,
    line[segment + 1].lat,
    line[segment + 1].lng,
  );
  if (windowOffset > windowAcceptMeters) {
    segment = _bestSegment(line, snap, 0, lastSeg, hint);
  }

  final t = projectionFactorOnSegment(
    snap.lat,
    snap.lng,
    line[segment].lat,
    line[segment].lng,
    line[segment + 1].lat,
    line[segment + 1].lng,
  );

  // On the route the accent line starts at the next vertex; the caller draws
  // a two-point connector across the open segment. Off the route, keep the
  // vertex at the start of this segment so the road they left is still there,
  // and do not stroke a spur out to the rider.
  final fromIndex = offRoute || t < 0.08 ? segment : segment + 1;

  GeoPoint? joinFrom;
  GeoPoint? joinTo;
  if (!offRoute && fromIndex < line.length) {
    final next = line[fromIndex];
    final gap = haversineMeters(snap.lat, snap.lng, next.lat, next.lng);
    if (gap >= joinMinMeters) {
      joinFrom = snap;
      joinTo = next;
    }
  }

  return RouteCut(
    segment: segment,
    fromIndex: fromIndex,
    joinFrom: joinFrom,
    joinTo: joinTo,
  );
}

int _bestSegment(
  List<GeoPoint> line,
  GeoPoint snap,
  int start,
  int end,
  int hint,
) {
  var best = double.infinity;
  var bestSeg = start;
  var bestHint = (start - hint).abs();
  for (var i = start; i <= end; i++) {
    final distance = distanceToSegmentMeters(
      snap.lat,
      snap.lng,
      line[i].lat,
      line[i].lng,
      line[i + 1].lat,
      line[i + 1].lng,
    );
    final hintDist = (i - hint).abs();
    if (distance + 1 < best || (distance <= best + 1 && hintDist < bestHint)) {
      best = distance;
      bestSeg = i;
      bestHint = hintDist;
    }
  }
  return bestSeg;
}

/// Segment index whose span contains [distance] along [cumulative].
int segmentAtDistance(List<double> cumulative, double distance) {
  if (cumulative.length < 2) return 0;
  if (distance <= 0) return 0;
  if (distance >= cumulative.last) return cumulative.length - 2;

  var low = 0;
  var high = cumulative.length - 1;
  while (low < high - 1) {
    final mid = (low + high) ~/ 2;
    if (cumulative[mid] <= distance) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return low;
}

/// Maps a distance measured on the full route onto the simplified line.
///
/// The simplified line is shorter (chords cut corners). Scaling by the two
/// lengths puts the hint on the right neighbourhood; [cutRoute] then snaps
/// to the vertex the rider is actually beside.
int hintSegmentForProgress({
  required List<double> cumulative,
  required double progressMeters,
  required double fullLengthMeters,
}) {
  if (cumulative.length < 2) return 0;
  final simple = cumulative.last;
  final scaled = fullLengthMeters > 1
      ? progressMeters * (simple / fullLengthMeters)
      : progressMeters;
  return segmentAtDistance(cumulative, scaled);
}

/// Meters from the start of [points] to each vertex. Index 0 is 0.
List<double> cumulativeMeters(List<GeoPoint> points) {
  if (points.isEmpty) return const [];
  final out = List<double>.filled(points.length, 0);
  for (var i = 1; i < points.length; i++) {
    out[i] =
        out[i - 1] +
        haversineMeters(
          points[i - 1].lat,
          points[i - 1].lng,
          points[i].lat,
          points[i].lng,
        );
  }
  return out;
}

/// Vertices from [fromIndex] forward until [meters] past that vertex.
///
/// Includes the vertex that crosses [meters], so a long straight still
/// reaches the requested distance.
List<GeoPoint> verticesAhead(
  List<GeoPoint> line,
  List<double> cumulative,
  int fromIndex,
  double meters,
) {
  if (line.isEmpty || fromIndex >= line.length || fromIndex < 0) {
    return const [];
  }
  final limit = cumulative[fromIndex] + meters;
  var last = fromIndex;
  while (last + 1 < line.length && cumulative[last] < limit) {
    last++;
  }
  return line.sublist(fromIndex, last + 1);
}
