import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../../features/ride/domain/ride.dart';
import '../../features/ride/domain/track_point.dart';
import '../../features/routes/domain/route.dart';
import '../utils/geo.dart';

/// GPX 1.1, with the Garmin TrackPointExtension for heart rate and cadence.
///
/// Written by hand rather than through a DOM builder: a four-hour ride is
/// ~15,000 points and the export runs while the rider is standing next to the
/// bike waiting for their phone. String concatenation here is roughly an order
/// of magnitude faster than building ninety thousand XML nodes, and the only
/// values that need escaping are the rider-chosen name and notes.
abstract final class GpxCodec {
  static const String _namespace = 'http://www.topografix.com/GPX/1/1';
  static const String _tpExtensionNs =
      'http://www.garmin.com/xmlschemas/TrackPointExtension/v1';
  static const String creator = 'PureCycling';

  /// Serializes a ride and its trace to GPX 1.1.
  static String encode(Ride ride, List<TrackPoint> points) {
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="$creator"')
      ..writeln('  xmlns="$_namespace"')
      ..writeln('  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
      ..writeln('  xmlns:gpxtpx="$_tpExtensionNs"')
      ..writeln('  xsi:schemaLocation="$_namespace '
          'http://www.topografix.com/GPX/1/1/gpx.xsd">');

    final name = ride.displayName(_defaultName(ride.startedAt));

    buffer
      ..writeln('  <metadata>')
      ..writeln('    <name>${_escape(name)}</name>')
      ..writeln('    <time>${_iso(ride.startedAt)}</time>')
      ..writeln('  </metadata>');

    buffer
      ..writeln('  <trk>')
      ..writeln('    <name>${_escape(name)}</name>')
      ..writeln('    <type>cycling</type>')
      ..writeln('    <trkseg>');

    for (final p in points) {
      buffer
        ..write('      <trkpt lat="')
        ..write(p.lat.toStringAsFixed(7))
        ..write('" lon="')
        ..write(p.lng.toStringAsFixed(7))
        ..writeln('">');

      final ele = p.altitude;
      if (ele != null && ele.isFinite) {
        buffer.writeln('        <ele>${ele.toStringAsFixed(2)}</ele>');
      }
      buffer.writeln('        <time>${_iso(p.timestamp)}</time>');

      // Written back so a re-import round-trips: some tools (and our own
      // decoder) use the recorded speed rather than re-deriving it.
      final speed = p.speed;
      if (speed != null && speed.isFinite && speed >= 0) {
        buffer.writeln('        <speed>${speed.toStringAsFixed(3)}</speed>');
      }

      if (p.heartRate != null || p.cadence != null) {
        buffer.writeln('        <extensions>');
        buffer.writeln('          <gpxtpx:TrackPointExtension>');
        if (p.heartRate != null) {
          buffer.writeln('            <gpxtpx:hr>${p.heartRate}</gpxtpx:hr>');
        }
        if (p.cadence != null) {
          buffer.writeln('            <gpxtpx:cad>${p.cadence}</gpxtpx:cad>');
        }
        buffer
          ..writeln('          </gpxtpx:TrackPointExtension>')
          ..writeln('        </extensions>');
      }

      buffer.writeln('      </trkpt>');
    }

    buffer
      ..writeln('    </trkseg>')
      ..writeln('  </trk>');

    if (ride.stats.elevationGainMeters > 0 ||
        ride.stats.distanceMeters > 0) {
      // Not part of GPX 1.1, but a widely-read convention and useful when the
      // file is opened by a tool that shows a summary before parsing points.
      buffer
        ..writeln('  <extensions>')
        ..writeln('    <purecycling:summary '
            'xmlns:purecycling="https://purecycling.app/gpx/1"')
        ..writeln('      distance_m="${ride.stats.distanceMeters.toStringAsFixed(1)}"')
        ..writeln('      elapsed_s="${ride.stats.elapsed.inSeconds}"')
        ..writeln('      moving_s="${ride.stats.moving.inSeconds}"')
        ..writeln('      elevation_gain_m="${ride.stats.elevationGainMeters.toStringAsFixed(1)}"')
        ..writeln('      avg_speed_mps="${ride.stats.avgSpeedMps.toStringAsFixed(3)}"')
        ..writeln('      max_speed_mps="${ride.stats.maxSpeedMps.toStringAsFixed(3)}"/>')
        ..writeln('  </extensions>');
    }

    buffer.writeln('</gpx>');
    return buffer.toString();
  }

  /// Parses a GPX file into route geometry.
  ///
  /// Accepts both `<trkpt>` (recorded tracks) and `<rtept>` (planned routes),
  /// because riders import both: a friend's ride and a route someone built in
  /// another tool.
  static ParsedGpx decode(String xmlSource) {
    final document = XmlDocument.parse(xmlSource);

    final name = _firstText(document, 'name');

    final points = <ParsedGpxPoint>[];

    // Tracks first — a file with both is almost always a recorded ride with a
    // stray route in it, and the track is what the rider means.
    for (final trkseg in document.findAllElements('trkseg')) {
      for (final trkpt in trkseg.findElements('trkpt')) {
        final point = _parsePoint(trkpt);
        if (point != null) points.add(point);
      }
    }

    if (points.isEmpty) {
      for (final rtept in document.findAllElements('rtept')) {
        final point = _parsePoint(rtept);
        if (point != null) points.add(point);
      }
    }

    return ParsedGpx(name: name, points: points);
  }

  static ParsedGpxPoint? _parsePoint(XmlElement element) {
    final lat = double.tryParse(element.getAttribute('lat') ?? '');
    final lon = double.tryParse(element.getAttribute('lon') ?? '');
    if (lat == null || lon == null) return null;
    if (lat.isNaN || lon.isNaN || lat.abs() > 90 || lon.abs() > 180) return null;

    double? ele;
    final eleText = _firstText(element, 'ele');
    if (eleText != null) ele = double.tryParse(eleText);

    DateTime? time;
    final timeText = _firstText(element, 'time');
    if (timeText != null) time = DateTime.tryParse(timeText)?.toUtc();

    double? speed;
    final speedText = _firstText(element, 'speed');
    if (speedText != null) speed = double.tryParse(speedText);

    return ParsedGpxPoint(
      point: GeoPoint(lat, lon),
      elevation: ele,
      time: time,
      speed: speed,
    );
  }

  /// First descendant element with the given local name, ignoring namespace
  /// prefixes — GPX files in the wild use several.
  static String? _firstText(XmlNode parent, String localName) {
    for (final e in parent.descendantElements) {
      if (e.name.local == localName) return e.innerText.trim();
    }
    return null;
  }

  /// Builds a `Route` from a parsed GPX file, computing distance and climb.
  ///
  /// Climb uses the same thresholded accumulation as the ride engine, so an
  /// imported route's elevation profile is comparable to a recorded ride's.
  static Route toRoute(ParsedGpx parsed, {required String id, String? name}) {
    final geoPoints = parsed.points.map((p) => p.point).toList(growable: false);

    return Route(
      id: id,
      name: name ?? parsed.name ?? '导入的路线',
      points: geoPoints,
      distanceMeters: polylineLengthMeters(geoPoints),
      elevationGainMeters: _elevationGain(parsed.points),
      provider: 'gpx',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  static double _elevationGain(List<ParsedGpxPoint> points) {
    const threshold = 2.0;
    double? reference;
    var gain = 0.0;
    for (final p in points) {
      final ele = p.elevation;
      if (ele == null || !ele.isFinite) continue;
      if (reference == null) {
        reference = ele;
        continue;
      }
      final delta = ele - reference;
      if (delta >= threshold) {
        gain += delta;
        reference = ele;
      } else if (delta <= -threshold) {
        reference = ele;
      }
    }
    return gain;
  }

  static String _iso(DateTime t) =>
      '${t.toUtc().toIso8601String().split('.').first}Z';

  static String _defaultName(DateTime startedAt) {
    final local = startedAt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} $hh:$mm 骑行';
  }

  /// Minimal XML text escaping. Values only reach here from user text, so the
  /// set is small but must include the quote for attribute safety.
  static String _escape(String value) {
    final out = StringBuffer();
    for (final rune in value.runes) {
      switch (rune) {
        case 0x26:
          out.write('&amp;');
        case 0x3C:
          out.write('&lt;');
        case 0x3E:
          out.write('&gt;');
        case 0x22:
          out.write('&quot;');
        case 0x27:
          out.write('&apos;');
        default:
          if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) {
            // Control characters are not legal in XML 1.0 at all.
            continue;
          }
          out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// Great-circle length of a parsed point list, exposed for the import
  /// preview.
  static double lengthMeters(List<ParsedGpxPoint> points) =>
      polylineLengthMeters(points.map((p) => p.point).toList(growable: false));

  /// Samples a route's elevation for the profile chart, capped at [buckets]
  /// points so a 40,000-point import does not become a 40,000-segment path.
  static List<double> elevationProfile(
    List<ParsedGpxPoint> points, {
    int buckets = 120,
  }) {
    final withElevation = points
        .where((p) => p.elevation != null && p.elevation!.isFinite)
        .toList(growable: false);
    if (withElevation.length < 2) return const [];

    if (withElevation.length <= buckets) {
      return withElevation.map((p) => p.elevation!).toList(growable: false);
    }

    // Average within each bucket rather than picking one sample: a single
    // point per bucket would alias a steep ramp into a flat line.
    final out = <double>[];
    final step = withElevation.length / buckets;
    for (var i = 0; i < buckets; i++) {
      final start = (i * step).floor();
      final end = math.min(((i + 1) * step).ceil(), withElevation.length);
      if (end <= start) continue;
      var sum = 0.0;
      for (var j = start; j < end; j++) {
        sum += withElevation[j].elevation!;
      }
      out.add(sum / (end - start));
    }
    return out;
  }
}

/// One point from a parsed GPX file.
class ParsedGpxPoint {
  const ParsedGpxPoint({
    required this.point,
    this.elevation,
    this.time,
    this.speed,
  });

  final GeoPoint point;
  final double? elevation;
  final DateTime? time;
  final double? speed;
}

/// The result of parsing a GPX file.
class ParsedGpx {
  const ParsedGpx({this.name, required this.points});

  final String? name;
  final List<ParsedGpxPoint> points;

  bool get isEmpty => points.length < 2;
}
