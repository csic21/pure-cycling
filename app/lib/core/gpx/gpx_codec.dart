import 'dart:math' as math;
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:xml/xml_events.dart';

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
  /// Shared resource budget for files, clipboard text and cloud hydration.
  static const maxBytes = 16 * 1024 * 1024;
  static const maxPoints = 100000;
  static const maxDepth = 32;
  static const maxTextLength = 16384;

  static Future<Uint8List> readBytesBounded(Stream<List<int>> source,
      {int? knownLength}) async {
    if (knownLength != null && knownLength > maxBytes) {
      throw const FormatException('GPX 文件不能超过 16 MiB');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in source) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('GPX 文件不能超过 16 MiB');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Future<ParsedGpx> decodeAsync(String source) async {
    if (source.length > maxBytes) throw const FormatException('GPX 文件不能超过 16 MiB');
    return Isolate.run(() => decode(source));
  }

  static Future<String> decodeUtf8Async(Uint8List bytes) async {
    if (bytes.length > maxBytes) throw const FormatException('GPX 文件不能超过 16 MiB');
    return Isolate.run(() => utf8.decode(bytes));
  }

  static Future<Route> toRouteAsync(ParsedGpx parsed, {required String id, String? name}) =>
      Isolate.run(() => toRoute(parsed, id: id, name: name));

  static Future<ParsedGpx> decodeBytesAsync(Uint8List bytes) async {
    if (bytes.length > maxBytes) throw const FormatException('GPX 文件不能超过 16 MiB');
    return Isolate.run(() => decode(utf8.decode(bytes)));
  }

  /// Pull parsing avoids a second full XML DOM in memory. Only the bounded
  /// point models and small metadata fields survive; no DTD or custom entity
  /// declarations are accepted, and the parser never resolves network URLs.
  static ParsedGpx decode(String xmlSource) {
    if (xmlSource.length > maxBytes) throw const FormatException('GPX 文件不能超过 16 MiB');
    var byteCount = 0;
    for (final rune in xmlSource.runes) {
      byteCount += rune <= 0x7f ? 1 : rune <= 0x7ff ? 2 : rune <= 0xffff ? 3 : 4;
      if (byteCount > maxBytes) throw const FormatException('GPX 文件不能超过 16 MiB');
    }
    if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(xmlSource)) {
      throw const FormatException('GPX 不支持 DTD 或自定义实体');
    }
    final stack = <String>[];
    final tracks = <ParsedGpxPoint>[];
    final routes = <ParsedGpxPoint>[];
    _GpxPointBuilder? point;
    String? name;
    StringBuffer? nameText;
    int? nameDepth;
    var pointsSeen = 0;
    var eventsSeen = 0;
    var sawRoot = false;

    void endElement() {
      if (nameDepth == stack.length) {
        name = nameText.toString().trim();
        nameText = null;
        nameDepth = null;
      }
      final active = point;
      if (active != null) {
        active.endField(stack.length);
        if (active.depth == stack.length) {
          final parsed = active.build();
          if (parsed != null) (active.track ? tracks : routes).add(parsed);
          point = null;
        }
      }
      stack.removeLast();
    }

    for (final event in parseEvents(xmlSource, validateNesting: true,
        validateDocument: true)) {
      if (++eventsSeen > 2000000) throw const FormatException('GPX 结构过于复杂');
      if (event is XmlDoctypeEvent) throw const FormatException('GPX 不支持 DTD');
      if (event is XmlStartElementEvent) {
        final local = event.localName;
        if (!sawRoot) {
          if (local != 'gpx') throw const FormatException('不是 GPX 文档');
          sawRoot = true;
        }
        stack.add(local);
        if (stack.length > maxDepth || event.attributes.length > 32 ||
            event.name.length > 256 || event.attributes.any((a) =>
              a.name.length > 256 || a.value.length > maxTextLength)) {
          throw const FormatException('GPX 嵌套或属性超过安全限制');
        }
        if (local == 'name' && name == null && nameText == null) {
          nameDepth = stack.length;
          nameText = StringBuffer();
        }
        if (local == 'trkpt' || local == 'rtept') {
          if (++pointsSeen > maxPoints) throw const FormatException('GPX 最多支持 100000 个轨迹点');
          if (stack.take(stack.length - 1).any((name) => name == 'trkpt' || name == 'rtept')) {
            throw const FormatException('GPX 轨迹点不能互相嵌套');
          }
          if (local == 'rtept' || stack.contains('trkseg')) {
            final attributes = {for (final a in event.attributes) a.localName: a.value};
            point = _GpxPointBuilder(stack.length, local == 'trkpt', attributes);
          }
        } else {
          point?.startField(local, stack.length);
        }
        if (event.isSelfClosing) endElement();
      } else if (event is XmlEndElementEvent) {
        endElement();
      } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
        final text = event is XmlTextEvent ? event.value : (event as XmlCDATAEvent).value;
        if (text.length > maxTextLength) throw const FormatException('GPX 文本字段过长');
        nameText?.write(text);
        if ((nameText?.length ?? 0) > maxTextLength) throw const FormatException('GPX 名称过长');
        point?.addText(text);
      }
    }
    if (!sawRoot) throw const FormatException('不是 GPX 文档');
    return ParsedGpx(name: name, points: tracks.isNotEmpty ? tracks : routes);
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

class _GpxPointBuilder {
  _GpxPointBuilder(this.depth, this.track, Map<String, String> attributes)
      : lat = double.tryParse(attributes['lat'] ?? ''),
        lng = double.tryParse(attributes['lon'] ?? '');
  final int depth;
  final bool track;
  final double? lat;
  final double? lng;
  final fields = <String, String>{};
  String? field;
  int? fieldDepth;
  StringBuffer? text;
  void startField(String local, int atDepth) {
    if (field == null && !fields.containsKey(local) &&
        const ['ele', 'time', 'speed'].contains(local)) {
      field = local; fieldDepth = atDepth; text = StringBuffer();
    }
  }
  void addText(String value) {
    text?.write(value);
    if ((text?.length ?? 0) > GpxCodec.maxTextLength) {
      throw const FormatException('GPX 文本字段过长');
    }
  }
  void endField(int atDepth) {
    if (field != null && fieldDepth == atDepth) {
      fields[field!] = text.toString().trim();
      field = null; fieldDepth = null; text = null;
    }
  }
  ParsedGpxPoint? build() {
    if (lat == null || lng == null || !lat!.isFinite || !lng!.isFinite ||
        lat!.abs() > 90 || lng!.abs() > 180) return null;
    double? finite(String key) {
      final value = double.tryParse(fields[key] ?? '');
      return value != null && value.isFinite ? value : null;
    }
    return ParsedGpxPoint(point: GeoPoint(lat!, lng!), elevation: finite('ele'),
      time: DateTime.tryParse(fields['time'] ?? '')?.toUtc(), speed: finite('speed'));
  }
}
