import 'dart:convert';

import 'package:cycling_app/core/updates/github_release_checker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const repository = 'csic21/pure-cycling';
  Map<String, Object?> release({
    String tag = 'v0.2.0',
    String url = 'https://github.com/csic21/pure-cycling/releases/tag/v0.2.0',
  }) => {
    'tag_name': tag,
    'html_url': url,
    'body': '修复路线规划',
    'assets': [
      {
        'name': 'pure-cycling-android.apk',
        'browser_download_url':
            'https://github.com/csic21/pure-cycling/releases/download/v0.2.0/pure-cycling-android.apk',
      },
    ],
  };

  test('offers a newer GitHub Release and its APK', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient((request) async {
        expect(request.url.path, '/repos/csic21/pure-cycling/releases/latest');
        return http.Response.bytes(utf8.encode(jsonEncode(release())), 200);
      }),
    );
    addTearDown(checker.close);

    final update = await checker.check(
      installedVersion: '0.1.0',
      repository: repository,
    );
    expect(update?.version, '0.2.0');
    expect(update?.androidApkUrl?.host, 'github.com');
  });

  test('does not offer older or equal versions', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient(
        (_) async =>
            http.Response.bytes(utf8.encode(jsonEncode(release())), 200),
      ),
    );
    addTearDown(checker.close);

    expect(
      await checker.check(installedVersion: '0.2.0', repository: repository),
      isNull,
    );
    expect(
      await checker.check(installedVersion: '0.3.0', repository: repository),
      isNull,
    );
  });

  test('rejects an unexpected download domain', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode(release(url: 'https://example.com/update'))),
          200,
        ),
      ),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(installedVersion: '0.1.0', repository: repository),
      throwsA(isA<ReleaseCheckException>()),
    );
  });

  test('private or missing releases report an actionable error', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient((_) async => http.Response('Not Found', 404)),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(installedVersion: '0.1.0', repository: repository),
      throwsA(isA<ReleaseCheckException>()),
    );
  });
}
