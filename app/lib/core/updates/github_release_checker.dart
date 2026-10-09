import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../sync/functions_config.dart';

/// Repository whose APK was built into this app's release pipeline.
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

/// Reads the latest published release and says whether it is newer than the
/// installed build.
///
/// It asks the project's relay, not GitHub. Asking GitHub from the device does
/// not work: anonymous requests are capped at 60 per hour *per public IP*, and
/// that budget is shared by everything behind the address — which on a Chinese
/// carrier is thousands of riders. See
/// `supabase/functions/release/handler.ts` for the whole story.
///
/// The payload is still GitHub's release JSON, which is what the parsing below
/// is written against; the relay passes it through rather than reshaping it.
class GitHubReleaseChecker {
  GitHubReleaseChecker({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  void close() => _client.close();

  /// Returns null when the installed version is already current.
  ///
  /// [relayUrl] defaults to the configured relay. It is a parameter so tests
  /// can point at a stub.
  Future<AppRelease?> check({
    required String installedVersion,
    String? relayUrl,
  }) async {
    final endpoint = (relayUrl ?? FunctionsConfig.releaseUrl)?.trim() ?? '';
    if (endpoint.isEmpty) {
      throw const ReleaseCheckException('这个版本没有配置更新服务，无法检查更新');
    }
    final api = Uri.tryParse(endpoint);
    if (api == null || api.scheme != 'https' || api.host.isEmpty) {
      throw const ReleaseCheckException('更新服务地址不安全');
    }

    late http.Response response;
    try {
      final request = http.Request('GET', api)
        ..headers['Accept'] = 'application/json';
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 10));
      const maximumBytes = 1024 * 1024;
      if ((streamed.contentLength ?? 0) > maximumBytes) {
        await streamed.stream.listen((_) {}).cancel();
        throw const ReleaseCheckException('更新服务响应过大');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(
        const Duration(seconds: 10),
      )) {
        if (bytes.length + chunk.length > maximumBytes) {
          throw const ReleaseCheckException('更新服务响应过大');
        }
        bytes.add(chunk);
      }
      response = http.Response.bytes(
        bytes.takeBytes(),
        streamed.statusCode,
        headers: streamed.headers,
      );
    } on ReleaseCheckException {
      rethrow;
    } catch (_) {
      throw const ReleaseCheckException('无法连接更新服务，请稍后重试');
    }

    if (response.statusCode == 404) {
      // The Supabase gateway also returns 404 when the function has not been
      // deployed. Only the relay's own structured 404 means no Release yet.
      try {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (response.headers['x-release-repository']?.toLowerCase() ==
                ReleaseSource.repository.toLowerCase() &&
            body is Map<String, dynamic> &&
            body['code'] == 'release_missing') {
          throw const ReleaseCheckException('还没有公开的 GitHub Release');
        }
      } on ReleaseCheckException {
        rethrow;
      } catch (_) {
        // An HTML or malformed gateway error is still a service failure.
      }
      throw const ReleaseCheckException('更新服务尚未就绪，请稍后重试');
    }
    if (response.statusCode != 200) {
      throw const ReleaseCheckException('更新服务暂时不可用，请稍后重试');
    }
    if (response.headers['x-release-repository']?.toLowerCase() !=
        ReleaseSource.repository.toLowerCase()) {
      throw const ReleaseCheckException('更新服务与安装包来源不一致');
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

      final pageUrl = _githubUri(json['html_url'], 'tag');
      if (pageUrl == null) {
        throw const ReleaseCheckException('Release 下载地址不安全');
      }

      Uri? apkUrl;
      for (final asset in (json['assets'] as List<dynamic>? ?? const [])) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'];
        if (name is! String || !name.toLowerCase().endsWith('.apk')) continue;
        apkUrl = _githubUri(asset['browser_download_url'], 'download');
        if (apkUrl != null) break;
      }

      return AppRelease(
        version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
        tag: tag,
        pageUrl: pageUrl,
        androidApkUrl: apkUrl,
        notes: _displayNotes(json['body'] as String? ?? '', tag),
      );
    } on ReleaseCheckException {
      rethrow;
    } catch (_) {
      throw const ReleaseCheckException('Release 数据格式不正确');
    }
  }

  /// GitHub hides the release pipeline's provenance comment, but a Flutter
  /// Text widget does not interpret HTML. Remove only our matching metadata,
  /// with a small size bound and an explicit shape check; ordinary comments,
  /// malformed metadata, and the rider-facing notes remain untouched.
  static String _displayNotes(String body, String tag) {
    final comment = RegExp(
      r'<!-- pure-cycling-release: (\{[^\r\n]{0,4096}?\}) -->',
    );
    final digest = RegExp(r'^[0-9a-f]{64}$');
    final source = RegExp(r'^[0-9a-f]{40}$');
    return body.replaceAllMapped(comment, (match) {
      try {
        final metadata = jsonDecode(match.group(1)!);
        if (metadata is Map<String, dynamic> &&
            metadata['tag'] == tag &&
            metadata['source_sha'] is String &&
            source.hasMatch(metadata['source_sha'] as String) &&
            metadata['signer_sha256'] is String &&
            digest.hasMatch(metadata['signer_sha256'] as String) &&
            metadata['apk_sha256'] is String &&
            digest.hasMatch(metadata['apk_sha256'] as String)) {
          return '';
        }
      } catch (_) {
        // An unknown or malformed comment is still release text, not trusted
        // metadata. Avoid stripping unrelated rider-facing content.
      }
      return match.group(0)!;
    }).trim();
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

  static Uri? _githubUri(dynamic raw, String kind) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return null;
    }
    final expected =
        '/${ReleaseSource.repository.toLowerCase()}/releases/$kind/';
    if (!uri.path.toLowerCase().startsWith(expected)) return null;
    return uri;
  }
}
