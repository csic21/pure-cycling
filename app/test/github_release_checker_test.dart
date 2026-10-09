import 'dart:convert';

import 'package:cycling_app/core/updates/github_release_checker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The update check, now that it goes through the project's relay instead of
/// asking GitHub from the device.
///
/// What matters here is that the request leaves for the relay and not for
/// `api.github.com` — that is the whole fix — and that the failures a relay
/// can produce keep the distinct messages the app relies on.
void main() {
  const relay = 'https://project.supabase.co/functions/v1/release';

  Map<String, Object?> release({
    String tag = 'v0.2.0',
    String url = 'https://github.com/csic21/pure-cycling/releases/tag/v0.2.0',
  }) => {
    'tag_name': tag,
    'html_url': url,
    'body': '修复路线规划',
    'assets': [
      {
        'name': 'app-release.apk',
        'browser_download_url':
            'https://github.com/csic21/pure-cycling/releases/download/v0.2.0/app-release.apk',
      },
    ],
  };

  http.Response ok(Object? body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: {'x-release-repository': 'csic21/pure-cycling'},
  );

  test('asks the relay, not GitHub, for the latest release', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient((request) async {
        expect(request.url.toString(), relay);
        expect(request.method, 'GET');
        return ok(release());
      }),
    );
    addTearDown(checker.close);

    final update = await checker.check(
      installedVersion: '0.1.0',
      relayUrl: relay,
    );
    expect(update?.version, '0.2.0');
    expect(update?.androidApkUrl?.host, 'github.com');
  });

  test('does not offer older or equal versions', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient((_) async => ok(release())),
    );
    addTearDown(checker.close);

    expect(
      await checker.check(installedVersion: '0.2.0', relayUrl: relay),
      isNull,
    );
    expect(
      await checker.check(installedVersion: '0.3.0', relayUrl: relay),
      isNull,
    );
  });

  test('rejects an unexpected download domain', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient(
        (_) async => ok(release(url: 'https://example.com/x')),
      ),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(installedVersion: '0.1.0', relayUrl: relay),
      throwsA(isA<ReleaseCheckException>()),
    );
  });

  test('rejects a Release page from another repository', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient(
        (_) async => ok(
          release(
            url: 'https://github.com/another/project/releases/tag/v0.2.0',
          ),
        ),
      ),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(installedVersion: '0.1.0', relayUrl: relay),
      throwsA(isA<ReleaseCheckException>()),
    );
  });

  test('rejects a relay pointing to another repository', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode(release())),
          200,
          headers: {'x-release-repository': 'another/project'},
        ),
      ),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(installedVersion: '0.1.0', relayUrl: relay),
      throwsA(isA<ReleaseCheckException>()),
    );
  });

  test('rejects an APK from another repository', () async {
    final data = release();
    final assets = data['assets'] as List<dynamic>;
    (assets.first as Map<String, Object?>)['browser_download_url'] =
        'https://github.com/another/project/releases/download/v0.2.0/app.apk';
    final checker = GitHubReleaseChecker(
      client: MockClient((_) async => ok(data)),
    );
    addTearDown(checker.close);

    final update = await checker.check(
      installedVersion: '0.1.0',
      relayUrl: relay,
    );
    expect(update?.androidApkUrl, isNull);
  });

  test('tells a missing release apart from an outage', () async {
    // The relay reports these as 404 and 503, and the rider should not be told
    // to retry something that retrying cannot fix — nor the reverse.
    Future<String> messageFor(int status) async {
      final checker = GitHubReleaseChecker(
        client: MockClient(
          (_) async => status == 404
              ? http.Response(
                  '{"code":"release_missing"}',
                  404,
                  headers: {'x-release-repository': 'csic21/pure-cycling'},
                )
              : http.Response('{}', status),
        ),
      );
      addTearDown(checker.close);
      try {
        await checker.check(installedVersion: '0.1.0', relayUrl: relay);
        return '（没有抛出异常）';
      } on ReleaseCheckException catch (error) {
        return error.message;
      }
    }

    expect(await messageFor(404), contains('还没有'));
    expect(await messageFor(503), contains('不可用'));
  });

  test('does not mistake an undeployed relay for a missing Release', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient((_) async => http.Response('Function not found', 404)),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(installedVersion: '0.1.0', relayUrl: relay),
      throwsA(
        isA<ReleaseCheckException>().having(
          (error) => error.message,
          'message',
          contains('尚未就绪'),
        ),
      ),
    );
  });

  test('says so when the build has no update service', () async {
    // A build without SUPABASE_FUNCTIONS_URL. Saying "暂时不可用" would send
    // the rider off to retry a service that is not there.
    final checker = GitHubReleaseChecker(
      client: MockClient((_) async => ok(release())),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(installedVersion: '0.1.0'),
      throwsA(isA<ReleaseCheckException>()),
    );
  });

  test('refuses a relay address that is not https', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient((_) async => ok(release())),
    );
    addTearDown(checker.close);

    expect(
      () => checker.check(
        installedVersion: '0.1.0',
        relayUrl: 'http://project.supabase.co/functions/v1/release',
      ),
      throwsA(isA<ReleaseCheckException>()),
    );
  });
  test('bounds the release metadata response before JSON parsing', () async {
    final checker = GitHubReleaseChecker(
      client: MockClient(
        (_) async => http.Response('x' * (1024 * 1024 + 1), 200),
      ),
    );
    addTearDown(checker.close);
    await expectLater(
      checker.check(installedVersion: '0.1.17', relayUrl: relay),
      throwsA(
        isA<ReleaseCheckException>().having(
          (error) => error.message,
          'message',
          contains('过大'),
        ),
      ),
    );
  });
  Map<String, Object> provenance({String tag = 'v0.2.0'}) => {
    'tag': tag,
    'source_sha': 'a' * 40,
    'signer_sha256': 'b' * 64,
    'apk_sha256': 'c' * 64,
  };

  Future<String> displayedNotes(String notes) async {
    final data = release()..['body'] = notes;
    final checker = GitHubReleaseChecker(
      client: MockClient((_) async => ok(data)),
    );
    try {
      return (await checker.check(
        installedVersion: '0.1.17',
        relayUrl: relay,
      ))!.notes;
    } finally {
      checker.close();
    }
  }

  test(
    'hides only the matching release provenance and retains normal notes',
    () async {
      for (final metadata in [
        provenance(),
        {
          ...provenance(),
          'package_name': 'app.purecycling.cycling',
          'version_name': '0.2.0',
          'version_code': 19,
        },
      ]) {
        final marker = '<!-- pure-cycling-release: ${jsonEncode(metadata)} -->';
        expect(
          await displayedNotes('修复更新流程。\n\n$marker\n\n保留这行说明。'),
          '修复更新流程。\n\n\n\n保留这行说明。',
        );
        expect(await displayedNotes(marker), isEmpty);
        expect(await displayedNotes('$marker 普通说明 $marker'), '普通说明');
      }
    },
  );

  test('preserves ordinary HTML comments and other metadata markers', () async {
    const notes =
        '普通说明\n<!-- keep this comment -->\n<!-- another-release: {} -->';
    expect(await displayedNotes(notes), notes);
  });

  test('preserves mismatched malformed and oversized provenance comments', () async {
    final examples = [
      '<!-- pure-cycling-release: ${jsonEncode(provenance(tag: 'v0.1.17'))} -->',
      '<!-- pure-cycling-release: {broken JSON} -->',
      '<!-- pure-cycling-release: {} -->',
      '<!-- pure-cycling-release: ${jsonEncode({...provenance(), 'source_sha': 'unknown'})} -->',
      '<!-- pure-cycling-release: ${jsonEncode({...provenance(), 'extra': 'x' * 4096})} -->',
      '<!-- pure-cycling-release: ${jsonEncode(provenance())}',
    ];
    for (final notes in examples) {
      expect(await displayedNotes(notes), notes);
    }
  });
}
