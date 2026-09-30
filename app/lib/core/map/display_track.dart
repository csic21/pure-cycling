import '../utils/geo.dart';
import '../utils/geometry_codec.dart';

/// The polyline a map should draw for a trace that keeps growing.
///
/// A ride publishes a fix about once a second. Handing every fix to the map
/// means reprojecting and retessellating the whole line on the UI isolate for
/// the rest of the ride — a four-hour ride is ~15,000 points, and the cost
/// grows with the square of the duration.
///
/// This keeps two lists, joined into [line]:
///
/// * the recent line, at riding resolution (about one vertex per [stepMeters],
///   sooner when the heading turns);
/// * an overview of everything older, thinned to a few hundred vertices once
///   it outgrows [overviewMaxVertices].
///
/// [head] is the latest raw fix, which is usually
/// *not* on [line]: the map draws a two-point segment from [lastVertex] to
/// [head] so the dot stays on the end of the trace without committing a
/// vertex every second.
///
/// [source] may be the same list growing in place. [ingest] only walks points
/// it has not seen yet.
class DisplayTrack {
  DisplayTrack({
    this.stepMeters = 8,
    this.cornerMeters = 4,
    this.cornerDegrees = 28,
    this.detailRetain = 160,
    this.detailCap = 240,
    this.overviewMaxVertices = 520,
    this.overviewTarget = 360,
    this.commitEndpoint = false,
  });

  /// Minimum travel before a new vertex is kept on a straight stretch.
  final double stepMeters;

  /// A turn sharper than [cornerDegrees] is kept once it is at least this
  /// far from the previous vertex, even when that is shorter than [stepMeters].
  final double cornerMeters;
  final double cornerDegrees;

  /// How much of the tail stays at riding resolution after a spill.
  final int detailRetain;

  /// Spill the oldest detail vertices into the overview past this length.
  final int detailCap;

  /// Overview length that triggers a thin.
  final int overviewMaxVertices;

  /// Overview length after a thin.
  final int overviewTarget;

  /// Write the final source point onto [line] even when it falls inside
  /// [stepMeters]. Routes want their destination on the polyline. A live
  /// trace does not: that point moves every fix and belongs on [head].
  final bool commitEndpoint;

  List<GeoPoint> _overview = [];
  List<GeoPoint> _detail = [];
  List<GeoPoint> _line = const [];
  List<GeoPoint>? _source;
  int _index = 0;
  GeoPoint? _lastKept;
  GeoPoint? _previousKept;
  GeoPoint? _head;

  /// Overview plus detail, without [head]. Empty until the first kept point.
  List<GeoPoint> get line => _line;

  /// Latest raw fix. Null when the source is empty.
  GeoPoint? get head => _head;

  /// Last committed vertex, or null when nothing has been kept.
  GeoPoint? get lastVertex => _lastKept;

  /// Reads new points from [source].
  ///
  /// Returns whether [line] changed. [head] may change either way.
  bool ingest(List<GeoPoint> source) {
    final replaced = !identical(source, _source) || source.length < _index;
    if (replaced) {
      _overview = [];
      _detail = [];
      _line = const [];
      _lastKept = null;
      _previousKept = null;
      _head = null;
      _source = source;
      _index = 0;
    }

    var changed = false;
    while (_index < source.length) {
      if (_add(source[_index])) changed = true;
      _index++;
    }
    if (commitEndpoint && source.isNotEmpty && _forceLast(source.last)) {
      changed = true;
    }
    _head = source.isEmpty ? null : source.last;
    if (replaced || changed) {
      _rebuildLine();
      return true;
    }
    return false;
  }

  bool _add(GeoPoint point) {
    if (!point.lat.isFinite || !point.lng.isFinite) return false;
    final last = _lastKept;
    if (last == null) {
      _detail.add(point);
      _lastKept = point;
      return true;
    }
    if (!_keep(last, point)) return false;
    _previousKept = last;
    _detail.add(point);
    _lastKept = point;
    if (_detail.length > detailCap) _spill();
    return true;
  }

  bool _keep(GeoPoint last, GeoPoint point) {
    final distance = haversineMeters(last.lat, last.lng, point.lat, point.lng);
    if (distance >= stepMeters) return true;
    final previous = _previousKept;
    if (previous == null || distance < cornerMeters) return false;
    final incoming = initialBearingDegrees(
      previous.lat,
      previous.lng,
      last.lat,
      last.lng,
    );
    final outgoing = initialBearingDegrees(
      last.lat,
      last.lng,
      point.lat,
      point.lng,
    );
    return bearingDelta(incoming, outgoing) >= cornerDegrees;
  }

  /// The route's destination has to sit on the polyline even when the last
  /// segment is shorter than [stepMeters].
  bool _forceLast(GeoPoint point) {
    if (_lastKept == point) return false;
    if (!point.lat.isFinite || !point.lng.isFinite) return false;
    if (_lastKept == null) {
      _detail.add(point);
      _lastKept = point;
      return true;
    }
    _previousKept = _lastKept;
    _detail.add(point);
    _lastKept = point;
    if (_detail.length > detailCap) _spill();
    return true;
  }

  void _spill() {
    final retain = detailRetain < 1 ? 1 : detailRetain;
    final moveCount = _detail.length - retain;
    if (moveCount <= 0) return;
    _overview.addAll(_detail.getRange(0, moveCount));
    _detail.removeRange(0, moveCount);
    if (_overview.length <= overviewMaxVertices) return;
    _overview = List<GeoPoint>.of(
      simplifyForDisplay(
        _overview,
        maxVertices: overviewTarget,
        minToleranceMeters: stepMeters,
      ),
    );
  }

  void _rebuildLine() {
    if (_overview.isEmpty) {
      _line = List<GeoPoint>.of(_detail);
    } else if (_detail.isEmpty) {
      _line = List<GeoPoint>.of(_overview);
    } else {
      _line = [..._overview, ..._detail];
    }
  }
}
