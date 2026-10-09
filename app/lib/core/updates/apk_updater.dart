import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ApkUpdateException implements Exception {
  const ApkUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Downloads a release APK into the app's private cache. Redirects must stay
/// on HTTPS, and incomplete/oversized responses never reach the installer.
class ApkUpdater {
  ApkUpdater({http.Client? client}) : _client = client ?? http.Client();

  static const _maximumBytes = 250 * 1024 * 1024;
  static const _channel = MethodChannel('app.purecycling/update');
  static var _serial = 0;
  static bool _downloading = false;
  static final _activePaths = <String>{};
  static String? _installerPath;
  static DateTime? _installerUntil;
  final http.Client _client;
  final _cancelled = Completer<void>();

  void close() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    _client.close();
  }

  void _checkCancelled() {
    if (_cancelled.isCompleted) throw const ApkUpdateCancelled();
  }

  Future<T> _cancellable<T>(Future<T> operation) => Future.any([
    operation,
    _cancelled.future.then<T>((_) => throw const ApkUpdateCancelled()),
  ]);

  Stream<List<int>> _cancelWithClose(Stream<List<int>> source) {
    late StreamSubscription<List<int>> subscription;
    late StreamController<List<int>> body;
    body = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = source.listen(
          (chunk) {
            if (!body.isClosed) body.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            if (!body.isClosed) body.addError(error, stack);
          },
          onDone: body.close,
        );
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () => subscription.cancel(),
    );
    // One cancellation listener per response, not one retained Future.any
    // listener for every network chunk in a potentially large APK.
    unawaited(
      _cancelled.future.then((_) {
        if (!body.isClosed) {
          body.addError(const ApkUpdateCancelled());
          unawaited(body.close());
        }
      }),
    );
    return body.stream;
  }

  Future<File> download(
    Uri url, {
    void Function(int received, int? total)? onProgress,
    Directory? destination,
  }) async {
    _checkCancelled();
    if (_downloading) throw const ApkUpdateException('已有更新正在下载');
    if (_installerUntil?.isAfter(DateTime.now()) ?? false) {
      throw const ApkUpdateException('已打开安装界面，请稍后重试');
    }
    if (url.scheme != 'https') {
      throw const ApkUpdateException('安装包地址不安全');
    }
    // This lock is taken before the first await, including cache cleanup.
    _downloading = true;
    File? part;
    File? apk;
    try {
      final directory = destination ?? await _updatesDirectory();
      await directory.create(recursive: true);
      // This is the explicit replacement boundary. Passive/cold sweeps keep
      // one complete APK because Android may still be using its URI.
      _installerPath = null;
      _installerUntil = null;
      await _sweepPackages(directory, preserveCompleted: false);
      await for (final entity in directory.list()) {
        if (entity is File &&
            _isDownloadedPackage(entity.uri.pathSegments.last)) {
          throw const ApkUpdateException('无法清理旧安装包，请稍后重试');
        }
      }
      _checkCancelled();
      // Each installer URI names immutable bytes. Reusing update.apk makes
      // some Android installers serve a previously parsed package.
      final stamp = '${DateTime.now().microsecondsSinceEpoch}${_serial++}';
      part = File('${directory.path}/update-$stamp.apk.part');
      apk = File('${directory.path}/update-$stamp.apk');
      _activePaths.addAll([part.path, apk.path]);
      var current = url;
      http.StreamedResponse? response;
      for (var redirect = 0; redirect <= 5; redirect++) {
        _checkCancelled();
        final request = http.AbortableRequest(
          'GET',
          current,
          abortTrigger: _cancelled.future,
        )..followRedirects = false;
        response = await _cancellable(
          _client.send(request).then((response) {
            if (_cancelled.isCompleted) {
              unawaited(response.stream.listen((_) {}).cancel());
              throw const ApkUpdateCancelled();
            }
            return response;
          }),
        ).timeout(const Duration(seconds: 20));
        if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) break;
        // Redirect bodies are never buffered or allowed to hold a connection.
        await response.stream.listen((_) {}).cancel();
        final location = response.headers['location'];
        if (location == null || redirect == 5) {
          throw const ApkUpdateException('安装包下载链接无效');
        }
        current = current.resolve(location);
        if (current.scheme != 'https') {
          throw const ApkUpdateException('安装包下载链接不安全');
        }
      }
      if (response == null) {
        throw const ApkUpdateException('安装包下载失败，请稍后重试');
      }
      final total = response.contentLength;
      if (response.statusCode != 200 ||
          (total != null && (total <= 0 || total > _maximumBytes))) {
        await response.stream.listen((_) {}).cancel();
        throw const ApkUpdateException('安装包下载失败或大小异常');
      }
      var received = 0;
      final reader = StreamIterator(_cancelWithClose(response.stream));
      RandomAccessFile? output;
      try {
        output = await part.open(mode: FileMode.write);
        while (await reader.moveNext().timeout(const Duration(seconds: 30))) {
          _checkCancelled();
          final chunk = reader.current;
          received += chunk.length;
          if (received > _maximumBytes) {
            throw const ApkUpdateException('安装包过大');
          }
          // Await each disk write: a fast network cannot queue the entire APK
          // in an IOSink while the filesystem is slow.
          await output.writeFrom(chunk);
          _checkCancelled();
          onProgress?.call(received, total);
        }
        await output.flush();
      } finally {
        try {
          await reader.cancel();
        } finally {
          await output?.close();
        }
      }
      _checkCancelled();
      if (received == 0 || (total != null && received != total)) {
        throw const ApkUpdateException('安装包下载不完整，请重试');
      }
      final header = await part
          .openRead(0, 4)
          .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
      if (header.length < 4 ||
          header[0] != 0x50 ||
          header[1] != 0x4b ||
          header[2] != 0x03 ||
          header[3] != 0x04) {
        throw const ApkUpdateException('下载内容不是有效的安装包');
      }
      _checkCancelled();
      final result = await part.rename(apk.path);
      _checkCancelled();
      return result;
    } on ApkUpdateException {
      close();
      rethrow;
    } catch (_) {
      _checkCancelled();
      // Timeout also aborts the underlying request; its late response must
      // not retain a connection after the operation releases its slot.
      close();
      throw const ApkUpdateException('安装包下载失败，请检查网络后重试');
    } finally {
      try {
        if (part != null && await part.exists()) await part.delete();
        if (_cancelled.isCompleted && apk != null && await apk.exists()) {
          await apk.delete();
        }
      } on FileSystemException {
        // A locked abandoned file is retried by the next cache sweep.
      } finally {
        _activePaths.remove(part?.path);
        _activePaths.remove(apk?.path);
        _downloading = false;
      }
    }
  }

  /// Grace for abandoned partial files during foreground cache sweeps.
  /// Completed packages have ownership-based retention, never a timer expiry.
  static const downloadedPackageGrace = Duration(minutes: 1);

  /// Retains one completed package, including across process restarts.
  ///
  /// Starting Android's installer does not prove it has consumed the URI:
  /// permission screens or a rider's confirmation can take arbitrarily long.
  /// Only a deliberate new download replaces that package. Passive lifecycle
  /// and cold-start sweeps remove extra completed APKs and abandoned parts.
  static Future<void> discardDownloadedPackages({
    Duration? olderThan,
    Directory? directory,
  }) async {
    final Directory dir;
    try {
      dir = directory ?? await _updatesDirectory();
    } catch (_) {
      return;
    }
    await _sweepPackages(dir, preserveCompleted: true, olderThan: olderThan);
  }

  static Future<void> _sweepPackages(
    Directory directory, {
    required bool preserveCompleted,
    Duration? olderThan,
  }) async {
    if (!await directory.exists()) return;
    final packages = await directory
        .list()
        .where(
          (entity) =>
              entity is File &&
              _isDownloadedPackage(entity.uri.pathSegments.last),
        )
        .cast<File>()
        .toList();
    String? retained;
    DateTime? newest;
    if (preserveCompleted) {
      for (final file in packages) {
        if (!file.path.endsWith('.apk')) continue;
        if (file.path == _installerPath) {
          retained = file.path;
          break;
        }
        try {
          final modified = await file.lastModified();
          if (newest == null || modified.isAfter(newest)) {
            newest = modified;
            retained = file.path;
          }
        } on FileSystemException {
          // A concurrent owned download may already have replaced this file.
        }
      }
    }
    final cutoff = olderThan == null
        ? null
        : DateTime.now().subtract(olderThan);
    for (final file in packages) {
      if (file.path == retained || _activePaths.contains(file.path)) continue;
      // The age window applies only to parts. Retaining one completed package
      // already protects installer ownership and bounds legacy cache growth.
      if (cutoff != null && file.path.endsWith('.part')) {
        try {
          if (!(await file.lastModified()).isBefore(cutoff)) continue;
        } on FileSystemException {
          continue;
        }
      }
      // Ownership may have changed during directory/stat awaits.
      if (_activePaths.contains(file.path) ||
          (preserveCompleted && file.path == _installerPath)) {
        continue;
      }
      try {
        await file.delete();
      } on FileSystemException {
        // Passive sweeps retry later. Explicit replacement checks for leftover
        // packages and refuses to create another file if cleanup was blocked.
      }
    }
  }

  static Future<Directory> _updatesDirectory() async =>
      Directory('${(await getTemporaryDirectory()).path}/updates');

  static bool _isDownloadedPackage(String name) =>
      name == 'update.apk' ||
      (name.startsWith('update-') &&
          (name.endsWith('.apk') || name.endsWith('.apk.part')));

  /// Hands a downloaded APK to the system installer.
  ///
  /// [expectedVersion] is the version the check advertised to the rider. The
  /// native side compares it against the APK's own `versionName` before the
  /// installer is opened: the update feed is cached, so a body can outlive the
  /// release it describes, and a stale download has to fail loudly here rather
  /// than quietly put the version that is already on the phone back on it.
  static Future<void> install(
    File apk, {
    required String expectedVersion,
  }) async {
    _installerPath = apk.path;
    _installerUntil = DateTime.now().add(downloadedPackageGrace);
    try {
      await _channel.invokeMethod<void>('install', {
        'path': apk.path,
        'version': expectedVersion,
      });
    } on PlatformException catch (error) {
      _installerPath = null;
      _installerUntil = null;
      throw ApkUpdateException(error.message ?? '无法打开系统安装界面');
    } on MissingPluginException {
      _installerPath = null;
      _installerUntil = null;
      throw const ApkUpdateException('当前设备不支持应用内安装');
    }
    // No cleanup timer: the one completed APK survives confirmation delays,
    // backgrounding and cold starts. An explicit replacement retires it.
  }
}

/// Cancellation is expected and must not surface as a network error.
class ApkUpdateCancelled extends ApkUpdateException {
  const ApkUpdateCancelled() : super('已取消更新下载');
}
