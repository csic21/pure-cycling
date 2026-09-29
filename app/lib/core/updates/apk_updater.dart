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

    final directory =
        destination ??
        Directory('${(await getTemporaryDirectory()).path}/updates');
    await directory.create(recursive: true);
    final part = File('${directory.path}/update.apk.part');
    final apk = File('${directory.path}/update.apk');
    if (await part.exists()) await part.delete();

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
  }
}
