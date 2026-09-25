import 'dart:io';

import 'package:cycling_app/core/map/tile_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// The arithmetic behind 「已缓存 12.3 MB · 1,204 张」.
///
/// `clear()` is deliberately not tested here: it goes through flutter_map's
/// own provider (destroying its worker and singleton), which needs a platform
/// channel. What is tested is the part that is ours — measuring a directory —
/// and the two states the settings screen branches on.
void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('tile_cache_test'));
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('an empty cache measures zero', () async {
    final size = await TileCache(directory: tempDir).measure();
    expect(size.bytes, 0);
    expect(size.tiles, 0);
  });

  test('a missing directory is not an error', () async {
    final size = await TileCache(
      directory: Directory('${tempDir.path}/not-created'),
    ).measure();
    expect(size.bytes, 0);
  });

  test('tiles are summed, and the size tracker is not a tile', () async {
    File('${tempDir.path}/a.tile').writeAsBytesSync(List.filled(1000, 1));
    File('${tempDir.path}/b.tile').writeAsBytesSync(List.filled(500, 1));
    // The tracker flutter_map keeps alongside the tiles; it occupies space and
    // a clear reclaims it, but it is not a tile.
    File('${tempDir.path}/size.json').writeAsStringSync('{}');

    final size = await TileCache(directory: tempDir).measure();

    expect(size.bytes, 1502);
    expect(size.tiles, 2);
  });
}
