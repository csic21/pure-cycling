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
  final http.Client _client;

  void close() => _client.close();

  Future<File> download(
    Uri url, {
    void Function(int received, int? total)? onProgress,
    Directory? destination,
  }) async {
    if (url.scheme != 'https') {
      throw const ApkUpdateException('安装包地址不安全');
    }

    final directory = destination ?? await _updatesDirectory();
    await directory.create(recursive: true);
    // A new name every time. The system installer caches an APK by its
    // content URI, and that URI is the path. Writing the next release over
    // `update.apk` makes the installer open the package it already parsed —
    // the one the rider installed last time — while this process, reading
    // the file directly, sees the new bytes and lets the dialog through.
    //
    // The previous files go first, so a new download cannot stack on top of
    // one the installer was still holding open.
    await discardDownloadedPackages(directory: directory);
    final stamp = '${DateTime.now().microsecondsSinceEpoch}${_serial++}';
    final part = File('${directory.path}/update-$stamp.apk.part');
    final apk = File('${directory.path}/update-$stamp.apk');

    try {
      var current = url;
      http.StreamedResponse? response;
      for (var redirect = 0; redirect <= 5; redirect++) {
        final request = http.Request('GET', current)..followRedirects = false;
        response = await _client
            .send(request)
            .timeout(const Duration(seconds: 20));
        if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) break;
        final location = response.headers['location'];
        if (location == null || redirect == 5) {
          throw const ApkUpdateException('安装包下载链接无效');
        }
        current = current.resolve(location);
        if (current.scheme != 'https') {
          throw const ApkUpdateException('安装包下载链接不安全');
        }
      }
      if (response == null || response.statusCode != 200) {
        throw const ApkUpdateException('安装包下载失败，请稍后重试');
      }

      final total = response.contentLength;
      if (total != null && (total <= 0 || total > _maximumBytes)) {
        throw const ApkUpdateException('安装包大小异常');
      }
      var received = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > _maximumBytes) {
            throw const ApkUpdateException('安装包过大');
          }
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
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
      if (await apk.exists()) await apk.delete();
      return await part.rename(apk.path);
    } on ApkUpdateException {
      rethrow;
    } catch (_) {
      throw const ApkUpdateException('安装包下载失败，请检查网络后重试');
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  /// How long a package handed to the installer is left on disk.
  ///
  /// Long enough for the installer to open it. After that the file is only
  /// taking space: each download has its own name, so keeping every one would
  /// grow the cache by the size of the APK on every update.
  static const downloadedPackageGrace = Duration(minutes: 1);

  /// Deletes downloaded APKs and half-written parts.
  ///
  /// [olderThan] keeps a file still inside that window. The installer is
  /// reading the one just handed over; a lifecycle flicker must not unlink it
  /// out from under that screen. Null deletes everything, which is what a new
  /// download and a cold start want. A file the installer still has open is
  /// skipped and tried again next time.
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
    if (!await dir.exists()) return;
    final cutoff = olderThan == null
        ? null
        : DateTime.now().subtract(olderThan);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!_isDownloadedPackage(name)) continue;
      if (cutoff != null) {
        try {
          if (!((await entity.lastModified()).isBefore(cutoff))) continue;
        } on FileSystemException {
          continue;
        }
      }
      try {
        await entity.delete();
      } on FileSystemException {
        // Unlink failed. The next resume or the next download tries again,
        // which is what stops a locked file from becoming a permanent copy.
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
    try {
      await _channel.invokeMethod<void>('install', {
        'path': apk.path,
        'version': expectedVersion,
      });
    } on PlatformException catch (error) {
      throw ApkUpdateException(error.message ?? '无法打开系统安装界面');
    } on MissingPluginException {
      throw const ApkUpdateException('当前设备不支持应用内安装');
    }
    // The installer has the file now. Drop it once that screen has had time
    // to open it. The grace window also covers a download the rider starts
    // in that same minute: only files already older than the window go, so
    // the new one is not unlinked mid-write. Coming back to the app sweeps
    // anything this timer missed.
    unawaited(
      Future<void>.delayed(
        downloadedPackageGrace,
        () => discardDownloadedPackages(olderThan: downloadedPackageGrace),
      ),
    );
  }
}
