import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cycling_app/core/gpx/gpx_codec.dart';
import 'package:flutter_test/flutter_test.dart';

String points(int count) => '<gpx><trk><trkseg>${List.filled(count, '<trkpt lat="31" lon="121"/>').join()}</trkseg></trk></gpx>';

void main() {
  test('point budget counts invalid and fallback points too', () {
    expect(GpxCodec.decode(points(GpxCodec.maxPoints)).points, hasLength(GpxCodec.maxPoints));
    expect(() => GpxCodec.decode(points(GpxCodec.maxPoints + 1)), throwsFormatException);
    final invalid = points(GpxCodec.maxPoints + 1).replaceAll('lat="31"', 'lat="999"');
    expect(() => GpxCodec.decode(invalid), throwsFormatException);
  });

  test('rejects DTD, external entity, deep nesting and oversized metadata', () {
    for (final xml in [
      '<!DOCTYPE gpx [<!ENTITY x SYSTEM "file:///synthetic-secret">]><gpx>&x;</gpx>',
      '<gpx>${List.filled(GpxCodec.maxDepth, '<x>').join()}${List.filled(GpxCodec.maxDepth, '</x>').join()}</gpx>',
      '<gpx><name>${'x' * (GpxCodec.maxTextLength + 1)}</name></gpx>',
      '<gpx><trkpt lat="31" lon="121"><trkpt lat="31" lon="121"/></trkpt></gpx>',
    ]) {
      expect(() => GpxCodec.decode(xml), throwsFormatException);
    }
  });

  test('bounded stream rejects dishonest size and cancels consumption', () async {
    var consumed = 0;
    var closed = false;
    Stream<List<int>> source() async* {
      try {
        for (var i = 0; i < 100; i++) {
          consumed++;
          yield Uint8List(1024 * 1024);
        }
      } finally { closed = true; }
    }
    await expectLater(GpxCodec.readBytesBounded(source(), knownLength: 1), throwsFormatException);
    expect(consumed, 17);
    expect(closed, isTrue);
    consumed = 0;
    await expectLater(GpxCodec.readBytesBounded(source(), knownLength: GpxCodec.maxBytes + 1), throwsFormatException);
    expect(consumed, 0);
  });

  test('UTF-8 byte limit covers multibyte clipboard text', () async {
    final source = '<gpx><!--${'骑' * (GpxCodec.maxBytes ~/ 3 + 1)}--></gpx>';
    await expectLater(GpxCodec.decodeAsync(source), throwsFormatException);
  });

  test('large parse runs off the caller isolate and matches bytes/text paths', () async {
    final xml = points(10000);
    var ticks = 0;
    final timer = Timer.periodic(Duration.zero, (_) => ticks++);
    final parsed = await GpxCodec.decodeAsync(xml);
    timer.cancel();
    expect(ticks, greaterThan(0), reason: 'the caller event loop can run during parsing');
    final fromBytes = await GpxCodec.decodeBytesAsync(Uint8List.fromList(utf8.encode(xml)));
    expect(parsed.points.length, 10000);
    expect(fromBytes.points.length, parsed.points.length);
  });

  test('namespaced GPX and CDATA metadata retain track preference', () {
    final parsed = GpxCodec.decode('<g:gpx xmlns:g="urn:test"><g:name><![CDATA[A & B]]></g:name>'
      '<g:rte><g:rtept lat="1" lon="2"/></g:rte><g:trk><g:trkseg>'
      '<g:trkpt lat="31" lon="121"><g:ele>12</g:ele></g:trkpt>'
      '<g:trkpt lat="32" lon="122"/></g:trkseg></g:trk></g:gpx>');
    expect(parsed.name, 'A & B');
    expect(parsed.points.length, 2);
    expect(parsed.points.first.point.lat, 31);
    expect(parsed.points.first.elevation, 12);
  });
}
