import 'dart:convert';

import 'package:http/http.dart' as http;

/// Public repository that hosts the app source and installable releases.
/// A shipped app queries its releases without embedding a GitHub token.
abstract final class ReleaseSource {
  static const repository = String.fromEnvironment(
    'GITHUB_RELEASE_REPO',
    defaultValue: 'csic21/pure-cycling',
  );
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.pageUrl,
    required this.notes,
    this.androidApkUrl,
  });

  final String version;
  final String tag;
  final Uri pageUrl;
  final String notes;
  final Uri? androidApkUrl;
}

class ReleaseCheckException implements Exception {
  const ReleaseCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitHubReleaseChecker {
  GitHubReleaseChecker({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  void close() => _client.close();

  /// Returns null when the installed version is already current.
  Future<AppRelease?> check({
    required String installedVersion,
    String repository = ReleaseSource.repository,
  }) async {
    if (repository.isEmpty) {
      throw const ReleaseCheckException('尚未配置公开的 GitHub Release 更新源');
    }
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw const ReleaseCheckException('更新源配置不正确');
    }

    final api = Uri.https(
      'api.github.com',
      '/repos/$repository/releases/latest',
    );
    late http.Response response;
    try {
      response = await _client
          .get(
            api,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'pure-cycling-app',
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      throw const ReleaseCheckException('无法连接更新服务，请稍后重试');
    }

    if (response.statusCode == 404) {
      throw const ReleaseCheckException('还没有公开的 GitHub Release');
    }
    if (response.statusCode != 200) {
      throw const ReleaseCheckException('更新服务暂时不可用，请稍后重试');
    }

    try {
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final tag = json['tag_name'] as String;
      final version = _parseVersion(tag);
      final installed = _parseVersion(installedVersion);
      if (version == null || installed == null) {
        throw const ReleaseCheckException('Release 版本号格式不正确');
      }
      if (_compareVersions(version, installed) <= 0) return null;

      final pageUrl = _githubUri(json['html_url']);
      if (pageUrl == null) {
        throw const ReleaseCheckException('Release 下载地址不安全');
      }

      Uri? apkUrl;
      for (final asset in (json['assets'] as List<dynamic>? ?? const [])) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'];
        if (name is! String || !name.toLowerCase().endsWith('.apk')) continue;
        apkUrl = _githubUri(asset['browser_download_url']);
        if (apkUrl != null) break;
      }

      return AppRelease(
        version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
        tag: tag,
        pageUrl: pageUrl,
        androidApkUrl: apkUrl,
        notes: (json['body'] as String? ?? '').trim(),
      );
    } on ReleaseCheckException {
      rethrow;
    } catch (_) {
      throw const ReleaseCheckException('Release 数据格式不正确');
    }
  }

  static List<int>? _parseVersion(String input) {
    final match = RegExp(
      r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$',
    ).firstMatch(input);
    if (match == null) return null;
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  static int _compareVersions(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      final result = a[i].compareTo(b[i]);
      if (result != 0) return result;
    }
    return 0;
  }

  static Uri? _githubUri(dynamic raw) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return null;
    }
    return uri;
  }
}
