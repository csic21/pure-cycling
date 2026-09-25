import 'dart:io';

import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';

/// The tile cache flutter_map keeps on disk.
///
/// `NetworkTileProvider` caches every tile it fetches — `<app cache>/fm_cache`,
/// up to a gigabyte — which means a road the rider has already looked at keeps
/// working in a tunnel. That is worth having and worth *saying*, because the
/// same cache is also a record of where they have been looking. So it is
/// visible and clearable from the settings screen rather than being an
/// invisible side effect of opening the map.
///
/// This is not "offline maps" in the V2 sense: there is no region to download
/// ahead of time, and an area never viewed is still blank. Downloading regions
/// needs a tile source whose terms allow bulk fetching, which is the open
/// question in `docs/map.md` — the cache below is the part that needs no
/// permission at all.
class TileCache {
  const TileCache({Directory? directory}) : _override = directory;

  /// Injected by tests, which have no `path_provider` plugin.
  final Directory? _override;

  /// Where flutter_map puts it. Verified against the platform implementation
  /// rather than guessed: the default is `getApplicationCacheDirectory()` with
  /// an `fm_cache` child.
  Future<Directory?> _directory() async {
    final override = _override;
    if (override != null) return override;

    try {
      final base = await getApplicationCacheDirectory();
      return Directory('${base.path}/fm_cache');
    } catch (_) {
      // No plugin (a test), or a platform that will not answer.
      return null;
    }
  }

  Future<({int bytes, int tiles})> measure() async {
    final dir = await _directory();
    if (dir == null || !await dir.exists()) return (bytes: 0, tiles: 0);

    var bytes = 0;
    var tiles = 0;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        // The size tracker lives alongside the tiles; counting it keeps the
        // number honest about what a clear will reclaim.
        final stat = await entity.stat();
        bytes += stat.size;
        if (!entity.path.endsWith('.json')) tiles++;
      }
    } catch (_) {
      // A cache being pruned underneath us is not an error worth reporting.
    }
    return (bytes: bytes, tiles: tiles);
  }

  /// Deletes every cached tile.
  ///
  /// Through flutter_map's own API rather than by deleting files behind its
  /// back: the provider's write worker holds the directory and a size tracker,
  /// and a cache whose files vanish underneath it stops accepting new tiles
  /// until its instance is recreated. `destroy(deleteCache: true)` terminates
  /// the worker, clears the singleton and removes exactly the `fm_cache`
  /// directory — the next tile load starts a fresh one.
  ///
  /// Nothing else in the app stores state in the platform cache directory:
  /// exports go to documents and the diagnostic log to application support,
  /// precisely because a cache may be cleared by the OS at any time.
  Future<void> clear() async {
    try {
      await BuiltInMapCachingProvider.getOrCreateInstance()
          .destroy(deleteCache: true);
    } catch (_) {
      // Already gone, or no cache to speak of.
    }
  }
}
