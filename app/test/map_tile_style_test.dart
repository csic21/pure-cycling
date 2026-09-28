import 'package:cycling_app/core/map/map_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which tile source gets dimmed in software.
///
/// This rule decides whether the map has any colour at all. It used to live
/// inside the map widget as "dim everything that has no dark style", which
/// ignored the rider's setting, dimmed AMap unconditionally, and did it with
/// an equal-weight matrix — plain desaturation. The result was a monochrome
/// map that no test could see, because nothing outside the widget could ask
/// the question. It is answered on the tile source now.
void main() {
  test('dims a light-only source when the rider asked for dark', () {
    final amap = MapTileSource.amapVector.forDarkPreference(true);
    expect(amap.dimTiles, isTrue);
    expect(amap.darkAvailable, isFalse);
  });

  test('leaves the same source alone when the rider asked for light', () {
    expect(MapTileSource.amapVector.forDarkPreference(false).dimTiles, isFalse);
  });

  test('never dims a source that has a dark style of its own', () {
    // Carto's dark basemap needs no help, and filtering an image that was
    // already designed for a dark screen is a second, worse conversion.
    expect(MapTileSource.cartoDark.forDarkPreference(true).dimTiles, isFalse);
    expect(MapTileSource.cartoDark.forDarkPreference(false).dimTiles, isFalse);
  });

  test('dims a light source that is not AMap too', () {
    expect(MapTileSource.osm.forDarkPreference(true).dimTiles, isTrue);
    expect(MapTileSource.osm.forDarkPreference(false).dimTiles, isFalse);
  });

  test('changing the style changes nothing but the dimming', () {
    // Datum above all: a dimmed AMap is still GCJ-02, so a route planned
    // through AMap still lands on the right street. Attribution is a
    // licensing term rather than a visual one and must survive the copy too.
    const plain = MapTileSource.amapVector;
    final dimmed = plain.forDarkPreference(true);

    expect(dimmed.id, plain.id);
    expect(dimmed.name, plain.name);
    expect(dimmed.urlTemplate, plain.urlTemplate);
    expect(dimmed.datum, MapDatum.gcj02);
    expect(dimmed.subdomains, plain.subdomains);
    expect(dimmed.minZoom, plain.minZoom);
    expect(dimmed.maxZoom, plain.maxZoom);
    expect(dimmed.attribution, plain.attribution);
  });

  test('a dimmed source still answers to its own id', () {
    // The settings screen reports the provider actually in use by looking it
    // up by id. A copy that lost its id would quietly name a different one.
    final dimmed = MapTileSource.amapVector.forDarkPreference(true);
    expect(MapTileSource.byId(dimmed.id), same(MapTileSource.amapVector));
  });
}
